import 'dart:convert';
import 'dart:io';

import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

void main() {
  group('parseSearchCliOutput', () {
    test('handles null and empty output like Go nil slice', () {
      expect(parseSearchCliOutput(''), isEmpty);
      expect(parseSearchCliOutput('null\n'), isEmpty);
      expect(parseSearchCliOutput('[]'), isEmpty);
    });

    test('parses JSON array of SearchBook items', () {
      const jsonOut = '''
[
  {
    "name": "斗破苍穹",
    "author": "天蚕土豆",
    "coverUrl": "https://a.com/c.jpg",
    "intro": "简介",
    "kind": "玄幻",
    "lastChapter": "第100章",
    "bookUrl": "https://a.com/1",
    "wordCount": "100万",
    "origin": "https://a.com",
    "originName": "SiteA"
  }
]
''';
      final items = parseSearchCliOutput(jsonOut);
      expect(items.length, 1);
      expect(items.first.name, '斗破苍穹');
      expect(items.first.originName, 'SiteA');
    });
  });

  group('compareSearchResults', () {
    const itemA = SearchBook(
      name: '斗破苍穹',
      author: '天蚕土豆',
      bookUrl: 'https://a.com/1',
      origin: 'https://a.com',
      originName: 'SiteA',
    );
    const itemB = SearchBook(
      name: '武动乾坤',
      author: '天蚕土豆',
      bookUrl: 'https://b.com/2',
      origin: 'https://b.com',
      originName: 'SiteB',
    );

    test('matches identical results regardless of ordering', () {
      final report = compareSearchResults(
        goResults: const [itemA, itemB],
        dartResults: const [itemB, itemA],
      );
      expect(report.isMatch, isTrue);
      expect(report.matchedCount, 2);
      expect(report.goOnly, isEmpty);
      expect(report.dartOnly, isEmpty);
      expect(report.fieldDiffs, isEmpty);
      expect(report.format(), contains('Status      : MATCH'));
    });

    test('reports goOnly and dartOnly items', () {
      final report = compareSearchResults(
        goResults: const [itemA],
        dartResults: const [itemB],
      );
      expect(report.isMatch, isFalse);
      expect(report.goOnly, [itemA]);
      expect(report.dartOnly, [itemB]);
    });

    test('detects field diffs on matched items and respects ignoreFields', () {
      final dartModified = itemA.copyWith(
        author: '土豆',
        intro: 'slightly different',
      );
      final report = compareSearchResults(
        goResults: const [itemA],
        dartResults: [dartModified],
      );
      expect(report.isMatch, isFalse);
      expect(report.matchedCount, 1);
      expect(report.fieldDiffs.length, 1);
      expect(
        report.fieldDiffs.first.diffs.map((d) => d.field),
        containsAll(['author', 'intro']),
      );

      final ignoredReport = compareSearchResults(
        goResults: const [itemA],
        dartResults: [dartModified],
        ignoreFields: {'author', 'intro'},
      );
      expect(ignoredReport.isMatch, isTrue);
    });

    test('pairs same origin+name when bookUrl differs', () {
      final dartUrlDiff = itemA.copyWith(bookUrl: 'https://a.com/book/1');
      final report = compareSearchResults(
        goResults: const [itemA],
        dartResults: [dartUrlDiff],
      );
      expect(report.isMatch, isFalse);
      expect(report.goOnly, isEmpty);
      expect(report.dartOnly, isEmpty);
      expect(report.fieldDiffs.length, 1);
      expect(report.fieldDiffs.first.diffs.single.field, 'bookUrl');
    });
  });

  test('splitCommandLine handles quoted paths and arguments', () {
    expect(splitCommandLine('go run "my dir/reader.go" -flag=\'a b\''), [
      'go',
      'run',
      'my dir/reader.go',
      '-flag=a b',
    ]);
  });

  test(
    'bin/compare_cli.dart compares Dart CLI against Go output end-to-end',
    () async {
      final mockSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => mockSite.close(force: true));
      final baseUrl = 'http://127.0.0.1:${mockSite.port}';

      mockSite.listen((req) {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
<html><body>
  <ul class="books">
    <li>
      <a class="name" href="/book/10">斗破苍穹</a>
      <span class="author">天蚕土豆</span>
    </li>
  </ul>
</body></html>
''');
        req.response.close();
      });

      final tempDir = Directory.systemTemp.createTempSync('gopro_cmp_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final sourcesFile = File('${tempDir.path}/sources.json');
      final source = BookSource(
        bookSourceName: 'TestSource',
        bookSourceUrl: baseUrl,
        enabled: true,
        searchUrl: '/search?q={{key}}',
        ruleSearch: const SearchRule(
          bookList: 'class.books@tag.li',
          name: 'class.name@text',
          author: 'class.author@text',
          bookUrl: 'class.name@href',
        ),
      );
      sourcesFile.writeAsStringSync(jsonEncode([source.toJson()]));

      final goOutFile = File('${tempDir.path}/go_out.json');
      goOutFile.writeAsStringSync(
        jsonEncode([
          SearchBook(
            name: '斗破苍穹',
            author: '天蚕土豆',
            bookUrl: '$baseUrl/book/10',
            origin: baseUrl,
            originName: 'TestSource',
          ).toJson(),
        ]),
      );

      final res = await Process.run('dart', [
        'run',
        'bin/compare_cli.dart',
        '--dart-cmd=dart run bin/gopro.dart',
        '--go-output=${goOutFile.path}',
        sourcesFile.path,
        'search',
        '斗破苍穹',
      ]);

      expect(
        res.exitCode,
        0,
        reason: 'stdout:\n${res.stdout}\nstderr:\n${res.stderr}',
      );
      expect(res.stdout.toString(), contains('Status      : MATCH'));
    },
  );
}
