import 'dart:io';

import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer mockSite;
  late String mockBaseUrl;
  late NovelSource mockSource;

  setUp(() async {
    mockSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mockBaseUrl = 'http://127.0.0.1:${mockSite.port}';

    mockSite.listen((req) {
      final path = req.uri.path;
      req.response.headers.contentType = ContentType.html;
      if (path == '/search') {
        req.response.write('''
<html><body>
  <ul class="book-list">
    <li>
      <a class="title" href="/book/1">斗破苍穹</a>
      <span class="author">天蚕土豆</span>
      <img src="/cover/1.jpg" />
      <p class="intro">这里是属于斗气的世界</p>
      <span class="kind">玄幻</span>
      <span class="last">大结局</span>
    </li>
  </ul>
</body></html>
''');
      } else if (path == '/book/1') {
        req.response.write('''
<html><body>
  <h1 class="book-name">斗破苍穹</h1>
  <span class="book-author">天蚕土豆</span>
  <div class="cover"><img src="/cover/1.jpg" /></div>
  <div class="book-intro">三十年河东，三十年河西</div>
  <a class="toc-link" href="/book/1/toc">目录</a>
</body></html>
''');
      } else if (path == '/book/1/toc') {
        req.response.write('''
<html><body>
  <ul class="chapter-list">
    <li><a href="/book/1/ch/1">第一章 陨落的天才</a></li>
    <li><a href="/book/1/ch/2">第二章 斗气大陆</a></li>
  </ul>
  <a class="next-toc" href="/book/1/toc2">下一页</a>
</body></html>
''');
      } else if (path == '/book/1/toc2') {
        req.response.write('''
<html><body>
  <ul class="chapter-list">
    <li><a href="/book/1/ch/3">第三章 萧炎</a></li>
  </ul>
</body></html>
''');
      } else if (path == '/book/1/ch/1') {
        req.response.write('''
<html><body>
  <div id="content">
    <p>斗之力，三段！</p>
    <p>请记住本书首发域名</p>
  </div>
  <a class="next-page" href="/book/1/ch/1_2">下一页</a>
</body></html>
''');
      } else if (path == '/book/1/ch/1_2') {
        req.response.write('''
<html><body>
  <div id="content">
    <p>望着测验魔石碑上面闪亮得甚至有些刺眼的五个大字。</p>
  </div>
</body></html>
''');
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      req.response.close();
    });

    mockSource = NovelSource(
      bookSourceName: 'MockBookSite',
      bookSourceUrl: mockBaseUrl,
      enabled: true,
      searchUrl: '/search?q={{key}}&page={{page}}',
      ruleSearch: const SearchRule(
        bookList: 'class.book-list@tag.li',
        name: 'class.title@text',
        author: 'class.author@text',
        bookUrl: 'class.title@href',
        coverUrl: 'tag.img@src',
        intro: 'class.intro@text',
        kind: 'class.kind@text',
        lastChapter: 'class.last@text',
      ),
      ruleNovelInfo: const NovelInfoRule(
        name: 'class.book-name@text',
        author: 'class.book-author@text',
        coverUrl: 'class.cover@tag.img@src',
        intro: 'class.book-intro@text',
        tocUrl: 'class.toc-link@href',
      ),
      ruleToc: const TocRule(
        chapterList: 'class.chapter-list@tag.li',
        chapterName: 'tag.a@text',
        chapterUrl: 'tag.a@href',
        nextTocUrl: 'class.next-toc@href',
      ),
      ruleContent: const ContentRule(
        content: 'id.content@text',
        nextContentUrl: 'class.next-page@href',
      ),
    );
  });

  tearDown(() async {
    await mockSite.close(force: true);
  });

  test('SearchBook.toNovel converts search result into Novel', () {
    const sb = SearchBook(
      name: '斗破苍穹',
      author: '天蚕土豆',
      bookUrl: 'https://example.com/book/1',
      origin: 'https://example.com',
      originName: 'Example',
    );
    final novel = sb.toNovel();
    expect(novel, isA<Novel>());
    expect(novel.name, '斗破苍穹');
    expect(novel.author, '天蚕土豆');
    expect(novel.bookUrl, 'https://example.com/book/1');
  });

  test(
    'End-to-end webbook flow: search -> getNovelInfo -> chapters -> content',
    () async {
      final results = await searchBooks([mockSource], '斗破苍穹', 1);
      expect(results.length, 1);
      expect(results.first.name, '斗破苍穹');
      expect(results.first.author, '天蚕土豆');
      expect(results.first.bookUrl, '$mockBaseUrl/book/1');
      expect(results.first.coverUrl, '$mockBaseUrl/cover/1.jpg');

      final Novel? novel = await getNovelInfo(
        mockSource,
        results.first.bookUrl,
      );
      expect(novel, isNotNull);
      expect(novel!.name, '斗破苍穹');
      expect(novel.intro, '三十年河东，三十年河西');
      expect(novel.tocUrl, '$mockBaseUrl/book/1/toc');

      final chapters = await getChapterList(mockSource, novel);
      expect(chapters.length, 3);
      expect(chapters[0].title, '第一章 陨落的天才');
      expect(chapters[2].title, '第三章 萧炎');
      expect(chapters[2].index, 2);

      final content = await getContent(mockSource, novel, chapters.first);
      expect(content, contains('斗之力，三段！'));
      expect(content, contains('望着测验魔石碑'));
      expect(content, isNot(contains('请记住本书首发域名')));
    },
  );
}
