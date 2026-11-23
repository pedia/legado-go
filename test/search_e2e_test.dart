import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

const String _aliceSearchHTML = '''<html><body>
<div class="list-group">
  <div class="list-group-item">
    <h5><a href="/book/1/">1.斗破苍穹[已完结]</a></h5>
    <p class="mb-1"><a href="/author/1/">天蚕土豆</a></p>
    <span class="s4">玄幻</span>
  </div>
  <div class="list-group-item">
    <h5><a href="/book/2/">2.武动乾坤[连载中]</a></h5>
    <p class="mb-1"><a href="/author/2/">天蚕土豆</a></p>
    <span class="s4">玄幻</span>
  </div>
</div>
</body></html>''';

const String _diyibanzhuHTML = '''<html><body>
<div class="mod block book-all-list">
  <div class="bd">
    <div class="right">
      <a class="name" href="/book/100/">斗破苍穹</a>
      <span class="author">天蚕土豆</span>
    </div>
    <div class="right">
      <a class="name" href="/book/200/">武动乾坤</a>
      <span class="author">天蚕土豆</span>
    </div>
  </div>
</div>
</body></html>''';

const String _coverHTML = '''<html><body>
<div class="cover">
  <p><a href="/s.php">First</a><a href="/book/1/">斗破苍穹</a><a href="/author/">天蚕土豆</a></p>
  <p><a href="/s.php">First</a><a href="/book/2/">武动乾坤</a><a href="/author/">土豆</a></p>
</div>
</body></html>''';

const String _lineHTML = '''<html><body>
<div class="line">
  <a href="/1">Index</a>
  <a href="/book/1/">斗破苍穹</a>
  <a href="/author/">天蚕土豆</a>
</div>
<div class="line">
  <a href="/2">Index</a>
  <a href="/book/2/">武动乾坤</a>
  <a href="/author/">土豆</a>
</div>
</body></html>''';

const String _searchJSON =
    '[{"name":"斗破苍穹","author":"天蚕土豆","cover":"/c/1.jpg","intro":"萧炎的传奇","kind":"玄幻","lastChapter":"第一千两百章","wordCount":"322万"},{"name":"武动乾坤","author":"天蚕土豆","cover":"/c/2.jpg","intro":"林动的故事","kind":"玄幻","lastChapter":"第八百章","wordCount":"280万"}]';

void main() {
  test('loadSources loads enabled sources from doc/example.json', () async {
    final sources = await loadSources('doc/example.json');
    expect(sources, isNotEmpty);
    expect(sources.every((s) => s.enabled), isTrue);
  });

  test('SearchUrl POST with GBK charset', () {
    final pool = JsPool(2);
    const searchUrl =
        '/s.php,{"method":"POST","body":"type=articlename&s={{key}}","charset":"gbk"}';
    final a = AnalyzeUrl(searchUrl, '斗破', 1, 'http://i.12bz.net', '', pool);
    expect(a.method, 'POST');
    expect(a.charset, 'gbk');
    expect(a.body, contains('斗破'));
  });

  test('SearchUrl angle bracket page', () {
    final pool = JsPool(2);
    const searchUrl = '/book/search/{{key}}<,/{{page}}>';
    final a = AnalyzeUrl(searchUrl, '斗破', 1, 'https://sesebooks.com', '', pool);
    expect(a.finalUrl.contains('<') || a.finalUrl.contains('>'), isFalse);
    expect(a.finalUrl.contains('page'), isFalse);

    final a2 = AnalyzeUrl(
      searchUrl,
      '斗破',
      2,
      'https://sesebooks.com',
      '',
      pool,
    );
    expect(a2.finalUrl, contains('/2'));
  });

  test('SearchUrl source comment eval', () {
    final pool = JsPool(2);
    const searchUrl =
        '{{cookie.removeCookie(source.getKey());eval(String(source.bookSourceComment))}}';
    const comment =
        "result = 'https://www.aakkrr.com/book/' + encodeURIComponent(key) + '<,/1>'";
    final a = AnalyzeUrl(
      searchUrl,
      '斗破',
      1,
      'https://www.aahhss.com',
      '',
      pool,
    );
    a.setComment(comment);
    expect(a.finalUrl.contains('{{'), isFalse);
    expect(a.finalUrl, contains('aakkrr.com'));
  });

  test('SearchUrl query param key and page', () {
    final pool = JsPool(2);
    const searchUrl =
        'https://www.alicesw.com/search.html?q={{key}}&p={{page}}';
    final a = AnalyzeUrl(
      searchUrl,
      '斗破',
      2,
      'https://www.alicesw.com',
      '',
      pool,
    );
    expect(a.finalUrl, contains('q='));
    expect(a.finalUrl, contains('p=2'));
  });

  test('SearchUrl relative path', () {
    final pool = JsPool(2);
    const searchUrl = '/e/search/,{"body":"keyboard={{key}}","method":"POST"}';
    final a = AnalyzeUrl(
      searchUrl,
      '斗破',
      1,
      'https://www.aahhss.com/',
      '',
      pool,
    );
    expect(a.finalUrl, startsWith('https://www.aahhss.com'));
    expect(a.method, 'POST');
  });

  test('CSS alicesw bookList', () {
    final pool = JsPool(2);
    final ar = AnalyzeRule(
      _aliceSearchHTML,
      'https://www.alicesw.com/search.html',
      pool,
    );
    final items = ar.getElements('class.list-group-item');
    expect(items.length, 2);
    final item = AnalyzeRule(items.first, 'https://www.alicesw.com', pool);
    final name = item.getString(r'h5@text##\d+\.|\[已完结\]|\[连载中\]');
    expect(name, contains('斗破苍穹'));
    expect(item.getString('class.mb-1@a@text'), '天蚕土豆');
  });

  test('CSS diyibanzhu bookList', () {
    final pool = JsPool(2);
    final ar = AnalyzeRule(
      _diyibanzhuHTML,
      'https://m.diyibanzhu2.online/',
      pool,
    );
    final items = ar.getElements(
      'class.mod block book-all-list@class.bd@class.right',
    );
    expect(items.length, 2);
    final item = AnalyzeRule(
      items.first,
      'https://m.diyibanzhu2.online/',
      pool,
    );
    expect(item.getString('class.name@text'), '斗破苍穹');
    expect(item.getString('class.author@text'), '天蚕土豆');
  });

  test('CSS cover p and tag.a.1', () {
    final pool = JsPool(2);
    final ar = AnalyzeRule(_coverHTML, 'http://i.12bz.net', pool);
    final items = ar.getElements('.cover@p');
    expect(items.length, 2);
    final item = AnalyzeRule(items.first, 'http://i.12bz.net', pool);
    expect(item.getString('tag.a.1@text'), '斗破苍穹');
  });

  test('CSS line items', () {
    final pool = JsPool(2);
    final ar = AnalyzeRule(_lineHTML, 'http://i.12bz.net', pool);
    final items = ar.getElements('class.line');
    expect(items.length, 2);
    final item = AnalyzeRule(items.first, 'http://i.12bz.net', pool);
    expect(item.getString('class.line@tag.a.1@text'), '斗破苍穹');
  });

  test('JSON search bookList', () {
    final pool = JsPool(2);
    final ar = AnalyzeRule(_searchJSON, 'https://api.example.com/search', pool);
    final items = ar.getElements(r'$[*]');
    expect(items.length, 2);
    final item = AnalyzeRule(items.first, 'https://api.example.com', pool);
    expect(item.getString(r'$.name'), '斗破苍穹');
    expect(item.getString(r'$.author'), '天蚕土豆');
    expect(item.getString(r'$.kind'), '玄幻');
  });

  test('SearchUrl double page pattern', () {
    final pool = JsPool(2);
    const searchUrl = 'search_top_{{key}}_691_{{page}}.html';
    final a = AnalyzeUrl(
      searchUrl,
      '斗破',
      3,
      'https://m.diyibanzhu2.online/',
      '',
      pool,
    );
    expect(a.finalUrl, contains('3.html'));
    expect(a.finalUrl, contains('691'));
  });
}
