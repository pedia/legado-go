import 'dart:async';
import 'dart:isolate';

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

class _InFlightSource {
  final String sourceName;
  final String sourceUrl;
  final DateTime startedAt;
  String phase;
  String detail;

  _InFlightSource({
    required this.sourceName,
    required this.sourceUrl,
    required this.startedAt,
    required this.phase,
    required this.detail,
  });
}

class _SearchWorkerIsolate {
  final Isolate isolate;
  final SendPort commandPort;

  _SearchWorkerIsolate(this.isolate, this.commandPort);

  static Future<_SearchWorkerIsolate> spawn() async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(_searchWorkerEntry, readyPort.sendPort);
    final commandPort = await readyPort.first as SendPort;
    readyPort.close();
    return _SearchWorkerIsolate(isolate, commandPort);
  }

  void shutdown() {
    try {
      commandPort.send(null);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
    }
  }

  void kill() {
    isolate.kill(priority: Isolate.immediate);
  }
}

/// Searches novels across multiple sources concurrently.
Future<List<SearchBook>> searchBooks(
  List<NovelSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  GoproLogger? logger,
  Duration timeout = const Duration(seconds: 15),
]) async {
  final report = await searchBooksDetailed(
    sources,
    key,
    page,
    maxConcurrency,
    logger,
    timeout,
  );
  return report.results;
}

/// Like [searchBooks] but runs source searches in isolated workers so
/// synchronous JS or `java.connect` stalls in one source cannot block other
/// sources or the watchdog timer, and can be forcefully terminated at [timeout].
Future<SearchReport> searchBooksDetailed(
  List<NovelSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  GoproLogger? logger,
  Duration timeout = const Duration(seconds: 15),
  Duration heartbeatInterval = const Duration(seconds: 5),
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
    final inFlight = <int, _InFlightSource>{};
    var completedCount = 0;
    var okSourceCount = 0;
    var lastProgressAt = DateTime.now();

    Timer? heartbeat;
    if (heartbeatInterval > Duration.zero && activeSources.isNotEmpty) {
      heartbeat = Timer.periodic(heartbeatInterval, (_) {
        if (inFlight.isEmpty) return;
        final now = DateTime.now();
        final activeList = inFlight.values.toList()
          ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
        final slowest = activeList.first;
        final slowestMs = now.difference(slowest.startedAt).inMilliseconds;
        final stalled =
            now.difference(lastProgressAt) >= heartbeatInterval ||
            slowestMs >= heartbeatInterval.inMilliseconds;

        final topSlow = [
          for (final entry in activeList.take(3))
            '${entry.sourceName}(${(now.difference(entry.startedAt).inMilliseconds / 1000).toStringAsFixed(1)}s ${entry.phase})',
        ].join(', ');

        effectiveLogger.log(
          level: stalled ? LogLevel.warn : LogLevel.info,
          stage: PipelineStage.search,
          sourceName: 'watchdog',
          sourceUrl: '',
          durationMs: slowestMs,
          message:
              'Progress $completedCount/${activeSources.length} '
              '(ok=$okSourceCount, fail=${errors.length}, '
              'inFlight=${inFlight.length}); waiting on: $topSlow'
              '${slowest.detail.isNotEmpty ? " [${slowest.detail}]" : ""}',
        );
      });
    }

    final bridgePort = SyncHttpBridge.activePort;
    var nextIndex = 0;

    Future<void> workerSlot() async {
      _SearchWorkerIsolate? worker;
      try {
        while (nextIndex < activeSources.length) {
          final idx = nextIndex++;
          final src = activeSources[idx];
          worker ??= await _SearchWorkerIsolate.spawn();

          final flight = _InFlightSource(
            sourceName: src.bookSourceName,
            sourceUrl: src.bookSourceUrl,
            startedAt: DateTime.now(),
            phase: 'init-url',
            detail: src.searchUrl,
          );
          inFlight[idx] = flight;

          final outcome = await _runInWorkerIsolate(
            worker: worker,
            source: src,
            key: key,
            page: page,
            timeout: timeout,
            bridgePort: bridgePort,
            logger: effectiveLogger,
            flight: flight,
          );

          if (outcome.timedOut) {
            worker.kill();
            worker = null;
          }

          inFlight.remove(idx);
          completedCount++;
          lastProgressAt = DateTime.now();

          if (outcome.error != null) {
            errors.add(outcome.error!);
          } else {
            results.addAll(outcome.results);
            if (outcome.results.isNotEmpty) okSourceCount++;
          }
        }
      } finally {
        worker?.shutdown();
      }
    }

    try {
      final workerCount = concurrency < activeSources.length
          ? concurrency
          : activeSources.length;
      await Future.wait([for (var i = 0; i < workerCount; i++) workerSlot()]);
    } finally {
      heartbeat?.cancel();
    }

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
  }, timeout: timeout);
}

Future<({List<SearchBook> results, SourceError? error, bool timedOut})>
_runInWorkerIsolate({
  required _SearchWorkerIsolate worker,
  required NovelSource source,
  required String key,
  required int page,
  required Duration timeout,
  required int? bridgePort,
  required GoproLogger logger,
  required _InFlightSource flight,
}) async {
  final replyPort = ReceivePort();
  final doneCompleter = Completer<Map<String, dynamic>>();
  Timer? deadlineTimer;

  final sub = replyPort.listen((msg) {
    if (msg is! Map) return;
    final kind = msg['kind'] as String?;
    switch (kind) {
      case 'phase':
        flight.phase = (msg['phase'] ?? '') as String;
        flight.detail = (msg['detail'] ?? '') as String;
      case 'log':
        final entry = msg['entry'];
        if (entry is LogEntry) {
          logger.log(
            level: entry.level,
            stage: entry.stage,
            sourceName: entry.sourceName,
            sourceUrl: entry.sourceUrl,
            category: entry.category,
            durationMs: entry.durationMs,
            message: entry.message,
            error: entry.error,
          );
        }
      case 'done':
        if (!doneCompleter.isCompleted) {
          doneCompleter.complete(msg.cast<String, dynamic>());
        }
    }
  });

  if (timeout > Duration.zero) {
    // Allow a small grace window beyond [timeout] so cooperative async
    // HTTP timeouts report first before forcibly killing synchronous hangs.
    deadlineTimer = Timer(timeout + const Duration(milliseconds: 500), () {
      if (!doneCompleter.isCompleted) {
        doneCompleter.complete({'timedOut': true});
      }
    });
  }

  try {
    worker.commandPort.send({
      'source': source.toJson(),
      'key': key,
      'page': page,
      'timeoutMs': timeout.inMilliseconds,
      'minLevel': logger.minLevel.index,
      'bridgePort': bridgePort,
      'replyPort': replyPort.sendPort,
    });

    final msg = await doneCompleter.future;
    if (msg['timedOut'] == true) {
      final elapsedMs = DateTime.now()
          .difference(flight.startedAt)
          .inMilliseconds;
      final timeoutErr = TimeoutException(
        'Source search timed out during ${flight.phase} (${flight.detail})',
        timeout,
      );
      final summary = FailureClassifier.summarizeError(timeoutErr);
      source.stats.recordFailure(
        PipelineStage.search,
        elapsedMs,
        FailureCategory.timeout,
        summary,
      );
      logger.error(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: FailureCategory.timeout,
        durationMs: elapsedMs,
        message: 'Search timed out for "$key" (killed hung worker)',
        error: timeoutErr,
      );
      return (
        results: const <SearchBook>[],
        error: SourceError(
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          stage: PipelineStage.search.label,
          category: FailureCategory.timeout,
          durationMs: elapsedMs,
          error: timeoutErr.toString(),
        ),
        timedOut: true,
      );
    }

    final durationMs = (msg['durationMs'] as num?)?.toInt() ?? 0;
    final ok = msg['ok'] == true;
    if (ok) {
      final rawItems = (msg['results'] as List<dynamic>? ?? const []);
      final items = [
        for (final item in rawItems)
          if (item is Map)
            SearchBook.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
      ];
      final recordedFailure = msg['recordedFailure'] == true;
      if (recordedFailure) {
        final catIdx = (msg['category'] as num?)?.toInt();
        final category =
            (catIdx != null &&
                catIdx >= 0 &&
                catIdx < FailureCategory.values.length)
            ? FailureCategory.values[catIdx]
            : FailureCategory.ruleMismatch;
        source.stats.recordFailure(
          PipelineStage.search,
          durationMs,
          category,
          (msg['error'] ?? '') as String,
        );
      } else {
        source.stats.recordSuccess(PipelineStage.search, durationMs);
      }
      return (results: items, error: null, timedOut: false);
    }

    final catIdx = (msg['category'] as num?)?.toInt();
    final category =
        (catIdx != null &&
            catIdx >= 0 &&
            catIdx < FailureCategory.values.length)
        ? FailureCategory.values[catIdx]
        : FailureCategory.unknown;
    final errText = (msg['error'] ?? 'Unknown search error') as String;
    source.stats.recordFailure(
      PipelineStage.search,
      durationMs,
      category,
      FailureClassifier.summarizeError(errText),
    );
    return (
      results: const <SearchBook>[],
      error: SourceError(
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        stage: PipelineStage.search.label,
        category: category,
        durationMs: durationMs,
        error: errText,
      ),
      timedOut: false,
    );
  } finally {
    deadlineTimer?.cancel();
    await sub.cancel();
    replyPort.close();
  }
}

Future<void> _searchWorkerEntry(SendPort mainHandshake) async {
  final commandPort = ReceivePort();
  mainHandshake.send(commandPort.sendPort);

  await for (final raw in commandPort) {
    if (raw == null) {
      commandPort.close();
      break;
    }
    if (raw is! Map) continue;

    final replyPort = raw['replyPort'] as SendPort;
    final sourceJson = (raw['source'] as Map).cast<String, dynamic>();
    final key = raw['key'] as String;
    final page = raw['page'] as int;
    final timeoutMs = (raw['timeoutMs'] as num?)?.toInt() ?? 15000;
    final minLevelIdx =
        (raw['minLevel'] as num?)?.toInt() ?? LogLevel.warn.index;
    final bridgePort = raw['bridgePort'] as int?;

    SyncHttpBridge.externalPort = bridgePort;
    final timeout = Duration(milliseconds: timeoutMs);
    SyncHttpBridge.defaultTimeout = timeout > Duration.zero
        ? timeout
        : const Duration(seconds: 15);

    final localSource = NovelSource.fromJson(sourceJson);
    final workerLogger = GoproLogger(
      minLevel: LogLevel.values[minLevelIdx],
      onLog: (entry) => replyPort.send({'kind': 'log', 'entry': entry}),
    );

    final sw = Stopwatch()..start();
    try {
      final found = await searchFromSource(
        localSource,
        key,
        page,
        logger: workerLogger,
        timeout: timeout,
        onPhase: (phase, detail) =>
            replyPort.send({'kind': 'phase', 'phase': phase, 'detail': detail}),
      );
      sw.stop();
      final recordedFailure = localSource.stats.failedCount > 0;
      replyPort.send({
        'kind': 'done',
        'ok': true,
        'durationMs':
            localSource.stats.lastDurationMs ?? sw.elapsedMilliseconds,
        'results': [for (final item in found) item.toJson()],
        'recordedFailure': recordedFailure,
        if (recordedFailure)
          'category': localSource.stats.lastFailureCategory?.index,
        if (recordedFailure) 'error': localSource.stats.lastError ?? '',
      });
    } catch (e) {
      sw.stop();
      replyPort.send({
        'kind': 'done',
        'ok': false,
        'durationMs':
            localSource.stats.lastDurationMs ?? sw.elapsedMilliseconds,
        'category':
            (localSource.stats.lastFailureCategory ??
                    FailureClassifier.classify(e))
                .index,
        'error': e.toString(),
      });
    }
  }
}

/// Searches novels from a single [source].
Future<List<SearchBook>> searchFromSource(
  NovelSource source,
  String key,
  int page, {
  GoproLogger? logger,
  Duration timeout = const Duration(seconds: 15),
  void Function(String phase, String detail)? onPhase,
}) {
  final log = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final sw = Stopwatch()..start();

    Future<List<SearchBook>> execute() async {
      onPhase?.call('init-url', source.searchUrl);
      log.debug(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message: 'Preparing search key="$key" page=$page (${source.searchUrl})',
      );

      final aurl = AnalyzeUrl(
        source.searchUrl,
        key,
        page,
        source.bookSourceUrl,
        source.header,
      )..setComment(source.bookSourceComment);

      final targetLabel = aurl.finalUrl.isNotEmpty
          ? aurl.finalUrl
          : source.searchUrl;
      onPhase?.call('http-request', targetLabel);
      log.debug(
        stage: PipelineStage.search,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message: 'Requesting ${aurl.method} $targetLabel',
      );

      final body = await aurl.getStrResponse(timeout: timeout);
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

      onPhase?.call('parse-rules', bookListRule);
      final ar = AnalyzeRule(body, aurl.finalUrl);
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
    }

    try {
      final run = execute();
      return timeout > Duration.zero ? await run.timeout(timeout) : await run;
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
  }, timeout: timeout);
}
