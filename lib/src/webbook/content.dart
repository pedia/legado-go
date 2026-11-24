import '../analyzer/analyzer.dart';
import '../analyzer/regex.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../diagnostics/diagnostics.dart';
import '../model/chapter.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches the content of a [chapter], handling `nextContentUrl` pagination.
Future<String> getContent(
  NovelSource source,
  Novel novel,
  BookChapter chapter, {
  GoproLogger? logger,
  Duration timeout = const Duration(seconds: 15),
}) {
  final log = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final sw = Stopwatch()..start();
    if (chapter.url.isEmpty) {
      sw.stop();
      final msg = 'Chapter "${chapter.title}" has empty URL';
      source.stats.recordFailure(
        PipelineStage.content,
        sw.elapsedMilliseconds,
        FailureCategory.emptyResponse,
        msg,
      );
      log.warn(
        stage: PipelineStage.content,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: FailureCategory.emptyResponse,
        durationMs: sw.elapsedMilliseconds,
        message: 'Cannot extract content: $msg',
      );
      return '';
    }

    final contentParts = <String>[];
    final visited = <String>{};
    const maxPages = 10;

    var currentUrl = chapter.url;
    var pagesFetched = 0;
    FailureCategory? firstPageIssueCategory;
    String? firstPageIssueMessage;

    for (var i = 0; i < maxPages; i++) {
      if (currentUrl.isEmpty || !visited.add(currentUrl)) {
        break;
      }

      log.debug(
        stage: PipelineStage.content,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message:
            'Extracting content page ${i + 1} for "${chapter.title}": $currentUrl',
      );

      try {
        final pageResult = await _parseContentPage(source, currentUrl, timeout);
        pagesFetched++;
        if (pageResult.content.isNotEmpty) {
          contentParts.add(pageResult.content);
        } else if (i == 0 && pageResult.issueMessage != null) {
          firstPageIssueCategory = pageResult.issueCategory;
          firstPageIssueMessage = pageResult.issueMessage;
        }
        currentUrl = pageResult.nextUrl;
      } catch (e) {
        final category = FailureClassifier.classify(e);
        final summary = FailureClassifier.summarizeError(e);
        if (i == 0) {
          sw.stop();
          source.stats.recordFailure(
            PipelineStage.content,
            sw.elapsedMilliseconds,
            category,
            summary,
          );
          log.error(
            stage: PipelineStage.content,
            sourceName: source.bookSourceName,
            sourceUrl: source.bookSourceUrl,
            category: category,
            durationMs: sw.elapsedMilliseconds,
            message:
                'Content extraction failed for "${chapter.title}" ($currentUrl)',
            error: e,
          );
          rethrow;
        }

        log.warn(
          stage: PipelineStage.content,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: category,
          durationMs: sw.elapsedMilliseconds,
          message:
              'Content pagination stopped on page ${i + 1} ($currentUrl) '
              'for "${chapter.title}"',
          error: e,
        );
        break;
      }
    }

    sw.stop();
    final joined = contentParts.join('\n');
    if (joined.isEmpty) {
      final category = firstPageIssueCategory ?? FailureCategory.ruleMismatch;
      final msg =
          firstPageIssueMessage ??
          'Extracted empty content for "${chapter.title}" '
              'with rule "${source.ruleContent.content}"';
      source.stats.recordFailure(
        PipelineStage.content,
        sw.elapsedMilliseconds,
        category,
        msg,
      );
      log.warn(
        stage: PipelineStage.content,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: category,
        durationMs: sw.elapsedMilliseconds,
        message: msg,
      );
      return '';
    }

    source.stats.recordSuccess(PipelineStage.content, sw.elapsedMilliseconds);
    log.info(
      stage: PipelineStage.content,
      sourceName: source.bookSourceName,
      sourceUrl: source.bookSourceUrl,
      durationMs: sw.elapsedMilliseconds,
      message:
          'Extracted ${joined.length} chars across $pagesFetched page(s) '
          'for "${chapter.title}"',
    );
    return joined;
  });
}

Future<
  ({
    String content,
    String nextUrl,
    FailureCategory? issueCategory,
    String? issueMessage,
  })
>
_parseContentPage(NovelSource source, String pageUrl, Duration timeout) async {
  final aurl = AnalyzeUrl(pageUrl, '', 0, source.bookSourceUrl, source.header);

  final body = await aurl.getStrResponse(timeout: timeout);
  if (body.isEmpty) {
    return (
      content: '',
      nextUrl: '',
      issueCategory: FailureCategory.emptyResponse,
      issueMessage: 'Content page returned empty HTTP body ($pageUrl)',
    );
  }

  final ar = AnalyzeRule(body, aurl.finalUrl);
  final contentRule = source.ruleContent;

  if (contentRule.content.isEmpty) {
    return (
      content: '',
      nextUrl: '',
      issueCategory: FailureCategory.ruleMismatch,
      issueMessage: 'Empty ruleContent.content',
    );
  }

  var content = ar.getString(contentRule.content);

  if (content.isNotEmpty) {
    content = content.trim();
    if (contentRule.replaceRegex.isNotEmpty) {
      content = applyRegex(contentRule.replaceRegex, content);
    }
    content = cleanContent(content);
  }

  var nextUrl = '';
  if (contentRule.nextContentUrl.isNotEmpty) {
    nextUrl = ar.getString(contentRule.nextContentUrl);
    if (nextUrl.isNotEmpty) {
      nextUrl = resolveWebUrl(aurl.finalUrl, nextUrl);
    }
  }

  return (
    content: content,
    nextUrl: nextUrl,
    issueCategory: content.isEmpty ? FailureCategory.ruleMismatch : null,
    issueMessage: content.isEmpty
        ? 'Extracted empty content with rule "${contentRule.content}" '
              '(body len=${body.length})'
        : null,
  );
}

/// Removes common ad patterns and normalizes whitespace lines.
String cleanContent(String raw) {
  var content = raw;
  const adPatterns = [
    '请到最新章节',
    '手机阅读：',
    '一秒记住',
    '请记住本书首发域名',
    '天才一秒记住',
    '最新章节！',
  ];

  for (final pattern in adPatterns) {
    final idx = content.indexOf(pattern);
    if (idx != -1) {
      final endIdx = content.indexOf('\n', idx);
      content = endIdx != -1
          ? content.substring(0, idx) + content.substring(endIdx + 1)
          : content.substring(0, idx);
    }
  }

  return [
    for (final line in content.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ].join('\n');
}
