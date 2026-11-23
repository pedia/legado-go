import 'dart:io';
import 'dart:isolate';

import 'package:gopro/gopro.dart';
import 'package:js_interpreter/js_interpreter.dart';
import 'package:test/test.dart';

const String _testHTMLFull = '''<html><body>
<div class="book-like">
<a href="/book/1"><h4>斗破苍穹</h4><span>天蚕土豆</span><img src="/c/1.jpg"/></a>
<a href="/book/2"><h4>武动乾坤</h4><span>天蚕土豆</span><img src="/c/2.jpg"/></a>
</div>
<div class="txt-list">
  <ul>
    <li><a href="/b/1">First</a><span class="s4">A1</span></li>
    <li><a href="/b/2">Second</a><span class="s4">A2</span></li>
    <li><a href="/b/3">Third</a><span class="s4">A3</span></li>
  </ul>
</div>
<div class="mod block book-all-list">
  <div class="bd">
    <li><div class="right">
      <a class="name" href="/n/1/">苍穹</a>
      <span class="author">土豆</span>
    </div></li>
    <li><div class="right">
      <a class="name" href="/n/2/">乾坤</a>
      <span class="author">土豆</span>
    </div></li>
  </div>
</div>
<section class="grid-item">
  <a href="/g/1"><h4>GridBook1</h4></a>
</section>
<section class="grid-item">
  <a href="/g/2"><h4>GridBook2</h4></a>
</section>
<div class="info">作者：天蚕土豆 | 玄幻 | 322万字</div>
</body></html>''';

const String _testJSON =
    '[{"name":"斗破苍穹","author":"天蚕土豆","tags":"玄幻","category":"小说","status":"完结","update":"2024-01-01","word":"322万"},{"name":"武动乾坤","author":"天蚕土豆","tags":"玄幻","category":"小说","status":"完结","update":"2024-02-01","word":"280万"}]';

void main() {
  group('CSS / JSoup', () {
    test('extractHTML returns multiple items', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final items = ar.getElements('.book-like@a');
      expect(items.length, 2);
    });

    test('bare tag selector returns all <a> elements', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final items = ar.getElements('a');
      expect(items.length, greaterThanOrEqualTo(4));
    });

    test('multi-class selector', () {
      final pool = JsPool(1);
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', pool);
      final items = ar.getElements(
        'class.mod block book-all-list@class.bd@tag.li@class.right',
      );
      expect(items.length, 2);
      final ia = AnalyzeRule(items.first, 'https://test.com', pool);
      expect(ia.getString('class.name@text'), '苍穹');
    });

    test('exclude modifier li!0', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final items = ar.getElements('.txt-list@tag.ul@tag.li!0');
      expect(items.length, 2);
    });

    test('bare tag with index a.0@href', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      expect(ar.getString('a.0@href'), '/book/1');
    });

    test('|| cascade CSS', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      expect(ar.getString('h5@text||h4@text'), '斗破苍穹');
    });

    test('|| cascade elements', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final items = ar.getElements('.nonexistent||.grid-item');
      expect(items.length, 2);
    });

    test('## regex post-processing', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final res = ar.getString('class.info@ownText##作者：');
      expect(res, isNotEmpty);
      expect(res.startsWith('作者：'), isFalse);
    });

    test('|| cascade with ## post-processing', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final res = ar.getString('class.author@text||class.info@ownText##作者：');
      expect(res, isNotEmpty);
    });

    test('percent interleave', () {
      const html =
          '<div><span class="a">A1</span><span class="a">A2</span><span class="b">B1</span><span class="b">B2</span></div>';
      final ar = AnalyzeRule(html, 'https://test.com', JsPool(1));
      expect(ar.getString('.a@text%%.b@text'), 'A1 B1 A2 B2');
    });

    test('ownText and bracket negative index', () {
      const html =
          '<div class="info">作者：<span>天蚕土豆</span> 玄幻</div><a href="/1">一</a><a href="/2">二</a>';
      final ar = AnalyzeRule(html, 'https://test.com', JsPool(1));
      expect(ar.getString('.info@ownText'), '作者： 玄幻');
      expect(ar.getString('a[-1]@href'), '/2');
    });
  });

  group('XPath', () {
    test('xpath text and attribute extraction', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      expect(ar.getString('//div[@class="book-like"]/a[1]/h4/text()'), '斗破苍穹');
      expect(ar.getString('//div[@class="book-like"]/a[2]/@href'), '/book/2');
    });

    test('xpath getElements preserves child structure', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final items = ar.getElements('//div[@class="book-like"]/a');
      expect(items.length, 2);
      final itemAr = AnalyzeRule(items.first, 'https://test.com', JsPool(1));
      expect(itemAr.getString('//h4/text()'), '斗破苍穹');
    });
  });

  group('Inline Templates', () {
    test('CSS expression template', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final name = ar.getString(r'{{@h4@text||h3@text||""}}{{$.name||""}}');
      expect(name, '斗破苍穹');
    });

    test('|| cascade inside template', () {
      final ar = AnalyzeRule(_testHTMLFull, 'https://test.com', JsPool(1));
      final name = ar.getString('{{@h3@text||h4@text||""}}');
      expect(name, '斗破苍穹');
    });
  });

  group('JSONPath', () {
    test('getElements on JSON array', () {
      final ar = AnalyzeRule(_testJSON, 'https://test.com', JsPool(1));
      final items = ar.getElements(r'$[*]');
      expect(items.length, 2);
    });

    test('field extraction from JSON item', () {
      final pool = JsPool(1);
      final ar = AnalyzeRule(_testJSON, 'https://test.com', pool);
      final items = ar.getElements(r'$[*]');
      final ia = AnalyzeRule(items.first, 'https://test.com', pool);
      expect(ia.getString(r'{{@h4@text||h3@text||""}}{{$.name||""}}'), '斗破苍穹');
      expect(ia.getString(r'{{@span@text||""}}{{$.author||""}}'), '天蚕土豆');
    });

    test('&& concatenation on JSON', () {
      final ar = AnalyzeRule(
        '{"tags":"玄幻","category":"小说","status":"完结","update":"2024-01-01"}',
        'https://test.com',
        JsPool(1),
      );
      expect(
        ar.getString(r'$.tags&&$.category&&$.status&&$.update'),
        '玄幻 小说 完结 2024-01-01',
      );
    });
  });

  group('JS Stubs', () {
    test('cookie defined as object', () {
      final js = JSInterpreter();
      injectLegadoStubs(js);
      final v = js.eval('typeof cookie');
      expect(v.toString(), 'object');
    });

    test('source.getKey defined as function', () {
      final js = JSInterpreter();
      injectLegadoStubs(js);
      final v = js.eval('typeof source.getKey');
      expect(v.toString(), 'function');
    });

    test('createRegExp works', () {
      final js = JSInterpreter();
      injectLegadoStubs(js);
      final str = js.eval('createRegExp("test[1]").toString()');
      expect(str.toString(), '/test[1]/i');
      final unclosed = js.eval('createRegExp("test[").test("TEST[")');
      expect(unclosed.toBoolean(), isTrue);
    });

    test('java.getElements parses setContent HTML', () {
      final js = JSInterpreter();
      injectLegadoStubs(js);
      js.eval(
        'java.setContent("<div><a href=\'/1\'>A</a><a href=\'/2\'>B</a></div>")',
      );
      final v = js.eval('java.getElements("a").length');
      expect(v.toNumber(), 2);
    });

    test('java.get reads redirect Location header', () async {
      final readyPort = ReceivePort();
      final stopPort = ReceivePort();
      final isolate = await Isolate.spawn(_redirectServerIsolate, [
        readyPort.sendPort,
        stopPort.sendPort,
      ]);
      final serverPort = await readyPort.first as int;
      addTearDown(() {
        stopPort.close();
        readyPort.close();
        isolate.kill(priority: Isolate.immediate);
      });

      final js = JSInterpreter();
      injectLegadoStubs(js);
      final v = js.eval(
        'java.get("http://127.0.0.1:$serverPort/search", {}).header("location")',
      );
      expect(v.toString(), '/result?searchid=123');
    });
  });
}

Future<void> _redirectServerIsolate(List<Object?> args) async {
  final readySend = args[0] as SendPort;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  readySend.send(server.port);
  await for (final req in server) {
    req.response.statusCode = HttpStatus.found;
    req.response.headers.set('Location', '/result?searchid=123');
    await req.response.close();
  }
}
