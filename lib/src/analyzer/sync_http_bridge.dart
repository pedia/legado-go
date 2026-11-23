import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Response returned to synchronous Legado JS HTTP helpers (`java.get`, etc.).
class JsHttpResponse {
  final String body;
  final int code;
  final String status;
  final String url;
  final Map<String, String> headers;

  const JsHttpResponse({
    this.body = '',
    this.code = 0,
    this.status = '',
    this.url = '',
    this.headers = const {},
  });

  factory JsHttpResponse.fromJson(Map<String, dynamic> json) {
    final hdrs = <String, String>{};
    final rawHdrs = json['headers'];
    if (rawHdrs is Map) {
      rawHdrs.forEach((k, v) => hdrs[k.toString()] = v.toString());
    }
    return JsHttpResponse(
      body: (json['body'] ?? '').toString(),
      code: (json['code'] as num?)?.toInt() ?? 0,
      status: (json['status'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      headers: hdrs,
    );
  }

  Map<String, dynamic> toJson() => {
    'body': body,
    'code': code,
    'status': status,
    'url': url,
    'headers': headers,
  };
}

/// Executes an HTTP(S) request in-process using `package:http` (`IOClient`)
/// with manual redirect tracking so [JsHttpResponse.url] records the final URL.
Future<JsHttpResponse> executePackageHttpRequest({
  required http.Client client,
  required String method,
  required String url,
  required String body,
  required Map<String, String> headers,
  required bool followRedirect,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final initialUri = Uri.tryParse(url);
  if (initialUri == null || !initialUri.hasScheme) {
    return JsHttpResponse(url: url, status: 'invalid url: $url');
  }
  var currentUri = initialUri;

  var currentMethod = method.trim().toUpperCase();
  if (currentMethod.isEmpty) currentMethod = 'GET';
  var currentBody = body;
  const maxRedirects = 10;

  for (var hop = 0; hop <= maxRedirects; hop++) {
    final req = http.Request(currentMethod, currentUri)
      ..followRedirects = false;
    headers.forEach((k, v) => req.headers[k] = v);
    if (currentMethod == 'POST' && currentBody.isNotEmpty) {
      req.bodyBytes = utf8.encode(currentBody);
    }

    final streamed = await client.send(req).timeout(timeout);
    final statusCode = streamed.statusCode;
    final reason = streamed.reasonPhrase ?? '';
    final respHeaders = <String, String>{};
    streamed.headers.forEach((k, v) {
      respHeaders[k.toLowerCase()] = v;
      respHeaders[k] = v;
    });

    if (followRedirect && _isRedirectStatus(statusCode) && hop < maxRedirects) {
      final location = streamed.headers['location'];
      if (location != null && location.isNotEmpty) {
        await streamed.stream.drain<void>();
        currentUri = currentUri.resolve(location);
        if (statusCode == HttpStatus.movedPermanently ||
            statusCode == HttpStatus.found ||
            statusCode == HttpStatus.seeOther) {
          if (currentMethod != 'HEAD') {
            currentMethod = 'GET';
            currentBody = '';
          }
        }
        continue;
      }
    }

    final bytes = currentMethod == 'HEAD'
        ? const <int>[]
        : await streamed.stream.toBytes();
    return JsHttpResponse(
      body: currentMethod == 'HEAD'
          ? ''
          : utf8.decode(bytes, allowMalformed: true),
      code: statusCode,
      status: reason.isNotEmpty ? '$statusCode $reason' : '$statusCode',
      url: currentUri.toString(),
      headers: respHeaders,
    );
  }

  return JsHttpResponse(
    url: currentUri.toString(),
    status: 'too many redirects',
  );
}

bool _isRedirectStatus(int code) =>
    code == HttpStatus.movedPermanently ||
    code == HttpStatus.found ||
    code == HttpStatus.seeOther ||
    code == HttpStatus.temporaryRedirect ||
    code == HttpStatus.permanentRedirect;

/// Runs [action] with an in-process [SyncHttpBridge] worker isolate active so
/// synchronous JS HTTP/HTTPS calls execute cleanly via `package:http` without
/// spawning external processes or leaving sockets open on exit.
Future<T> withSyncHttpBridge<T>(Future<T> Function() action) async {
  await SyncHttpBridge.acquire();
  try {
    return await action();
  } finally {
    await SyncHttpBridge.release();
  }
}

/// In-process loopback bridge that runs `package:http` (`IOClient`) inside a
/// worker [Isolate] and serves synchronous callers over [RawSynchronousSocket].
class SyncHttpBridge {
  static int _refCount = 0;
  static Future<SyncHttpBridge>? _starting;
  static SyncHttpBridge? _active;

  final int port;
  final SendPort _controlPort;
  final Isolate _isolate;

  SyncHttpBridge._(this.port, this._controlPort, this._isolate);

  /// Port of the active in-process bridge, or `null` if none is running.
  static int? get activePort => _active?.port;

  /// Acquires the shared bridge, starting it if needed.
  static Future<void> acquire() async {
    _refCount++;
    if (_active != null) return;
    _starting ??= _start();
    try {
      _active = await _starting;
    } catch (_) {
      if (_refCount > 0) _refCount--;
      rethrow;
    } finally {
      _starting = null;
    }
  }

  /// Releases one reference and closes the bridge when no callers remain.
  static Future<void> release() async {
    if (_refCount > 0) _refCount--;
    if (_refCount == 0 && _active != null) {
      final bridge = _active!;
      _active = null;
      await bridge.close();
    }
  }

  static Future<SyncHttpBridge> _start() async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _bridgeWorkerIsolate,
      readyPort.sendPort,
    );
    final info = await readyPort.first as List<Object?>;
    readyPort.close();
    final port = info[0] as int;
    final controlPort = info[1] as SendPort;
    return SyncHttpBridge._(port, controlPort, isolate);
  }

  /// Sends one synchronous HTTP(S) request through this in-process bridge.
  JsHttpResponse requestSync({
    required String method,
    required String url,
    required String body,
    required Map<String, String> headers,
    required bool followRedirect,
  }) {
    RawSynchronousSocket? socket;
    try {
      socket = RawSynchronousSocket.connectSync(
        InternetAddress.loopbackIPv4,
        port,
      );
      final payload = utf8.encode(
        jsonEncode({
          'method': method,
          'url': url,
          'body': body,
          'headers': headers,
          'followRedirect': followRedirect,
        }),
      );
      final lenHeader = Uint8List(4)
        ..buffer.asByteData().setUint32(0, payload.length, Endian.big);
      socket.writeFromSync(lenHeader);
      socket.writeFromSync(payload);

      final respLenBytes = _readExactSync(socket, 4);
      final respLen = Uint8List.fromList(
        respLenBytes,
      ).buffer.asByteData().getUint32(0, Endian.big);
      final respBytes = _readExactSync(socket, respLen);
      final decoded =
          jsonDecode(utf8.decode(respBytes, allowMalformed: true))
              as Map<String, dynamic>;
      return JsHttpResponse.fromJson(decoded);
    } catch (e) {
      return JsHttpResponse(url: url, status: e.toString());
    } finally {
      try {
        socket?.closeSync();
      } catch (_) {}
    }
  }

  /// Shuts down the worker isolate cleanly.
  Future<void> close() async {
    final ack = ReceivePort();
    _controlPort.send(ack.sendPort);
    await ack.first.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _isolate.kill(priority: Isolate.immediate);
        return null;
      },
    );
    ack.close();
  }
}

Future<void> _bridgeWorkerIsolate(SendPort readySend) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final controlPort = ReceivePort();
  final ioClient = HttpClient()
    ..badCertificateCallback = ((_, _, _) => true)
    ..connectionTimeout = const Duration(seconds: 15);
  final client = IOClient(ioClient);

  readySend.send([server.port, controlPort.sendPort]);

  final sub = server.listen((socket) async {
    try {
      final bytes = await _readAllFromAsyncSocket(socket);
      if (bytes.length < 4) {
        await socket.close();
        return;
      }
      final reqLen = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      if (bytes.length < 4 + reqLen) {
        await socket.close();
        return;
      }
      final cfg =
          jsonDecode(utf8.decode(bytes.sublist(4, 4 + reqLen)))
              as Map<String, dynamic>;
      final headers = <String, String>{};
      final rawHdrs = cfg['headers'];
      if (rawHdrs is Map) {
        rawHdrs.forEach((k, v) => headers[k.toString()] = v.toString());
      }

      JsHttpResponse resp;
      try {
        resp = await executePackageHttpRequest(
          client: client,
          method: (cfg['method'] ?? 'GET').toString(),
          url: (cfg['url'] ?? '').toString(),
          body: (cfg['body'] ?? '').toString(),
          headers: headers,
          followRedirect: cfg['followRedirect'] == true,
        );
      } catch (e) {
        resp = JsHttpResponse(
          url: (cfg['url'] ?? '').toString(),
          status: e.toString(),
        );
      }

      final respPayload = utf8.encode(jsonEncode(resp.toJson()));
      final respHeader = Uint8List(4)
        ..buffer.asByteData().setUint32(0, respPayload.length, Endian.big);
      socket.add(respHeader);
      socket.add(respPayload);
      await socket.flush();
    } catch (_) {
    } finally {
      await socket.close();
    }
  });

  final replyPort = await controlPort.first as SendPort;
  await sub.cancel();
  await server.close();
  client.close();
  controlPort.close();
  replyPort.send(true);
}

Future<Uint8List> _readAllFromAsyncSocket(Socket socket) async {
  final completer = Completer<Uint8List>();
  final buffer = BytesBuilder(copy: false);
  var expectedLength = -1;

  late final StreamSubscription<Uint8List> sub;
  sub = socket.listen(
    (chunk) {
      buffer.add(chunk);
      if (expectedLength < 0 && buffer.length >= 4) {
        final current = buffer.toBytes();
        expectedLength = ByteData.sublistView(
          current,
          0,
          4,
        ).getUint32(0, Endian.big);
        buffer.clear();
        buffer.add(current);
      }
      if (expectedLength >= 0 && buffer.length >= 4 + expectedLength) {
        if (!completer.isCompleted) {
          completer.complete(buffer.takeBytes());
          sub.cancel();
        }
      }
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(buffer.takeBytes());
      }
    },
    onError: (Object err) {
      if (!completer.isCompleted) {
        completer.complete(buffer.takeBytes());
      }
    },
    cancelOnError: true,
  );

  return completer.future;
}

/// Dispatches a synchronous HTTP(S) request without `curl`:
/// 1. Uses the active in-process [SyncHttpBridge] (`package:http` `IOClient`)
///    when available (supports both HTTP and HTTPS).
/// 2. For standalone `http://` calls without a bridge, uses a pure-Dart
///    in-process [RawSynchronousSocket] HTTP/1.1 client.
/// 3. For standalone `https://` calls without a bridge, runs a Dart subprocess
///    using `package:http` / `HttpClient`.
JsHttpResponse syncHttpRequest({
  required String method,
  required String url,
  required String body,
  required Map<String, String> headers,
  required bool followRedirect,
}) {
  final activeBridge = SyncHttpBridge._active;
  if (activeBridge != null) {
    return activeBridge.requestSync(
      method: method,
      url: url,
      body: body,
      headers: headers,
      followRedirect: followRedirect,
    );
  }

  final uri = Uri.tryParse(url);
  if (uri != null && uri.scheme.toLowerCase() == 'http') {
    return syncPlainHttpRequest(
      method: method,
      url: url,
      body: body,
      headers: headers,
      followRedirect: followRedirect,
    );
  }

  return _syncHttpsSubprocess(
    method: method,
    url: url,
    body: body,
    headers: headers,
    followRedirect: followRedirect,
  );
}

/// Pure in-process synchronous HTTP/1.1 client built on [RawSynchronousSocket].
JsHttpResponse syncPlainHttpRequest({
  required String method,
  required String url,
  required String body,
  required Map<String, String> headers,
  required bool followRedirect,
}) {
  final initialUri = Uri.tryParse(url);
  if (initialUri == null || initialUri.scheme.toLowerCase() != 'http') {
    return JsHttpResponse(url: url, status: 'unsupported url: $url');
  }
  var currentUri = initialUri;

  var currentMethod = method.trim().toUpperCase();
  if (currentMethod.isEmpty) currentMethod = 'GET';
  var currentBody = body;
  const maxRedirects = 10;

  for (var hop = 0; hop <= maxRedirects; hop++) {
    if (currentUri.scheme.toLowerCase() == 'https') {
      return _syncHttpsSubprocess(
        method: currentMethod,
        url: currentUri.toString(),
        body: currentBody,
        headers: headers,
        followRedirect: followRedirect,
      );
    }

    final port = currentUri.hasPort ? currentUri.port : 80;
    RawSynchronousSocket? socket;
    try {
      socket = RawSynchronousSocket.connectSync(currentUri.host, port);
      final target = _requestTarget(currentUri);
      final reqHeaders = <String, String>{};
      headers.forEach((k, v) => reqHeaders[k] = v);
      if (!reqHeaders.keys.any((k) => k.toLowerCase() == 'host')) {
        reqHeaders['Host'] = currentUri.hasPort
            ? '${currentUri.host}:$port'
            : currentUri.host;
      }
      reqHeaders['Connection'] = 'close';
      reqHeaders.putIfAbsent('Accept-Encoding', () => 'gzip');

      final bodyBytes = (currentMethod == 'POST' && currentBody.isNotEmpty)
          ? utf8.encode(currentBody)
          : const <int>[];
      if (bodyBytes.isNotEmpty &&
          !reqHeaders.keys.any((k) => k.toLowerCase() == 'content-length')) {
        reqHeaders['Content-Length'] = bodyBytes.length.toString();
      }

      final reqBuf = StringBuffer('$currentMethod $target HTTP/1.1\r\n');
      reqHeaders.forEach((k, v) => reqBuf.write('$k: $v\r\n'));
      reqBuf.write('\r\n');

      socket.writeFromSync(utf8.encode(reqBuf.toString()));
      if (bodyBytes.isNotEmpty) {
        socket.writeFromSync(bodyBytes);
      }

      final rawBytes = _readHttpResponseSync(socket, method: currentMethod);
      final parsed = _parseRawHttpResponse(
        rawBytes,
        url: currentUri.toString(),
        method: currentMethod,
      );

      if (followRedirect &&
          _isRedirectStatus(parsed.code) &&
          hop < maxRedirects) {
        final location = parsed.headers['location'];
        if (location != null && location.isNotEmpty) {
          currentUri = currentUri.resolve(location);
          if (parsed.code == HttpStatus.movedPermanently ||
              parsed.code == HttpStatus.found ||
              parsed.code == HttpStatus.seeOther) {
            if (currentMethod != 'HEAD') {
              currentMethod = 'GET';
              currentBody = '';
            }
          }
          continue;
        }
      }

      return parsed;
    } catch (e) {
      return JsHttpResponse(url: currentUri.toString(), status: e.toString());
    } finally {
      try {
        socket?.closeSync();
      } catch (_) {}
    }
  }

  return JsHttpResponse(
    url: currentUri.toString(),
    status: 'too many redirects',
  );
}

String _requestTarget(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  return uri.hasQuery ? '$path?${uri.query}' : path;
}

List<int> _readExactSync(RawSynchronousSocket socket, int length) {
  final result = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    final read = socket.readIntoSync(result, offset, length);
    if (read <= 0) {
      throw const HttpException('Unexpected EOF reading framed message');
    }
    offset += read;
  }
  return result;
}

Uint8List _readHttpResponseSync(
  RawSynchronousSocket socket, {
  required String method,
}) {
  final buf = Uint8List(8192);
  final out = BytesBuilder(copy: false);
  while (true) {
    final read = socket.readIntoSync(buf);
    if (read <= 0) break;
    out.add(Uint8List.sublistView(buf, 0, read));
    final current = out.toBytes();
    if (_isCompleteHttpResponse(current, method: method)) {
      return current;
    }
    out.clear();
    out.add(current);
  }
  return out.takeBytes();
}

bool _isCompleteHttpResponse(Uint8List raw, {required String method}) {
  var sepIdx = _indexOfBytes(raw, const [13, 10, 13, 10]);
  var sepLen = 4;
  if (sepIdx < 0) {
    sepIdx = _indexOfBytes(raw, const [10, 10]);
    sepLen = 2;
  }
  if (sepIdx < 0) return false;

  final bodyStart = sepIdx + sepLen;
  if (method == 'HEAD') return true;

  final headerText = latin1.decode(Uint8List.sublistView(raw, 0, sepIdx));
  final lines = headerText.split(RegExp(r'\r?\n'));
  var code = 0;
  if (lines.isNotEmpty) {
    final parts = lines.first.trim().split(' ');
    if (parts.length >= 2) {
      code = int.tryParse(parts[1]) ?? 0;
    }
  }
  if (code == HttpStatus.noContent || code == HttpStatus.notModified) {
    return true;
  }

  int? contentLength;
  var isChunked = false;
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final val = line.substring(colon + 1).trim();
    if (key == 'content-length') {
      contentLength = int.tryParse(val);
    } else if (key == 'transfer-encoding' &&
        val.toLowerCase().contains('chunked')) {
      isChunked = true;
    }
  }

  if (contentLength != null) {
    return raw.length >= bodyStart + contentLength;
  }
  if (isChunked) {
    return _hasCompleteChunkedBody(raw, bodyStart);
  }
  return false;
}

bool _hasCompleteChunkedBody(Uint8List data, int start) {
  var i = start;
  while (i < data.length) {
    final lineEnd = _indexOfCrlf(data, i);
    if (lineEnd < 0) return false;
    final sizeLine = latin1
        .decode(Uint8List.sublistView(data, i, lineEnd))
        .split(';')
        .first
        .trim();
    final chunkSize = int.tryParse(sizeLine, radix: 16);
    if (chunkSize == null) return false;
    if (chunkSize == 0) {
      // Final 0-size chunk ends with \r\n\r\n (or \r\n + trailers + \r\n\r\n).
      return _indexOfBytes(Uint8List.sublistView(data, lineEnd), const [
            13,
            10,
            13,
            10,
          ]) >=
          0;
    }
    final nextStart = lineEnd + 2 + chunkSize + 2;
    if (nextStart > data.length) return false;
    i = nextStart;
  }
  return false;
}

JsHttpResponse _parseRawHttpResponse(
  Uint8List raw, {
  required String url,
  required String method,
}) {
  var sepIdx = _indexOfBytes(raw, const [13, 10, 13, 10]);
  var sepLen = 4;
  if (sepIdx < 0) {
    sepIdx = _indexOfBytes(raw, const [10, 10]);
    sepLen = 2;
  }
  if (sepIdx < 0) {
    return JsHttpResponse(
      body: utf8.decode(raw, allowMalformed: true),
      url: url,
      status: 'malformed http response',
    );
  }

  final headerText = latin1.decode(Uint8List.sublistView(raw, 0, sepIdx));
  final lines = headerText.split(RegExp(r'\r?\n'));
  final statusLine = lines.isNotEmpty ? lines.first.trim() : '';
  var code = 0;
  var statusText = statusLine;
  final parts = statusLine.split(' ');
  if (parts.length >= 2) {
    code = int.tryParse(parts[1]) ?? 0;
    if (parts.length >= 3) {
      statusText = '$code ${parts.sublist(2).join(' ')}';
    }
  }

  final respHeaders = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0) {
      final k = line.substring(0, colon).trim();
      final v = line.substring(colon + 1).trim();
      respHeaders[k.toLowerCase()] = v;
      respHeaders[k] = v;
    }
  }

  if (method == 'HEAD') {
    return JsHttpResponse(
      body: '',
      code: code,
      status: statusText,
      url: url,
      headers: respHeaders,
    );
  }

  var bodyBytes = Uint8List.sublistView(raw, sepIdx + sepLen);
  final transferEncoding = (respHeaders['transfer-encoding'] ?? '')
      .toLowerCase();
  if (transferEncoding.contains('chunked')) {
    bodyBytes = _decodeChunkedBytes(bodyBytes);
  }
  final contentEncoding = (respHeaders['content-encoding'] ?? '').toLowerCase();
  if (contentEncoding.contains('gzip') && bodyBytes.isNotEmpty) {
    try {
      bodyBytes = Uint8List.fromList(gzip.decode(bodyBytes));
    } catch (_) {}
  }

  return JsHttpResponse(
    body: utf8.decode(bodyBytes, allowMalformed: true),
    code: code,
    status: statusText,
    url: url,
    headers: respHeaders,
  );
}

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

Uint8List _decodeChunkedBytes(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < data.length) {
    final lineEnd = _indexOfCrlf(data, i);
    if (lineEnd < 0) break;
    final sizeLine = latin1
        .decode(Uint8List.sublistView(data, i, lineEnd))
        .split(';')
        .first
        .trim();
    final chunkSize = int.tryParse(sizeLine, radix: 16);
    if (chunkSize == null || chunkSize == 0) break;
    final chunkStart = lineEnd + 2;
    final chunkEnd = chunkStart + chunkSize;
    if (chunkEnd > data.length) {
      out.add(Uint8List.sublistView(data, chunkStart));
      break;
    }
    out.add(Uint8List.sublistView(data, chunkStart, chunkEnd));
    i = chunkEnd + 2;
  }
  return out.takeBytes();
}

int _indexOfCrlf(Uint8List data, int start) {
  for (var i = start; i < data.length - 1; i++) {
    if (data[i] == 13 && data[i + 1] == 10) return i;
  }
  return -1;
}

JsHttpResponse _syncHttpsSubprocess({
  required String method,
  required String url,
  required String body,
  required Map<String, String> headers,
  required bool followRedirect,
}) {
  final tempDir = Directory.systemTemp.createTempSync('gopro_dart_http_');
  final scriptFile = File('${tempDir.path}/fetch.dart');
  try {
    scriptFile.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final cfg = jsonDecode(Platform.environment['GOPRO_HTTP_REQ']!) as Map<String, dynamic>;
  final client = HttpClient()
    ..badCertificateCallback = (_, _, _) => true
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    var currentUri = Uri.parse(cfg['url'] as String);
    var currentMethod = (cfg['method'] as String).toUpperCase();
    var currentBody = cfg['body'] as String;
    final follow = cfg['followRedirect'] as bool;
    final headers = (cfg['headers'] as Map).cast<String, dynamic>();

    for (var hop = 0; hop <= 10; hop++) {
      final req = await client.openUrl(currentMethod, currentUri);
      req.followRedirects = false;
      headers.forEach((k, v) => req.headers.set(k, v.toString()));
      if (currentMethod == 'POST' && currentBody.isNotEmpty) {
        req.write(currentBody);
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (follow && resp.statusCode >= 300 && resp.statusCode < 400 && hop < 10) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        if (loc != null && loc.isNotEmpty) {
          await resp.drain<void>();
          currentUri = currentUri.resolve(loc);
          if (resp.statusCode != 307 && resp.statusCode != 308 && currentMethod != 'HEAD') {
            currentMethod = 'GET';
            currentBody = '';
          }
          continue;
        }
      }
      final bytes = currentMethod == 'HEAD'
          ? const <int>[]
          : await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      final outHeaders = <String, String>{};
      resp.headers.forEach((name, values) {
        if (values.isNotEmpty) {
          outHeaders[name.toLowerCase()] = values.first;
          outHeaders[name] = values.first;
        }
      });
      stdout.write(jsonEncode({
        'body': currentMethod == 'HEAD' ? '' : utf8.decode(bytes, allowMalformed: true),
        'code': resp.statusCode,
        'status': '\${resp.statusCode} \${resp.reasonPhrase}',
        'url': currentUri.toString(),
        'headers': outHeaders,
      }));
      return;
    }
  } catch (e) {
    stdout.write(jsonEncode({
      'body': '',
      'code': 0,
      'status': e.toString(),
      'url': cfg['url'],
      'headers': <String, String>{},
    }));
  } finally {
    client.close(force: true);
  }
}
''');
    final payload = jsonEncode({
      'method': method,
      'url': url,
      'body': body,
      'headers': headers,
      'followRedirect': followRedirect,
    });
    final resolvedExe = Platform.resolvedExecutable;
    final exeName = resolvedExe.split(Platform.pathSeparator).last;
    final dartExe = (exeName == 'dart' || exeName == 'dart.exe')
        ? resolvedExe
        : 'dart';
    final res = Process.runSync(
      dartExe,
      ['run', scriptFile.path],
      environment: {'GOPRO_HTTP_REQ': payload},
    );
    if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
      final decoded = jsonDecode(res.stdout.toString()) as Map<String, dynamic>;
      return JsHttpResponse.fromJson(decoded);
    }
    return JsHttpResponse(url: url, status: res.stderr.toString());
  } catch (e) {
    return JsHttpResponse(url: url, status: e.toString());
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
