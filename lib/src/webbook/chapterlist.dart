import '../analyzer/analyzer.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../diagnostics/diagnostics.dart';
import '../model/chapter.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches the table of contents for a [novel], handling `nextTocUrl` pagination.
Future<List<BookChapter>> getChapterList(
  NovelSource source,
  Novel novel, {
  GoproLogger? logger,
}) {
  final log = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final sw = Stopwatch()..start();
    final initialUrl = novel.tocUrl.isNotEmpty ? novel.tocUrl : novel.bookUrl;
    if (initialUrl.isEmpty) {
      sw.stop();
      const msg = 'Empty TOC and book URL';
      source.stats.recordFailure(
        PipelineStage.chapterList,
        sw.elapsedMilliseconds,
        FailureCategory.emptyResponse,
        msg,
      );
      log.warn(
        stage: PipelineStage.chapterList,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: FailureCategory.emptyResponse,
        durationMs: sw.elapsedMilliseconds,
        message: 'Cannot fetch chapters for "${novel.name}": $msg',
      );
      return const [];
    }

    var tocUrl = initialUrl;
    final allChapters = <BookChapter>[];
    final visited = <String>{};
    const maxPages = 20;

    var pagesFetched = 0;
    FailureCategory? firstPageIssueCategory;
    String? firstPageIssueMessage;

    for (var i = 0; i < maxPages; i++) {
      if (tocUrl.isEmpty || !visited.add(tocUrl)) {
        break;
      }

      log.debug(
        stage: PipelineStage.chapterList,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message: 'Fetching chapter list page ${i + 1}: $tocUrl',
      );

      try {
        final pageResult = await _parseChapterPage(source, tocUrl);
        pagesFetched++;
        allChapters.addAll(pageResult.chapters);
        if (i == 0 && pageResult.issueMessage != null) {
          firstPageIssueCategory = pageResult.issueCategory;
          firstPageIssueMessage = pageResult.issueMessage;
        }
        tocUrl = pageResult.nextUrl;
      } catch (e) {
        final category = FailureClassifier.classify(e);
        final summary = FailureClassifier.summarizeError(e);
        if (i == 0) {
          sw.stop();
          source.stats.recordFailure(
            PipelineStage.chapterList,
            sw.elapsedMilliseconds,
            category,
            summary,
          );
          log.error(
            stage: PipelineStage.chapterList,
            sourceName: source.bookSourceName,
            sourceUrl: source.bookSourceUrl,
            category: category,
            durationMs: sw.elapsedMilliseconds,
            message: 'Chapter list failed on page 1 ($tocUrl)',
            error: e,
          );
          rethrow;
        }

        log.warn(
          stage: PipelineStage.chapterList,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: category,
          durationMs: sw.elapsedMilliseconds,
          message:
              'Chapter pagination stopped on page ${i + 1} ($tocUrl), '
              'keeping ${allChapters.length} chapter(s)',
          error: e,
        );
        break;
      }
    }

    sw.stop();
    if (allChapters.isEmpty) {
      final category = firstPageIssueCategory ?? FailureCategory.ruleMismatch;
      final msg =
          firstPageIssueMessage ??
          'Extracted 0 chapters from $initialUrl with rule "${source.ruleToc.chapterList}"';
      source.stats.recordFailure(
        PipelineStage.chapterList,
        sw.elapsedMilliseconds,
        category,
        msg,
      );
      log.warn(
        stage: PipelineStage.chapterList,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: category,
        durationMs: sw.elapsedMilliseconds,
        message: msg,
      );
      return const [];
    }

    source.stats.recordSuccess(
      PipelineStage.chapterList,
      sw.elapsedMilliseconds,
    );
    log.info(
      stage: PipelineStage.chapterList,
      sourceName: source.bookSourceName,
      sourceUrl: source.bookSourceUrl,
      durationMs: sw.elapsedMilliseconds,
      message:
          'Extracted ${allChapters.length} chapter(s) across $pagesFetched page(s)',
    );

    return [
      for (var i = 0; i < allChapters.length; i++)
        allChapters[i].copyWith(index: i, bookUrl: novel.bookUrl),
    ];
  });
}

Future<
  ({
    List<BookChapter> chapters,
    String nextUrl,
    FailureCategory? issueCategory,
    String? issueMessage,
  })
>
_parseChapterPage(NovelSource source, String pageUrl) async {
  final aurl = AnalyzeUrl(pageUrl, '', 0, source.bookSourceUrl, source.header);

  final body = await aurl.getStrResponse();
  if (body.isEmpty) {
    return (
      chapters: const <BookChapter>[],
      nextUrl: '',
      issueCategory: FailureCategory.emptyResponse,
      issueMessage: 'Chapter list page returned empty HTTP body ($pageUrl)',
    );
  }

  final ar = AnalyzeRule(body, aurl.finalUrl);
  final tocRule = source.ruleToc;

  var listRule = tocRule.chapterList;
  if (listRule.isEmpty) {
    return (
      chapters: const <BookChapter>[],
      nextUrl: '',
      issueCategory: FailureCategory.ruleMismatch,
      issueMessage: 'Empty ruleToc.chapterList',
    );
  }

  var reverse = false;
  if (listRule.startsWith('-')) {
    reverse = true;
    listRule = listRule.substring(1);
  }

  final chapterElements = ar.getElements(listRule);
  if (chapterElements.isEmpty) {
    return (
      chapters: const <BookChapter>[],
      nextUrl: '',
      issueCategory: FailureCategory.ruleMismatch,
      issueMessage:
          'No chapters matched rule "$listRule" (body len=${body.length})',
    );
  }

  var chapters = <BookChapter>[];
  for (final elem in chapterElements) {
    final elemAr = AnalyzeRule(elem, aurl.finalUrl);
    final chapterName = tocRule.chapterName.isNotEmpty
        ? elemAr.getString(tocRule.chapterName)
        : '';
    var chapterUrl = tocRule.chapterUrl.isNotEmpty
        ? elemAr.getString(tocRule.chapterUrl)
        : '';
    if (chapterUrl.isNotEmpty) {
      chapterUrl = resolveWebUrl(aurl.finalUrl, chapterUrl);
    }

    if (chapterName.isNotEmpty || chapterUrl.isNotEmpty) {
      chapters.add(BookChapter(title: chapterName, url: chapterUrl));
    }
  }

  if (reverse) {
    chapters = chapters.reversed.toList();
  }

  var nextUrl = '';
  if (tocRule.nextTocUrl.isNotEmpty) {
    nextUrl = ar.getString(tocRule.nextTocUrl);
    if (nextUrl.isNotEmpty) {
      nextUrl = resolveWebUrl(aurl.finalUrl, nextUrl);
    }
  }

  return (
    chapters: chapters,
    nextUrl: nextUrl,
    issueCategory: chapters.isEmpty ? FailureCategory.ruleMismatch : null,
    issueMessage: chapters.isEmpty
        ? 'Matched ${chapterElements.length} element(s) with "$listRule" '
              'but extracted 0 chapters'
        : null,
  );
}
