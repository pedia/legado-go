import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:charset/charset.dart';
import 'package:gopro/gopro.dart';
import 'package:js_interpreter/js_interpreter.dart';
import 'package:test/test.dart';

void main() {
  late int serverPort;
  late String baseUrl;
  late Isolate serverIsolate;
  late SendPort stopPort;

  setUpAll(() async {
    final readyPort = ReceivePort();
    serverIsolate = await Isolate.spawn(_testServerIsolate, readyPort.sendPort);
    final info = await readyPort.first as List<Object?>;
    readyPort.close();
    serverPort = info[0] as int;
    stopPort = info[1] as SendPort;
    baseUrl = 'http://127.0.0.1:$serverPort';
  });

  tearDownAll(() async {
    final ack = ReceivePort();
    stopPort.send(ack.sendPort);
    await ack.first.timeout(const Duration(seconds: 2), onTimeout: () => null);
    ack.close();
    serverIsolate.kill(priority: Isolate.immediate);
  });

  group('syncPlainHttpRequest (RawSynchronousSocket HTTP/1.1)', () {
    test('GET sends query and custom headers', () {
      final resp = syncPlainHttpRequest(
        method: 'GET',
        url: '$baseUrl/echo?q=legado',
        body: '',
        headers: const {'X-Custom': 'dart-sync'},
        followRedirect: false,
      );
      expect(resp.code, 200);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      expect(data['method'], 'GET');
      expect(data['query'], 'q=legado');
      expect(data['customHeader'], 'dart-sync');
    });

    test('POST sends UTF-8 request body', () {
      final resp = syncPlainHttpRequest(
        method: 'POST',
        url: '$baseUrl/echo',
        body: 'name=斗破苍穹',
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        followRedirect: false,
      );
      expect(resp.code, 200);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      expect(data['method'], 'POST');
      expect(data['body'], 'name=斗破苍穹');
    });

    test('decodes chunked and gzip responses', () {
      final chunked = syncPlainHttpRequest(
        method: 'GET',
        url: '$baseUrl/chunked',
        body: '',
        headers: const {},
        followRedirect: false,
      );
      expect(chunked.code, 200);
      expect(chunked.body, 'chunk-one|chunk-two');

      final zipped = syncPlainHttpRequest(
        method: 'GET',
        url: '$baseUrl/gzip',
        body: '',
        headers: const {},
        followRedirect: false,
      );
      expect(zipped.code, 200);
      expect(zipped.body, 'hello gzipped body');
    });

    test('handles followRedirect true and false', () {
      final noFollow = syncPlainHttpRequest(
        method: 'GET',
        url: '$baseUrl/redirect',
        body: '',
        headers: const {},
        followRedirect: false,
      );
      expect(noFollow.code, 302);
      expect(noFollow.headers['location'], '/final?ok=1');

      final followed = syncPlainHttpRequest(
        method: 'GET',
        url: '$baseUrl/redirect',
        body: '',
        headers: const {},
        followRedirect: true,
      );
      expect(followed.code, 200);
      expect(followed.url, '$baseUrl/final?ok=1');
      expect(followed.body, 'arrived-at-final');
    });

    test('HEAD returns empty body with headers', () {
      final resp = syncPlainHttpRequest(
        method: 'HEAD',
        url: '$baseUrl/echo',
        body: '',
        headers: const {},
        followRedirect: false,
      );
      expect(resp.code, 200);
      expect(resp.body, isEmpty);
      expect(resp.headers['x-server'], 'gopro-test');
    });
  });

  group('SyncHttpBridge (in-process package:http isolate)', () {
    test(
      'supports java.get, java.post, java.ajax, java.head, java.connect',
      () async {
        await withSyncHttpBridge(() async {
          expect(SyncHttpBridge.activePort, isNotNull);
          final js = JSInterpreter();
          injectLegadoStubs(js);

          final getBody = js.eval(
            'java.get("$baseUrl/echo?via=bridge", {"X-Custom": "bridge-hdr"}).body()',
          );
          final getJson =
              jsonDecode(getBody.toString()) as Map<String, dynamic>;
          expect(getJson['customHeader'], 'bridge-hdr');
          expect(getJson['query'], 'via=bridge');

          final postBody = js.eval(
            'java.post("$baseUrl/echo", "k=v", {"X-Custom": "post"}).body()',
          );
          final postJson =
              jsonDecode(postBody.toString()) as Map<String, dynamic>;
          expect(postJson['method'], 'POST');
          expect(postJson['body'], 'k=v');

          final ajaxBody = js.eval('java.ajax("$baseUrl/redirect")');
          expect(ajaxBody.toString(), 'arrived-at-final');

          final noRedir = js.eval(
            'java.get("$baseUrl/redirect", {}).statusCode()',
          );
          expect(noRedir.toNumber(), 302);

          final headHdr = js.eval(
            'java.head("$baseUrl/echo", {}).header("x-server")',
          );
          expect(headHdr.toString(), 'gopro-test');

          final connUrl = js.eval('java.connect("$baseUrl/redirect").url()');
          expect(connUrl.toString(), '$baseUrl/final?ok=1');
        });
        expect(SyncHttpBridge.activePort, isNull);
      },
    );

    test('ref-counts concurrent withSyncHttpBridge callers cleanly', () async {
      await Future.wait([
        withSyncHttpBridge(() async {
          final resp = syncHttpRequest(
            method: 'GET',
            url: '$baseUrl/final?ok=a',
            body: '',
            headers: const {},
            followRedirect: true,
          );
          expect(resp.body, 'arrived-at-final');
        }),
        withSyncHttpBridge(() async {
          final resp = syncHttpRequest(
            method: 'GET',
            url: '$baseUrl/final?ok=b',
            body: '',
            headers: const {},
            followRedirect: true,
          );
          expect(resp.body, 'arrived-at-final');
        }),
      ]);
      expect(SyncHttpBridge.activePort, isNull);
    });
  });

  group('AnalyzeUrl package:http IOClient', () {
    test(
      'executes @js URL using SyncHttpBridge, retries 5xx, and decodes GBK',
      () async {
        final a1 = AnalyzeUrl(
          '@js:var u=java.connect("$baseUrl/redirect").url(); result=u;',
          'test',
          1,
          baseUrl,
          '',
        );
        final res1 = await a1.getStrResponse();
        expect(res1, 'arrived-at-final');

        final aRetry = AnalyzeUrl(
          '$baseUrl/flaky,{"retry":1}',
          'test',
          1,
          baseUrl,
          '',
        );
        final resRetry = await aRetry.getStrResponse();
        expect(resRetry, 'recovered');

        final aGbk = AnalyzeUrl(
          '$baseUrl/gbk,{"charset":"gbk"}',
          'test',
          1,
          baseUrl,
          '',
        );
        final resGbk = await aGbk.getStrResponse();
        expect(resGbk, '斗破苍穹');
      },
    );
  });
}

Future<void> _testServerIsolate(SendPort readySend) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final stopPort = ReceivePort();
  readySend.send([server.port, stopPort.sendPort]);
  var flakyCount = 0;

  final sub = server.listen((req) async {
    final path = req.uri.path;
    req.response.headers.set('X-Server', 'gopro-test');

    if (path == '/echo') {
      final reqBody = await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'method': req.method,
          'query': req.uri.query,
          'customHeader': req.headers.value('x-custom') ?? '',
          'body': reqBody,
        }),
      );
    } else if (path == '/chunked') {
      req.response.headers.contentType = ContentType.text;
      req.response.write('chunk-one|');
      await req.response.flush();
      req.response.write('chunk-two');
    } else if (path == '/gzip') {
      final compressed = gzip.encode(utf8.encode('hello gzipped body'));
      req.response.headers.set('Content-Encoding', 'gzip');
      req.response.headers.contentLength = compressed.length;
      req.response.add(compressed);
    } else if (path == '/redirect') {
      req.response.statusCode = HttpStatus.found;
      req.response.headers.set('Location', '/final?ok=1');
    } else if (path == '/final') {
      req.response.write('arrived-at-final');
    } else if (path == '/flaky') {
      flakyCount++;
      if (flakyCount == 1) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.write('try again');
      } else {
        req.response.write('recovered');
      }
    } else if (path == '/gbk') {
      const gbk = GbkCodec(allowMalformed: true);
      final bytes = gbk.encode('斗破苍穹');
      req.response.headers.contentLength = bytes.length;
      req.response.add(bytes);
    } else {
      req.response.statusCode = HttpStatus.notFound;
    }
    await req.response.close();
  });

  final ack = await stopPort.first as SendPort;
  await sub.cancel();
  await server.close(force: true);
  stopPort.close();
  ack.send(true);
}
