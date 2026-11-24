import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

void main() {
  group('Diagnostics unit tests', () {
    test(
      'NovelSource has independent runtime stats excluded from toJson()',
      () {
        final sourceA = NovelSource(
          bookSourceName: 'SourceA',
          bookSourceUrl: 'https://a.example',
          enabled: true,
        );
        final sourceB = NovelSource(
          bookSourceName: 'SourceB',
          bookSourceUrl: 'https://b.example',
          enabled: true,
        );

        sourceA.stats.recordSuccess(PipelineStage.search, 120);
        sourceA.stats.recordFailure(
          PipelineStage.content,
          45,
          FailureCategory.ruleMismatch,
          'Empty content',
        );

        expect(sourceA.stats.successCount, 1);
        expect(sourceA.stats.failedCount, 1);
        expect(sourceA.stats.totalCount, 2);
        expect(sourceA.stats.successRate, closeTo(0.5, 0.001));
        expect(sourceA.stats.avgDurationMs, closeTo(82.5, 0.1));
        expect(sourceA.stats.minDurationMs, 45);
        expect(sourceA.stats.maxDurationMs, 120);
        expect(sourceA.stats.forStage(PipelineStage.search).successCount, 1);
        expect(sourceA.stats.forStage(PipelineStage.content).failedCount, 1);
        expect(sourceA.stats.failureCounts[FailureCategory.ruleMismatch], 1);

        expect(sourceB.stats.totalCount, 0);

        expect(sourceA.toJson().containsKey('stats'), isFalse);
        expect(sourceA.toJsonWithStats()['stats'], isA<Map<String, dynamic>>());

        sourceA.stats.reset();
        expect(sourceA.stats.totalCount, 0);
        expect(sourceA.stats.failureCounts, isEmpty);
      },
    );

    test('FailureClassifier maps common exceptions to categories', () {
      expect(
        FailureClassifier.classify(TimeoutException('timed out')),
        FailureCategory.timeout,
      );
      expect(
        FailureClassifier.classify(
          const HttpException('HTTP 502: Bad Gateway'),
        ),
        FailureCategory.httpStatus,
      );
      expect(
        FailureClassifier.classify(const SocketException('Connection refused')),
        FailureCategory.network,
      );
      expect(
        FailureClassifier.classify(const FormatException('Unexpected char')),
        FailureCategory.parseOrScript,
      );
      expect(
        FailureClassifier.classify(
          StateError('empty final url after analyzing rule'),
        ),
        FailureCategory.emptyResponse,
      );
      expect(
        FailureClassifier.classify(
          StateError('no results matched rule "class.item" (body len=100)'),
        ),
        FailureCategory.ruleMismatch,
      );
    });

    test('GoproLogger filters by LogLevel and invokes onLog hook', () {
      final captured = <LogEntry>[];
      final logger = GoproLogger(
        minLevel: LogLevel.warn,
        collectEntries: true,
        onLog: captured.add,
      );

      logger.debug(
        stage: PipelineStage.search,
        sourceName: 'S1',
        sourceUrl: 'https://s1.test',
        message: 'debug ignored',
      );
      logger.info(
        stage: PipelineStage.search,
        sourceName: 'S1',
        sourceUrl: 'https://s1.test',
        message: 'info ignored',
      );
      logger.warn(
        stage: PipelineStage.chapterList,
        sourceName: 'S1',
        sourceUrl: 'https://s1.test',
        category: FailureCategory.timeout,
        durationMs: 250,
        message: 'page 2 timed out',
      );
      logger.error(
        stage: PipelineStage.content,
        sourceName: 'S1',
        sourceUrl: 'https://s1.test',
        category: FailureCategory.httpStatus,
        durationMs: 80,
        message: 'failed',
        error: const HttpException('HTTP 500'),
      );

      expect(captured.length, 2);
      expect(logger.entries.length, 2);
      expect(captured[0].level, LogLevel.warn);
      expect(
        captured[0].formatLine(),
        '[WARN] [chapterList] [S1] (timeout, 250ms) page 2 timed out',
      );
      expect(captured[1].level, LogLevel.error);
      expect(captured[1].formatLine(), contains('[ERROR] [content] [S1]'));
    });

    test('SourceHealthSummaryFormatter renders table with stage breakdown', () {
      final s1 = NovelSource(
        bookSourceName: 'AlphaBook',
        bookSourceUrl: 'https://alpha.test',
        enabled: true,
      );
      s1.stats.recordSuccess(PipelineStage.search, 50);
      s1.stats.recordFailure(
        PipelineStage.content,
        150,
        FailureCategory.httpStatus,
        'HTTP 503',
      );

      final table = SourceHealthSummaryFormatter.format([
        s1,
      ], totalElapsedMs: 210);
      expect(table, contains('Source Health Summary (1 sources)'));
      expect(table, contains('AlphaBook'));
      expect(table, contains('S:1/0 C:0/1'));
      expect(table, contains('httpStatus: HTTP 503'));
      expect(
        table,
        contains(
          'Totals: requests=2, ok=1, fail=1, successRate=50.0%, '
          'failures=[httpStatus=1], elapsed=210ms',
        ),
      );
    });
  });

  group('Pipeline counters & leveled logging integration', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((req) {
        final path = req.uri.path;
        req.response.headers.contentType = ContentType.html;

        if (path == '/ok/search') {
          req.response.write('''
<html><body>
  <ul class="books">
    <li><a class="title" href="/ok/book/1">测试小说</a><span class="author">作者甲</span></li>
  </ul>
</body></html>''');
        } else if (path == '/ok/empty-body') {
          // HTTP 200 with empty body.
        } else if (path == '/fail/http500') {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.write('Internal Server Error');
        } else if (path == '/fail/bad-rule') {
          req.response.write('<html><body><p>no list here</p></body></html>');
        } else if (path == '/info/missing-name') {
          req.response.write(
            '<html><body><p>unexpected layout</p></body></html>',
          );
        } else if (path == '/toc/page1') {
          req.response.write('''
<html><body>
  <ul class="chaps"><li><a href="/content/ok">第一章</a></li></ul>
  <a class="next-toc" href="/fail/http500">下一页</a>
</body></html>''');
        } else if (path == '/content/ok') {
          req.response.write('''
<html><body>
  <div id="text">正文第一页内容。</div>
  <a class="next-content" href="/fail/http500">下一页</a>
</body></html>''');
        } else if (path == '/content/empty-extract') {
          req.response.write('<html><body><div>无匹配规则</div></body></html>');
        } else if (path == '/stall-body') {
          req.response.statusCode = HttpStatus.ok;
          req.response.write('<html><body>headers-only');
          req.response.flush();
          return;
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'searchBooksDetailed records per-source stats, errors, and logs',
      () async {
        final goodSource = NovelSource(
          bookSourceName: 'GoodSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/ok/search?q={{key}}',
          ruleSearch: const SearchRule(
            bookList: 'class.books@tag.li',
            name: 'class.title@text',
            author: 'class.author@text',
            bookUrl: 'class.title@href',
          ),
        );
        final httpFailSource = NovelSource(
          bookSourceName: 'Http500Source',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/fail/http500?q={{key}}',
          ruleSearch: const SearchRule(bookList: 'class.books@tag.li'),
        );
        final ruleFailSource = NovelSource(
          bookSourceName: 'RuleMismatchSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/fail/bad-rule?q={{key}}',
          ruleSearch: const SearchRule(bookList: 'class.books@tag.li'),
        );
        final emptyBodySource = NovelSource(
          bookSourceName: 'EmptyBodySource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/ok/empty-body?q={{key}}',
          ruleSearch: const SearchRule(bookList: 'class.books@tag.li'),
        );

        final logger = GoproLogger(
          minLevel: LogLevel.debug,
          collectEntries: true,
        );
        final report = await searchBooksDetailed(
          [goodSource, httpFailSource, ruleFailSource, emptyBodySource],
          '测试',
          1,
          4,
          logger,
        );

        expect(report.results.length, 1);
        expect(report.errors.length, 2);

        expect(goodSource.stats.successCount, 1);
        expect(goodSource.stats.failedCount, 0);

        expect(httpFailSource.stats.failedCount, 1);
        expect(
          httpFailSource.stats.lastFailureCategory,
          FailureCategory.httpStatus,
        );

        expect(ruleFailSource.stats.failedCount, 1);
        expect(
          ruleFailSource.stats.lastFailureCategory,
          FailureCategory.ruleMismatch,
        );

        expect(emptyBodySource.stats.failedCount, 1);
        expect(
          emptyBodySource.stats.lastFailureCategory,
          FailureCategory.emptyResponse,
        );

        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.info &&
                e.sourceName == 'GoodSource' &&
                e.stage == PipelineStage.search,
          ),
          isTrue,
        );
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.error &&
                e.sourceName == 'Http500Source' &&
                e.category == FailureCategory.httpStatus,
          ),
          isTrue,
        );
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.warn &&
                e.sourceName == 'EmptyBodySource' &&
                e.category == FailureCategory.emptyResponse,
          ),
          isTrue,
        );
      },
    );

    test('getNovelInfo logs warnings and errors and updates stats', () async {
      final source = NovelSource(
        bookSourceName: 'InfoSource',
        bookSourceUrl: baseUrl,
        enabled: true,
        ruleNovelInfo: const NovelInfoRule(name: 'h1@text'),
      );
      final logger = GoproLogger(minLevel: LogLevel.info, collectEntries: true);

      final emptyNovel = await getNovelInfo(
        source,
        '$baseUrl/ok/empty-body',
        logger: logger,
      );
      expect(emptyNovel, isNull);
      expect(source.stats.failedCount, 1);
      expect(source.stats.lastFailureCategory, FailureCategory.emptyResponse);

      final mismatched = await getNovelInfo(
        source,
        '$baseUrl/info/missing-name',
        logger: logger,
      );
      expect(mismatched, isNotNull);
      expect(mismatched!.name, isEmpty);
      expect(source.stats.failedCount, 2);
      expect(source.stats.lastFailureCategory, FailureCategory.ruleMismatch);

      await expectLater(
        getNovelInfo(source, '$baseUrl/fail/http500', logger: logger),
        throwsA(isA<HttpException>()),
      );
      expect(source.stats.failedCount, 3);
      expect(source.stats.lastFailureCategory, FailureCategory.httpStatus);
      expect(
        logger.entries.where((e) => e.stage == PipelineStage.novelInfo).length,
        3,
      );
    });

    test(
      'getChapterList logs page 2 pagination warning and page 1 errors',
      () async {
        final source = NovelSource(
          bookSourceName: 'TocSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          ruleToc: const TocRule(
            chapterList: 'class.chaps@tag.li',
            chapterName: 'tag.a@text',
            chapterUrl: 'tag.a@href',
            nextTocUrl: 'class.next-toc@href',
          ),
        );
        final logger = GoproLogger(
          minLevel: LogLevel.info,
          collectEntries: true,
        );

        // Page 1 succeeds, page 2 hits /fail/http500 -> emits warn log and returns page 1 chapters.
        final partialChapters = await getChapterList(
          source,
          Novel(name: 'Book', bookUrl: '$baseUrl/toc/page1'),
          logger: logger,
        );
        expect(partialChapters.length, 1);
        expect(
          source.stats.forStage(PipelineStage.chapterList).successCount,
          1,
        );
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.warn &&
                e.stage == PipelineStage.chapterList &&
                e.category == FailureCategory.httpStatus &&
                e.message.contains('pagination stopped on page 2'),
          ),
          isTrue,
        );

        // Page 1 fails -> emits error log, increments failedCount, rethrows.
        await expectLater(
          getChapterList(
            source,
            Novel(name: 'BrokenBook', bookUrl: '$baseUrl/fail/http500'),
            logger: logger,
          ),
          throwsA(isA<HttpException>()),
        );
        expect(source.stats.forStage(PipelineStage.chapterList).failedCount, 1);
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.error &&
                e.stage == PipelineStage.chapterList &&
                e.category == FailureCategory.httpStatus,
          ),
          isTrue,
        );
      },
    );

    test(
      'getContent logs extraction failure, pagination warning, and counters',
      () async {
        final source = NovelSource(
          bookSourceName: 'ContentSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          ruleContent: const ContentRule(
            content: 'id.text@text',
            nextContentUrl: 'class.next-content@href',
          ),
        );
        final logger = GoproLogger(
          minLevel: LogLevel.info,
          collectEntries: true,
        );
        const novel = Novel(name: 'Book');

        // Empty chapter URL -> warn + emptyResponse failure counter.
        final emptyUrlContent = await getContent(
          source,
          novel,
          const BookChapter(title: '空链接章', url: ''),
          logger: logger,
        );
        expect(emptyUrlContent, isEmpty);
        expect(source.stats.failedCount, 1);
        expect(source.stats.lastFailureCategory, FailureCategory.emptyResponse);

        // Non-empty HTML that misses id.text rule -> warn + ruleMismatch failure counter.
        final missedContent = await getContent(
          source,
          novel,
          BookChapter(title: '规则失效章', url: '$baseUrl/content/empty-extract'),
          logger: logger,
        );
        expect(missedContent, isEmpty);
        expect(source.stats.failedCount, 2);
        expect(source.stats.lastFailureCategory, FailureCategory.ruleMismatch);

        // Page 1 succeeds, page 2 fails -> warn log + returns page 1 content + success counter.
        final partialContent = await getContent(
          source,
          novel,
          BookChapter(title: '分页异常章', url: '$baseUrl/content/ok'),
          logger: logger,
        );
        expect(partialContent, '正文第一页内容。');
        expect(source.stats.successCount, 1);
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.warn &&
                e.stage == PipelineStage.content &&
                e.message.contains('pagination stopped on page 2'),
          ),
          isTrue,
        );

        // Page 1 HTTP 500 -> error log + failure counter + rethrows.
        await expectLater(
          getContent(
            source,
            novel,
            BookChapter(title: '报错章', url: '$baseUrl/fail/http500'),
            logger: logger,
          ),
          throwsA(isA<HttpException>()),
        );
        expect(source.stats.failedCount, 3);
        expect(
          logger.entries.any(
            (e) =>
                e.level == LogLevel.error &&
                e.stage == PipelineStage.content &&
                e.category == FailureCategory.httpStatus,
          ),
          isTrue,
        );
      },
    );

    test(
      'CLI writes clean JSON to stdout and leveled logs + health summary to stderr',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('gopro_diag_cli_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final sourcesFile = File('${tempDir.path}/sources.json');
        final okSrc = NovelSource(
          bookSourceName: 'CliOkSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/ok/search?q={{key}}',
          ruleSearch: const SearchRule(
            bookList: 'class.books@tag.li',
            name: 'class.title@text',
            author: 'class.author@text',
            bookUrl: 'class.title@href',
          ),
        );
        final errSrc = NovelSource(
          bookSourceName: 'CliErrSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/fail/http500?q={{key}}',
          ruleSearch: const SearchRule(bookList: 'class.books@tag.li'),
        );
        sourcesFile.writeAsStringSync(
          jsonEncode([okSrc.toJson(), errSrc.toJson()]),
        );

        final res = await Process.run('dart', [
          'run',
          'bin/gopro.dart',
          '-l',
          'debug',
          sourcesFile.path,
          'search',
          '测试',
        ]);

        expect(res.exitCode, 0, reason: 'stderr:\n${res.stderr}');

        final decoded = jsonDecode(res.stdout.toString());
        expect(decoded, isA<List<dynamic>>());
        expect((decoded as List<dynamic>).length, 1);

        final errOut = res.stderr.toString();
        expect(errOut, contains('[DEBUG] [search] [CliOkSource]'));
        expect(errOut, contains('[INFO] [search] [CliOkSource]'));
        expect(errOut, contains('[ERROR] [search] [CliErrSource]'));
        expect(errOut, contains('Source Health Summary'));
        expect(errOut, contains('CliOkSource'));
        expect(errOut, contains('CliErrSource'));
        expect(errOut, contains('failures=[httpStatus=1]'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'stalled response body times out cleanly and watchdog reports hung source',
      () async {
        final stallServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => stallServer.close(force: true));
        final stallBaseUrl = 'http://127.0.0.1:${stallServer.port}';

        stallServer.listen((req) async {
          if (req.uri.path == '/stall-body') {
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.html;
            req.response.write('<html><body>partial ');
            await req.response.flush();
            // Intentionally keep the stream open without closing to simulate a tarpit.
            return;
          }
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><body><ul class="books"><li><a class="t" href="/b/1">快书</a></li></ul></body></html>',
          );
          await req.response.close();
        });

        final fastSrc = NovelSource(
          bookSourceName: 'FastSource',
          bookSourceUrl: stallBaseUrl,
          enabled: true,
          searchUrl: '/fast?q={{key}}',
          ruleSearch: const SearchRule(
            bookList: 'class.books@tag.li',
            name: 'class.t@text',
            bookUrl: 'class.t@href',
          ),
        );
        final stalledSrc = NovelSource(
          bookSourceName: 'StalledBodySource',
          bookSourceUrl: stallBaseUrl,
          enabled: true,
          searchUrl: '/stall-body?q={{key}}',
          ruleSearch: const SearchRule(
            bookList: 'class.books@tag.li',
            name: 'class.t@text',
          ),
        );

        final logger = GoproLogger(
          minLevel: LogLevel.debug,
          collectEntries: true,
        );
        final sw = Stopwatch()..start();
        final report = await searchBooksDetailed(
          [fastSrc, stalledSrc],
          'test',
          1,
          2,
          logger,
          const Duration(milliseconds: 450),
          const Duration(milliseconds: 120),
        );
        sw.stop();

        expect(report.results.length, 1);
        expect(report.errors.length, 1);
        expect(report.errors.single.category, FailureCategory.timeout);
        expect(stalledSrc.stats.failedCount, 1);
        expect(stalledSrc.stats.lastFailureCategory, FailureCategory.timeout);
        expect(sw.elapsedMilliseconds, lessThan(3000));

        expect(
          logger.entries.any(
            (e) =>
                e.sourceName == 'watchdog' &&
                e.message.contains('StalledBodySource') &&
                e.message.contains('http-request'),
          ),
          isTrue,
        );
      },
    );

    test(
      'CLI --timeout and --source filter isolate and bound hung sources',
      () async {
        final stallServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => stallServer.close(force: true));
        final stallBaseUrl = 'http://127.0.0.1:${stallServer.port}';

        stallServer.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.write('<html><body>headers-only');
          await req.response.flush();
          // Intentionally never close to trigger CLI --timeout=1.
        });

        final tempDir = Directory.systemTemp.createTempSync('gopro_to_cli_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final sourcesFile = File('${tempDir.path}/sources.json');
        final s1 = NovelSource(
          bookSourceName: 'SkipSource',
          bookSourceUrl: stallBaseUrl,
          enabled: true,
          searchUrl: '/skip?q={{key}}',
        );
        final s2 = NovelSource(
          bookSourceName: 'TargetHungSource',
          bookSourceUrl: stallBaseUrl,
          enabled: true,
          searchUrl: '/hung?q={{key}}',
        );
        sourcesFile.writeAsStringSync(jsonEncode([s1.toJson(), s2.toJson()]));

        final res = await Process.run('dart', [
          'run',
          'bin/gopro.dart',
          '-t',
          '1',
          '-c',
          '4',
          '-s',
          'TargetHung',
          '-l',
          'info',
          sourcesFile.path,
          'search',
          '青山',
        ]);

        expect(res.exitCode, 0, reason: 'stderr:\n${res.stderr}');
        expect(jsonDecode(res.stdout.toString()), isEmpty);
        final errOut = res.stderr.toString();
        expect(errOut, contains('Loaded 1 enabled sources (filtered from 2)'));
        expect(errOut, contains('TargetHungSource'));
        expect(errOut, contains('failures=[timeout=1]'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'synchronous java.connect hang in one source is killed at timeout without blocking fast sources',
      () async {
        final fastSrc = NovelSource(
          bookSourceName: 'FastAfterJsHang',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl: '/ok/search?q={{key}}',
          ruleSearch: const SearchRule(
            bookList: 'class.books@tag.li',
            name: 'class.title@text',
            author: 'class.author@text',
            bookUrl: 'class.title@href',
          ),
        );
        final jsHangSrc = NovelSource(
          bookSourceName: 'HungJavaConnectSource',
          bookSourceUrl: baseUrl,
          enabled: true,
          searchUrl:
              '{{(function(){for(var i=0;i<3;i++){java.connect("$baseUrl/stall-body");}return "";})()}}/ok/search?q={{key}}',
          ruleSearch: const SearchRule(bookList: 'class.books@tag.li'),
        );

        final logger = GoproLogger(
          minLevel: LogLevel.warn,
          collectEntries: true,
        );
        final sw = Stopwatch()..start();
        final report = await searchBooksDetailed(
          [jsHangSrc, fastSrc],
          '测试',
          1,
          2,
          logger,
          const Duration(milliseconds: 400),
          const Duration(milliseconds: 120),
        );
        sw.stop();

        expect(report.results.length, 1);
        expect(report.results.single.originName, 'FastAfterJsHang');
        expect(report.errors.length, 1);
        expect(report.errors.single.category, FailureCategory.timeout);
        expect(jsHangSrc.stats.failedCount, 1);
        expect(jsHangSrc.stats.lastFailureCategory, FailureCategory.timeout);
        expect(sw.elapsedMilliseconds, lessThan(4000));
        expect(
          logger.entries.any(
            (e) =>
                e.sourceName == 'watchdog' &&
                e.message.contains('HungJavaConnectSource'),
          ),
          isTrue,
        );
      },
    );
  });
}
