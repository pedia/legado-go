import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

void main() {
  test('parseUrlOption single quote', () {
    final a = AnalyzeUrl.empty();
    a.parseUrlOption("{'method':'POST','body':'s=test'}");
    expect(a.method, 'POST');
    expect(a.body, 's=test');
  });

  test('parseUrlOption double quote', () {
    final a = AnalyzeUrl.empty();
    a.parseUrlOption('{"method":"POST","body":"s=hello"}');
    expect(a.method, 'POST');
    expect(a.body, 's=hello');
  });

  test('parseUrlOption with headers', () {
    final a = AnalyzeUrl.empty();
    a.parseUrlOption("{'method':'GET','headers':{'User-Agent':'TestBot'}}");
    expect(a.method, 'GET');
    expect(a.headerMap['User-Agent'], 'TestBot');
  });

  test('initUrl with POST body', () {
    final a = AnalyzeUrl(
      "/search.html,{'method':'POST','body':'s={{key}}'}",
      'test',
      1,
      'https://www.50zw.so',
      '',
    );
    expect(a.method, 'POST');
    expect(a.body, 's=test');
    expect(a.finalUrl, 'https://www.50zw.so/search.html');
  });

  test('singleToDoubleQuote', () {
    expect(singleToDoubleQuote("{'a':'b'}"), '{"a":"b"}');
    expect(singleToDoubleQuote('{"a":"b"}'), '{"a":"b"}');
    expect(
      singleToDoubleQuote("{'method':'POST','body':'s=test'}"),
      '{"method":"POST","body":"s=test"}',
    );
  });

  test('initUrl bare @js prefix', () {
    const ruleUrl =
        '@js:url=baseUrl+"/so/{{key}}.html,{\'method\':\'GET\',\'headers\':{\'User-Agent\':\'TestBot\',\'Referer\':\'https://www.qidian.com/\'}}";java.put(\'url\',url);result=url;';
    final a = AnalyzeUrl(ruleUrl, '斗破', 1, 'https://www.qidian.com', '');
    expect(a.jsCode, isNotEmpty);
  });

  test('inline expr cookie.removeCookie', () {
    final pool = JsPool(2);
    const searchUrl =
        '{{cookie.removeCookie("https://example.com")}}\nhttps://example.com/search/,{"body":"s={{key}}","method":"POST"}';
    final a = AnalyzeUrl(searchUrl, 'test', 1, 'https://example.com', '', pool);
    a.setComment('');
    expect(a.finalUrl.contains('cookie'), isFalse);
    expect(a.method, 'POST');
    expect(a.body, 's=test');
  });

  test('inline expr source.bookSourceComment eval', () {
    final pool = JsPool(2);
    const searchUrl =
        '{{cookie.removeCookie(source.getKey());eval(String(source.bookSourceComment))}}';
    const comment = "result = 'https://example.com/search/'";
    final a = AnalyzeUrl(searchUrl, 'test', 1, 'https://example.com', '', pool);
    a.setComment(comment);
    expect(a.finalUrl, 'https://example.com/search/');
  });

  test('angle bracket pages', () {
    final a = AnalyzeUrl.empty(page: 1);
    final res1 = a.resolveAngleBracketPages(r'/book/test<,/${page}>');
    expect(res1.contains('<') || res1.contains('>'), isFalse);

    a.page = 2;
    final res2 = a.resolveAngleBracketPages(r'/book/test<,/${page}>');
    expect(res2, contains('/2'));
  });

  test('findTemplateExpr', () {
    expect(findTemplateExpr('{{expr1}}rest').expr, 'expr1');
    expect(findTemplateExpr('prefix{{expr2}}suffix').expr, 'expr2');
    expect(findTemplateExpr('no template here').expr, '');
    expect(findTemplateExpr('{{a;b}}').expr, 'a;b');
  });

  test('GBK charset option parsed and raw key kept in body', () {
    final a = AnalyzeUrl(
      '/s.php,{"charset":"gbk","method":"POST","body":"s={{key}}"}',
      '斗破',
      1,
      'https://example.com',
      '',
    );
    expect(a.charset, 'gbk');
    expect(a.method, 'POST');
    expect(a.body, 's=斗破');
    expect(a.encodedRequestBody(), 's=%B6%B7%C6%C6');
  });

  test('inline expr page arithmetic', () {
    final pool = JsPool(1);
    final a = AnalyzeUrl(
      '/booklist/{{page-1}}.html',
      'test',
      3,
      'https://example.com',
      '',
      pool,
    );
    expect(a.finalUrl, 'https://example.com/booklist/2.html');
  });

  test('parseUrlOption extended fields and option JS', () {
    final pool = JsPool(1);
    final a = AnalyzeUrl(
      '/file,{"type":"bin","retry":"2","webView":"true","webJs":"return document.body.innerText","serverID":"7","webViewDelayTime":"300","proxy":"http://127.0.0.1:8888","js":"url=url+\'?x=1\';java.headerMap.put(\'X-Test\',\'ok\')"}',
      'test',
      1,
      'https://example.com',
      '',
      pool,
    );
    expect(a.type, 'bin');
    expect(a.retry, 2);
    expect(a.useWebView, isTrue);
    expect(a.webJs, isNotEmpty);
    expect(a.serverID, '7');
    expect(a.webViewDelay, 300);
    expect(a.proxy, 'http://127.0.0.1:8888');
    expect(a.headerMap['X-Test'], 'ok');
    expect(a.finalUrl, contains('?x=1'));
  });

  test('source header fragment with baseUrl replacement', () {
    final a = AnalyzeUrl(
      '/',
      'test',
      1,
      'https://example.com',
      '"User-Agent":"UA","Referer":"{{baseUrl}}"',
    );
    expect(a.headerMap['User-Agent'], 'UA');
    expect(a.headerMap['Referer'], 'https://example.com');
  });
}
