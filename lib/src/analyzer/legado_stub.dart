import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:js_interpreter/js_interpreter.dart';

import 'css.dart';

const String legadoStubJS = r'''
var java = {
  _store: {},
  _content: "",
  put: function(k, v) { this._store[k] = String(v); return String(v); },
  get: function(k) { return this._store[k] || ""; },
  log: function() { /* silent */ },
  toast: function() { /* silent */ },
  longToast: function() { /* silent */ },
  encodeURI: function(s) { return encodeURI(s); },
  base64Decode: function(s) { return __legado_base64_decode(String(s)); },
  base64Encode: function(s) { return __legado_base64_encode(String(s)); },
  md5Encode: function(s) { return __legado_md5(String(s)); },
  md5Encode16: function(s) { return __legado_md5(String(s)).substring(8, 24); },
  hexDecodeToString: function(hex) {
    var s = "";
    for (var i = 0; i < hex.length; i += 2) {
      s += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
    }
    return s;
  },
  s2t: function(s) { return s; },
  t2s: function(s) { return s; },
  ajax: function(url) { return __legado_ajax(String(url)); },
  connect: function(url) { return __legado_make_response(__legado_request("GET", String(url), "", "{}")); },
  get: function(url, headers) { return __legado_make_response(__legado_request("GET", String(url), "", JSON.stringify(headers || {}))); },
  post: function(url, body, headers) { return __legado_make_response(__legado_request("POST", String(url), String(body || ""), JSON.stringify(headers || {}))); },
  head: function(url, headers) { return __legado_make_response(__legado_request("HEAD", String(url), "", JSON.stringify(headers || {}))); },
  setContent: function(html) { this._content = html; },
  getContent: function() { return this._content; },
  getElements: function(path) { return []; },
  getString: function(path) { return ""; },
  getStringList: function(path) { return []; },
  webView: function(html, url, js) { return html || this.ajax(url || ""); },
  startBrowserAwait: function(url, msg) { return ""; },
  putLoginInfo: function(msg) {},
  getVerificationCode: function(url) { return ""; },
  getCookie: function(url, name) { return ""; },
  timeFormat: function(ts) { return new Date(Number(ts)).toISOString(); },
  androidId: function() { return ""; }
};
var cookie = {
  removeCookie: function(key) {},
  getCookie: function(key) { return ""; },
  setCookie: function(key, value) {}
};
var cache = {
  put: function(key, value, seconds) { __legado_cache_put(String(key), String(value)); return String(value); },
  get: function(key) { return __legado_cache_get(String(key)); },
  delete: function(key) { __legado_cache_delete(String(key)); }
};
var source = {
  _var: "",
  _comment: "",
  bookSourceComment: "",
  bookSourceName: "",
  searchUrl: "",
  bookList: "",
  getKey: function() { return ""; },
  getVariable: function() { return this._var; },
  setVariable: function(v) { this._var = String(v); },
  put: function(k, v) { java._store[String(k)] = String(v); return String(v); },
  get: function(k) { return java._store[String(k)] || ""; },
  putLoginInfo: function(msg) {},
  getLoginInfoMap: function() { return {}; }
};
function __legado_make_response(json) {
  var r = {};
  try { r = JSON.parse(String(json || "{}")); } catch(e) { r = {body:String(json||""), headers:{}, code:0, url:""}; }
  r.headers = r.headers || {};
  return {
    body: function(){ return r.body || ""; },
    code: function(){ return Number(r.code || 0); },
    statusCode: function(){ return Number(r.code || 0); },
    message: function(){ return r.status || ""; },
    url: function(){ return r.url || ""; },
    header: function(k){ return r.headers[String(k).toLowerCase()] || r.headers[String(k)] || ""; },
    headers: function(){ return { get: function(k){ return r.headers[String(k).toLowerCase()] || r.headers[String(k)] || ""; } }; },
    raw: function(){ return r; },
    toString: function(){ return r.body || ""; }
  };
}
function checkData() { return {}; }
function toDataUrl(key, page) { return ""; }
function getl(arr, page) {
  var size = 20;
  var start = page * size;
  return arr.slice(start, start + size);
}
function createRegExp(key) {
  try { return new RegExp(key, "i"); }
  catch(e) { return new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i"); }
}
function getSortValue(item, st) { return item[st] || 0; }
''';

final Map<String, String> _jsCache = {};

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

  Map<String, dynamic> toJson() => {
    'body': body,
    'code': code,
    'status': status,
    'url': url,
    'headers': headers,
  };
}

/// Injects Legado API stubs and host-backed functions into [interpreter].
void injectLegadoStubs(JSInterpreter interpreter) {
  interpreter.registerGlobal(
    '__legado_ajax',
    JSNativeFunction(
      functionName: '__legado_ajax',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.string('');
        final body = _doLegadoAjax(args[0].toString());
        return JSValueFactory.string(body);
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_request',
    JSNativeFunction(
      functionName: '__legado_request',
      nativeImpl: (args) {
        final method = args.isNotEmpty ? args[0].toString() : 'GET';
        final urlStr = args.length > 1 ? args[1].toString() : '';
        final body = args.length > 2 ? args[2].toString() : '';
        final headersJson = args.length > 3 ? args[3].toString() : '{}';
        final resp = _doLegadoRequest(
          method,
          urlStr,
          body,
          _parseHeadersJson(headersJson),
          false,
        );
        return JSValueFactory.string(jsonEncode(resp.toJson()));
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_base64_decode',
    JSNativeFunction(
      functionName: '__legado_base64_decode',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.string('');
        final raw = args[0].toString();
        try {
          final normalized = base64.normalize(raw);
          return JSValueFactory.string(
            utf8.decode(base64.decode(normalized), allowMalformed: true),
          );
        } catch (_) {
          return JSValueFactory.string('');
        }
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_base64_encode',
    JSNativeFunction(
      functionName: '__legado_base64_encode',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.string('');
        return JSValueFactory.string(
          base64.encode(utf8.encode(args[0].toString())),
        );
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_md5',
    JSNativeFunction(
      functionName: '__legado_md5',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.string('');
        final digest = md5.convert(utf8.encode(args[0].toString()));
        return JSValueFactory.string(digest.toString());
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_cache_put',
    JSNativeFunction(
      functionName: '__legado_cache_put',
      nativeImpl: (args) {
        if (args.length >= 2) {
          _jsCache[args[0].toString()] = args[1].toString();
        }
        return JSValueFactory.undefined();
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_cache_get',
    JSNativeFunction(
      functionName: '__legado_cache_get',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.nullValue();
        final v = _jsCache[args[0].toString()];
        if (v != null) return JSValueFactory.string(v);
        return JSValueFactory.nullValue();
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_cache_delete',
    JSNativeFunction(
      functionName: '__legado_cache_delete',
      nativeImpl: (args) {
        if (args.isNotEmpty) {
          _jsCache.remove(args[0].toString());
        }
        return JSValueFactory.undefined();
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_log',
    JSNativeFunction(
      functionName: '__legado_log',
      nativeImpl: (args) {
        print(args.map((a) => a.toString()).join(' '));
        return JSValueFactory.undefined();
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_getElements',
    JSNativeFunction(
      functionName: '__legado_getElements',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.array([]);
        final rule = args[0].toString();
        final content = _readJsContent(interpreter);
        if (content.isEmpty) return JSValueFactory.array([]);

        final selectors = rule.split('||');
        final allResults = <String>[];
        for (var sel in selectors) {
          sel = sel.trim();
          if (sel.isEmpty) continue;
          allResults.addAll(cssGetElementList(sel, content, ''));
        }
        return JSValueFactory.array(
          allResults.map(JSValueFactory.string).toList(),
        );
      },
    ),
  );

  interpreter.registerGlobal(
    '__legado_getString',
    JSNativeFunction(
      functionName: '__legado_getString',
      nativeImpl: (args) {
        if (args.isEmpty) return JSValueFactory.string('');
        final rule = args[0].toString();
        final content = _readJsContent(interpreter);
        if (content.isEmpty) return JSValueFactory.string('');
        return JSValueFactory.string(cssGetString(rule, content, ''));
      },
    ),
  );

  interpreter.eval(legadoStubJS);
  interpreter.eval('''
    java.ajax = __legado_ajax;
    java.log = __legado_log;
    java.getElements = __legado_getElements;
    java.getString = __legado_getString;
  ''');
}

String _readJsContent(JSInterpreter interpreter) {
  try {
    final cv = interpreter.eval('java._content');
    if (!cv.isUndefined && !cv.isNull && cv.toString().isNotEmpty) {
      return cv.toString();
    }
  } catch (_) {}
  try {
    final rv = interpreter.eval('typeof result !== "undefined" ? result : ""');
    if (!rv.isUndefined && !rv.isNull) {
      return rv.toString();
    }
  } catch (_) {}
  return '';
}

String _doLegadoAjax(String urlStr) {
  final parsed = _parseJSURL(urlStr);
  final resp = _doLegadoRequest(
    parsed.method,
    parsed.target,
    parsed.body,
    parsed.headers,
    true,
  );
  return resp.body;
}

JsHttpResponse _doLegadoRequest(
  String method,
  String urlStr,
  String body,
  Map<String, String> headers,
  bool followRedirect,
) {
  var effMethod = method.trim().toUpperCase();
  if (effMethod.isEmpty) effMethod = 'GET';

  final parsed = _parseJSURL(urlStr);
  if (parsed.method.isNotEmpty) {
    effMethod = parsed.method;
  }
  var effBody = body;
  if (parsed.body.isNotEmpty && effBody.isEmpty) {
    effBody = parsed.body;
  }
  final effHeaders = Map<String, String>.from(headers);
  for (final entry in parsed.headers.entries) {
    effHeaders.putIfAbsent(entry.key, () => entry.value);
  }

  final targetUrl = parsed.target;
  if (targetUrl.trim().isEmpty) {
    return JsHttpResponse(url: targetUrl, status: 'empty url');
  }

  if (effMethod == 'POST' &&
      !effHeaders.keys.any((k) => k.toLowerCase() == 'content-type')) {
    effHeaders['Content-Type'] = 'application/x-www-form-urlencoded';
  }

  return _syncHttpRequest(
    method: effMethod,
    url: targetUrl,
    body: effBody,
    headers: effHeaders,
    followRedirect: followRedirect,
  );
}

JsHttpResponse _syncHttpRequest({
  required String method,
  required String url,
  required String body,
  required Map<String, String> headers,
  required bool followRedirect,
}) {
  final tempDir = Directory.systemTemp.createTempSync('gopro_sync_http_');
  final headerFile = File('${tempDir.path}/headers.txt');
  try {
    final args = <String>[
      '-sS',
      '-k',
      '--max-time',
      '15',
      '-X',
      method,
      '-D',
      headerFile.path,
      '-w',
      '\n%{http_code}\n%{url_effective}',
    ];
    if (followRedirect) {
      args.add('-L');
    }
    if (method == 'HEAD') {
      args.add('-I');
    }
    for (final entry in headers.entries) {
      args.addAll(['-H', '${entry.key}: ${entry.value}']);
    }
    if (method == 'POST' && body.isNotEmpty) {
      args.addAll(['--data-raw', body]);
    }
    args.add(url);

    final result = Process.runSync('curl', args, stdoutEncoding: null);
    if (result.exitCode != 0 && !headerFile.existsSync()) {
      return _syncHttpWithDartSubprocess(
        method: method,
        url: url,
        body: body,
        headers: headers,
        followRedirect: followRedirect,
      );
    }

    final rawOut = result.stdout is List<int>
        ? result.stdout as List<int>
        : utf8.encode(result.stdout.toString());
    final outText = utf8.decode(rawOut, allowMalformed: true);
    final lines = outText.split('\n');
    var effectiveUrl = url;
    var code = 0;
    var responseBody = outText;
    if (lines.length >= 3) {
      effectiveUrl = lines.last.trim();
      code = int.tryParse(lines[lines.length - 2].trim()) ?? 0;
      responseBody = lines.sublist(0, lines.length - 2).join('\n');
    }

    final respHeaders = <String, String>{};
    var statusText = code > 0 ? '$code' : result.stderr.toString();
    if (headerFile.existsSync()) {
      final headerContent = headerFile.readAsStringSync();
      // If redirects occurred, take the final header block.
      final blocks = headerContent.trim().split(RegExp(r'\r?\n\r?\n'));
      final lastBlock = blocks.isNotEmpty ? blocks.last : '';
      final headerLines = lastBlock.split(RegExp(r'\r?\n'));
      if (headerLines.isNotEmpty) {
        statusText = headerLines.first.trim();
      }
      for (final line in headerLines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          final k = line.substring(0, colon).trim();
          final v = line.substring(colon + 1).trim();
          respHeaders[k.toLowerCase()] = v;
          respHeaders[k] = v;
        }
      }
    }

    return JsHttpResponse(
      body: method == 'HEAD' ? '' : responseBody,
      code: code,
      status: statusText,
      url: effectiveUrl.isEmpty ? url : effectiveUrl,
      headers: respHeaders,
    );
  } on ProcessException {
    return _syncHttpWithDartSubprocess(
      method: method,
      url: url,
      body: body,
      headers: headers,
      followRedirect: followRedirect,
    );
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

JsHttpResponse _syncHttpWithDartSubprocess({
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
    final uri = Uri.parse(cfg['url'] as String);
    final req = await client.openUrl(cfg['method'] as String, uri);
    req.followRedirects = cfg['followRedirect'] as bool;
    final headers = (cfg['headers'] as Map).cast<String, dynamic>();
    headers.forEach((k, v) => req.headers.set(k, v.toString()));
    final body = cfg['body'] as String;
    if (cfg['method'] == 'POST' && body.isNotEmpty) {
      req.write(body);
    }
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
    final outHeaders = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        outHeaders[name.toLowerCase()] = values.first;
        outHeaders[name] = values.first;
      }
    });
    stdout.write(jsonEncode({
      'body': utf8.decode(bytes, allowMalformed: true),
      'code': resp.statusCode,
      'status': '\${resp.statusCode} \${resp.reasonPhrase}',
      'url': uri.toString(),
      'headers': outHeaders,
    }));
  } catch (e) {
    stdout.write(jsonEncode({
      'body': '',
      'code': 0,
      'status': e.toString(),
      'url': cfg['url'],
      'headers': <String, String>{},
    }));
  } finally {
    client.close();
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
      final hdrs = <String, String>{};
      final rawHdrs = decoded['headers'];
      if (rawHdrs is Map) {
        rawHdrs.forEach((k, v) => hdrs[k.toString()] = v.toString());
      }
      return JsHttpResponse(
        body: (decoded['body'] ?? '').toString(),
        code: (decoded['code'] as num?)?.toInt() ?? 0,
        status: (decoded['status'] ?? '').toString(),
        url: (decoded['url'] ?? url).toString(),
        headers: hdrs,
      );
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

class _ParsedJSUrl {
  final String method;
  final String target;
  final String body;
  final Map<String, String> headers;

  _ParsedJSUrl({
    required this.method,
    required this.target,
    required this.body,
    required this.headers,
  });
}

_ParsedJSUrl _parseJSURL(String urlStr) {
  final headers = <String, String>{};
  var method = 'GET';
  var target = urlStr.trim();
  var body = '';

  final idx = _findJSOptionSeparator(target);
  if (idx >= 0) {
    final option = target.substring(idx + 1).trim();
    target = target.substring(0, idx).trim();
    try {
      final opt = jsonDecode(_normalizeJSJSON(option));
      if (opt is Map) {
        final m = opt['method'];
        if (m is String && m.isNotEmpty) {
          method = m.toUpperCase();
        }
        if (opt.containsKey('body') && opt['body'] != null) {
          body = _stringifyJSValue(opt['body']);
        }
        final h = opt['headers'];
        if (h is Map) {
          h.forEach((k, v) {
            headers[k.toString()] = _stringifyJSValue(v);
          });
        }
      }
    } catch (_) {}
  }
  return _ParsedJSUrl(
    method: method,
    target: target,
    body: body,
    headers: headers,
  );
}

int _findJSOptionSeparator(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s[i] == ',') {
      final rest = s.substring(i + 1).trim();
      if (rest.startsWith('{') ||
          rest.startsWith("'") ||
          rest.startsWith('"')) {
        return i;
      }
    }
  }
  return -1;
}

String _normalizeJSJSON(String raw) {
  final s = raw.trim();
  if (!s.contains("'")) return s;
  final b = StringBuffer();
  var inDouble = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '"') {
      inDouble = !inDouble;
      b.write(ch);
    } else if (ch == "'" && !inDouble) {
      b.write('"');
    } else {
      b.write(ch);
    }
  }
  return b.toString();
}

String _stringifyJSValue(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  try {
    return jsonEncode(v);
  } catch (_) {
    return v.toString();
  }
}

Map<String, String> _parseHeadersJson(String raw) {
  final out = <String, String>{};
  if (raw.trim().isEmpty) return out;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      decoded.forEach((k, v) {
        out[k.toString()] = _stringifyJSValue(v);
      });
    }
  } catch (_) {}
  return out;
}
