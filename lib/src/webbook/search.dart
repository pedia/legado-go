import 'dart:async';

import '../analyzer/analyzer.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../diagnostics/diagnostics.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

class SourceError {
  final String sourceName;
  final String sourceUrl;
  final String stage;
  final FailureCategory category;
  final int durationMs;
  final String error;

  const SourceError({
    required this.sourceName,
    required this.sourceUrl,
    required this.stage,
    required this.error,
    this.category = FailureCategory.unknown,
    this.durationMs = 0,
  });

  Map<String, dynamic> toJson() => {
    'sourceName': sourceName,
    'sourceUrl': sourceUrl,
    'stage': stage,
    'category': category.label,
    'durationMs': durationMs,
    'error': error,
  };
}

class SearchReport {
  final List<SearchBook> results;
  final List<SourceError> errors;
  final List<LogEntry> logs;
  final List<Map<String, dynamic>> sourceStats;

  const SearchReport({
    required this.results,
    this.errors = const [],
    this.logs = const [],
    this.sourceStats = const [],
  });

  Map<String, dynamic> toJson() => {
    'results': results.map((r) => r.toJson()).toList(),
    if (errors.isNotEmpty) 'errors': errors.map((e) => e.toJson()).toList(),
    if (logs.isNotEmpty) 'logs': logs.map((l) => l.toJson()).toList(),
    if (sourceStats.isNotEmpty) 'sourceStats': sourceStats,
  };
}

/// Searches novels across multiple sources concurrently.
Future<List<SearchBook>> searchBooks(
  List<NovelSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  GoproLogger? logger,
]) async {
  final report = await searchBooksDetailed(
    sources,
    key,
    page,
    maxConcurrency,
    logger,
  );
  return report.results;
}

/// Like [searchBooks] but preserves per-source diagnostics and logs.
Future<SearchReport> searchBooksDetailed(
  List<NovelSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  GoproLogger? logger,
]) {
  final effectiveLogger = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final concurrency = maxConcurrency <= 0 ? 10 : maxConcurrency;
    final activeSources = [
      for (final s in sources)
        if (s.enabled && s.searchUrl.isNotEmpty) s,
    ];

    final results = <SearchBook>[];
    final errors = <SourceError>[];

    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < activeSources.length) {
        final src = activeSources[nextIndex++];
        try {
          results.addAll(
            await searchFromSource(src, key, page, logger: effectiveLogger),
          );
        } catch (e) {
          errors.add(
            SourceError(
              sourceName: src.bookSourceName,
              sourceUrl: src.bookSourceUrl,
              stage: PipelineStage.search.label,
              category: FailureClassifier.classify(e),
              durationMs: src.stats.lastDurationMs ?? 0,
              error: e.toString(),
            ),
          );
        }
      }
    }

    final workerCount = concurrency < activeSources.length
        ? concurrency
        : activeSources.length;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);

    return SearchReport(
      results: results,
      errors: errors,
      logs: effectiveLogger.entries,
      sourceStats: [
        for (final src in activeSources)
          {
            'sourceName': src.bookSourceName,
            'sourceUrl': src.bookSourceUrl,
            ...src.stats.toJson(),
          },
      ],
    );
  });
}

/// Searches novels from a single [source].
Future<List<SearchBook>> searchFromSource(
  NovelSource source,
  String key,
  int page, {
  GoproLogger? logger,
}) {
  final log = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final sw = Stopwatch()..start();
    try {
      final aurl = AnalyzeUrl(
        source.searchUrl,
        key,
        page,
        source.bookSourceUrl,
        source.header,
      )..setComment(source.bookSourceComment);

      log.debug(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message: 'Searching key="$key" page=$page -> ${aurl.finalUrl}',
      );

      final body = await aurl.getStrResponse();
      if (body.isEmpty) {
        sw.stop();
        const msg = 'Empty HTTP response body';
        source.stats.recordFailure(
          PipelineStage.search,
          sw.elapsedMilliseconds,
          FailureCategory.emptyResponse,
          msg,
        );
        log.warn(
          stage: PipelineStage.search,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: FailureCategory.emptyResponse,
          durationMs: sw.elapsedMilliseconds,
          message: 'Search returned empty response body (${aurl.finalUrl})',
        );
        return const [];
      }

      final ar = AnalyzeRule(body, aurl.finalUrl);
      final bookListRule = source.ruleSearch.bookList;
      if (bookListRule.isEmpty) {
        sw.stop();
        const msg = 'Empty ruleSearch.bookList';
        source.stats.recordFailure(
          PipelineStage.search,
          sw.elapsedMilliseconds,
          FailureCategory.ruleMismatch,
          msg,
        );
        log.warn(
          stage: PipelineStage.search,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: FailureCategory.ruleMismatch,
          durationMs: sw.elapsedMilliseconds,
          message: 'Search skipped: ruleSearch.bookList is empty',
        );
        return const [];
      }

      final bookItems = ar.getElements(bookListRule);
      if (bookItems.isEmpty) {
        throw StateError(
          'no results matched rule "$bookListRule" (body len=${body.length})',
        );
      }

      final items = <SearchBook>[];
      for (final item in bookItems) {
        final itemAr = AnalyzeRule(item, aurl.finalUrl);
        var bookUrl = itemAr.getString(source.ruleSearch.bookUrl);
        var coverUrl = itemAr.getString(source.ruleSearch.coverUrl);

        if (bookUrl.isNotEmpty) {
          bookUrl = resolveWebUrl(aurl.finalUrl, bookUrl);
        }
        if (coverUrl.isNotEmpty) {
          coverUrl = resolveWebUrl(aurl.finalUrl, coverUrl);
        }

        final found = SearchBook(
          name: itemAr.getString(source.ruleSearch.name),
          author: itemAr.getString(source.ruleSearch.author),
          coverUrl: coverUrl,
          intro: itemAr.getString(source.ruleSearch.intro),
          kind: itemAr.getString(source.ruleSearch.kind),
          lastChapter: itemAr.getString(source.ruleSearch.lastChapter),
          wordCount: itemAr.getString(source.ruleSearch.wordCount),
          bookUrl: bookUrl,
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
        );

        if (found.name.isNotEmpty) {
          items.add(found);
        }
      }

      sw.stop();
      if (items.isEmpty) {
        final msg =
            'Matched ${bookItems.length} item(s) with "$bookListRule" '
            'but extracted 0 titles';
        source.stats.recordFailure(
          PipelineStage.search,
          sw.elapsedMilliseconds,
          FailureCategory.ruleMismatch,
          msg,
        );
        log.warn(
          stage: PipelineStage.search,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: FailureCategory.ruleMismatch,
          durationMs: sw.elapsedMilliseconds,
          message: msg,
        );
        return const [];
      }

      source.stats.recordSuccess(PipelineStage.search, sw.elapsedMilliseconds);
      log.info(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        durationMs: sw.elapsedMilliseconds,
        message: 'Extracted ${items.length} search result(s) for "$key"',
      );
      return items;
    } catch (e) {
      sw.stop();
      final category = FailureClassifier.classify(e);
      final summary = FailureClassifier.summarizeError(e);
      source.stats.recordFailure(
        PipelineStage.search,
        sw.elapsedMilliseconds,
        category,
        summary,
      );
      log.error(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: category,
        durationMs: sw.elapsedMilliseconds,
        message: 'Search failed for "$key"',
        error: e,
      );
      rethrow;
    }
  });
}
