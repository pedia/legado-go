import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../model/novel_source.dart';

/// Pipeline stages instrumented for per-source counters and logging.
enum PipelineStage {
  search('search', 'S'),
  novelInfo('novelInfo', 'I'),
  chapterList('chapterList', 'T'),
  content('content', 'C');

  final String label;
  final String shortCode;

  const PipelineStage(this.label, this.shortCode);
}

/// High-level failure classification for source requests and rule extraction.
enum FailureCategory {
  network('network'),
  timeout('timeout'),
  httpStatus('httpStatus'),
  ruleMismatch('ruleMismatch'),
  emptyResponse('emptyResponse'),
  parseOrScript('parseOrScript'),
  unknown('unknown');

  final String label;

  const FailureCategory(this.label);
}

/// Log severity levels ordered from most verbose to silent.
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR'),
  off(4, 'OFF');

  final int severity;
  final String label;

  const LogLevel(this.severity, this.label);

  /// Parses a CLI/config string into a [LogLevel].
  static LogLevel parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'info':
        return LogLevel.info;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'error':
        return LogLevel.error;
      case 'off':
      case 'none':
      case 'silent':
        return LogLevel.off;
      default:
        throw FormatException(
          'Invalid log level "$raw". Expected one of: debug, info, warn, error, off.',
        );
    }
  }
}

/// Per-stage execution counters and latency metrics.
class StageStats {
  int successCount = 0;
  int failedCount = 0;
  int totalDurationMs = 0;
  int? minDurationMs;
  int? maxDurationMs;
  int? lastDurationMs;
  FailureCategory? lastFailureCategory;
  String? lastError;

  StageStats();

  StageStats._copy(StageStats other)
    : successCount = other.successCount,
      failedCount = other.failedCount,
      totalDurationMs = other.totalDurationMs,
      minDurationMs = other.minDurationMs,
      maxDurationMs = other.maxDurationMs,
      lastDurationMs = other.lastDurationMs,
      lastFailureCategory = other.lastFailureCategory,
      lastError = other.lastError;

  int get totalCount => successCount + failedCount;

  double get avgDurationMs =>
      totalCount == 0 ? 0.0 : totalDurationMs / totalCount;

  double get successRate => totalCount == 0 ? 0.0 : successCount / totalCount;

  void recordSuccess(int durationMs) {
    final safeMs = durationMs < 0 ? 0 : durationMs;
    successCount++;
    _recordLatency(safeMs);
  }

  void recordFailure(
    int durationMs,
    FailureCategory category,
    String errorMessage,
  ) {
    final safeMs = durationMs < 0 ? 0 : durationMs;
    failedCount++;
    _recordLatency(safeMs);
    lastFailureCategory = category;
    lastError = errorMessage;
  }

  void _recordLatency(int durationMs) {
    totalDurationMs += durationMs;
    lastDurationMs = durationMs;
    final currentMin = minDurationMs;
    if (currentMin == null || durationMs < currentMin) {
      minDurationMs = durationMs;
    }
    final currentMax = maxDurationMs;
    if (currentMax == null || durationMs > currentMax) {
      maxDurationMs = durationMs;
    }
  }

  void reset() {
    successCount = 0;
    failedCount = 0;
    totalDurationMs = 0;
    minDurationMs = null;
    maxDurationMs = null;
    lastDurationMs = null;
    lastFailureCategory = null;
    lastError = null;
  }

  StageStats snapshot() => StageStats._copy(this);

  Map<String, dynamic> toJson() => {
    'success': successCount,
    'failed': failedCount,
    'total': totalCount,
    'avgDurationMs': double.parse(avgDurationMs.toStringAsFixed(1)),
    if (minDurationMs != null) 'minDurationMs': minDurationMs,
    if (maxDurationMs != null) 'maxDurationMs': maxDurationMs,
    if (lastDurationMs != null) 'lastDurationMs': lastDurationMs,
    if (lastFailureCategory != null)
      'lastFailureCategory': lastFailureCategory!.label,
    if (lastError != null) 'lastError': lastError,
  };
}

/// Runtime in-memory counters attached to each [NovelSource].
class SourceStats {
  final Map<PipelineStage, StageStats> _stages;
  final Map<FailureCategory, int> _failureCounts;
  PipelineStage? lastStage;
  FailureCategory? lastFailureCategory;
  String? lastError;
  int? lastDurationMs;
  DateTime? lastUpdatedAt;

  SourceStats()
    : _stages = {for (final stage in PipelineStage.values) stage: StageStats()},
      _failureCounts = {};

  SourceStats._copy(SourceStats other)
    : _stages = {
        for (final entry in other._stages.entries)
          entry.key: entry.value.snapshot(),
      },
      _failureCounts = Map<FailureCategory, int>.from(other._failureCounts),
      lastStage = other.lastStage,
      lastFailureCategory = other.lastFailureCategory,
      lastError = other.lastError,
      lastDurationMs = other.lastDurationMs,
      lastUpdatedAt = other.lastUpdatedAt;

  int get successCount {
    var total = 0;
    for (final stage in _stages.values) {
      total += stage.successCount;
    }
    return total;
  }

  int get failedCount {
    var total = 0;
    for (final stage in _stages.values) {
      total += stage.failedCount;
    }
    return total;
  }

  int get totalCount => successCount + failedCount;

  int get totalDurationMs {
    var total = 0;
    for (final stage in _stages.values) {
      total += stage.totalDurationMs;
    }
    return total;
  }

  double get avgDurationMs =>
      totalCount == 0 ? 0.0 : totalDurationMs / totalCount;

  int? get minDurationMs {
    int? minVal;
    for (final stage in _stages.values) {
      final candidate = stage.minDurationMs;
      if (candidate != null && (minVal == null || candidate < minVal)) {
        minVal = candidate;
      }
    }
    return minVal;
  }

  int? get maxDurationMs {
    int? maxVal;
    for (final stage in _stages.values) {
      final candidate = stage.maxDurationMs;
      if (candidate != null && (maxVal == null || candidate > maxVal)) {
        maxVal = candidate;
      }
    }
    return maxVal;
  }

  double get successRate => totalCount == 0 ? 0.0 : successCount / totalCount;

  Map<PipelineStage, StageStats> get stages => Map.unmodifiable(_stages);

  Map<FailureCategory, int> get failureCounts =>
      Map.unmodifiable(_failureCounts);

  StageStats forStage(PipelineStage stage) => _stages[stage]!;

  void recordSuccess(PipelineStage stage, int durationMs) {
    final safeMs = durationMs < 0 ? 0 : durationMs;
    _stages[stage]!.recordSuccess(safeMs);
    lastStage = stage;
    lastDurationMs = safeMs;
    lastUpdatedAt = DateTime.now();
  }

  void recordFailure(
    PipelineStage stage,
    int durationMs,
    FailureCategory category,
    String errorMessage,
  ) {
    final safeMs = durationMs < 0 ? 0 : durationMs;
    _stages[stage]!.recordFailure(safeMs, category, errorMessage);
    _failureCounts[category] = (_failureCounts[category] ?? 0) + 1;
    lastStage = stage;
    lastFailureCategory = category;
    lastError = errorMessage;
    lastDurationMs = safeMs;
    lastUpdatedAt = DateTime.now();
  }

  void reset() {
    for (final stage in _stages.values) {
      stage.reset();
    }
    _failureCounts.clear();
    lastStage = null;
    lastFailureCategory = null;
    lastError = null;
    lastDurationMs = null;
    lastUpdatedAt = null;
  }

  SourceStats snapshot() => SourceStats._copy(this);

  Map<String, dynamic> toJson() => {
    'success': successCount,
    'failed': failedCount,
    'total': totalCount,
    'successRate': double.parse(successRate.toStringAsFixed(3)),
    'avgDurationMs': double.parse(avgDurationMs.toStringAsFixed(1)),
    if (minDurationMs != null) 'minDurationMs': minDurationMs,
    if (maxDurationMs != null) 'maxDurationMs': maxDurationMs,
    if (lastDurationMs != null) 'lastDurationMs': lastDurationMs,
    if (lastStage != null) 'lastStage': lastStage!.label,
    if (lastFailureCategory != null)
      'lastFailureCategory': lastFailureCategory!.label,
    if (lastError != null) 'lastError': lastError,
    if (_failureCounts.isNotEmpty)
      'failureCounts': {
        for (final entry in _failureCounts.entries)
          entry.key.label: entry.value,
      },
    'stages': {
      for (final entry in _stages.entries)
        if (entry.value.totalCount > 0) entry.key.label: entry.value.toJson(),
    },
  };
}

/// Maps runtime errors and extraction anomalies into [FailureCategory] tags.
abstract final class FailureClassifier {
  static FailureCategory classify(Object error) {
    if (error is TimeoutException) {
      return FailureCategory.timeout;
    }
    if (error is HttpException) {
      return FailureCategory.httpStatus;
    }
    if (error is SocketException ||
        error is HandshakeException ||
        error is TlsException ||
        error is OSError ||
        error is http.ClientException) {
      final msg = error.toString().toLowerCase();
      if (msg.contains('timed out') || msg.contains('timeout')) {
        return FailureCategory.timeout;
      }
      return FailureCategory.network;
    }
    if (error is FormatException) {
      return FailureCategory.parseOrScript;
    }

    final lower = error.toString().toLowerCase();
    if (lower.contains('empty final url') ||
        lower.contains('empty response') ||
        lower.contains('empty http response')) {
      return FailureCategory.emptyResponse;
    }
    if (lower.contains('no results matched rule') ||
        lower.contains('rule mismatch') ||
        lower.contains('empty content') ||
        lower.contains('empty chapter')) {
      return FailureCategory.ruleMismatch;
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return FailureCategory.timeout;
    }
    if (RegExp(r'http\s+[45]\d{2}').hasMatch(lower) ||
        lower.contains('httpexception')) {
      return FailureCategory.httpStatus;
    }
    if (lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('failed host lookup')) {
      return FailureCategory.network;
    }
    if (lower.contains('syntaxerror') ||
        lower.contains('referenceerror') ||
        lower.contains('typeerror') ||
        lower.contains('xpath') ||
        lower.contains('json')) {
      return FailureCategory.parseOrScript;
    }
    return FailureCategory.unknown;
  }

  static String summarizeError(Object error, {int maxLength = 160}) {
    final singleLine = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= maxLength) return singleLine;
    return '${singleLine.substring(0, maxLength - 3)}...';
  }
}

/// Structured log event emitted during source pipeline execution.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final PipelineStage stage;
  final String sourceName;
  final String sourceUrl;
  final FailureCategory? category;
  final int? durationMs;
  final String message;
  final String? error;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.stage,
    required this.sourceName,
    required this.sourceUrl,
    required this.message,
    this.category,
    this.durationMs,
    this.error,
  });

  String formatLine() {
    final meta = <String>[
      if (category != null) category!.label,
      if (durationMs != null) '${durationMs}ms',
    ];
    final metaPart = meta.isEmpty ? '' : ' (${meta.join(', ')})';
    final errorPart = (error != null && error!.isNotEmpty) ? ': $error' : '';
    final sourceLabel = sourceName.isNotEmpty ? sourceName : sourceUrl;
    return '[${level.label}] [${stage.label}] [$sourceLabel]$metaPart $message$errorPart';
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.label.toLowerCase(),
    'stage': stage.label,
    'sourceName': sourceName,
    'sourceUrl': sourceUrl,
    if (category != null) 'category': category!.label,
    if (durationMs != null) 'durationMs': durationMs,
    'message': message,
    if (error != null) 'error': error,
  };
}

typedef LogSink = void Function(LogEntry entry);

/// Leveled logger with a pluggable [onLog] hook and optional in-memory log capture.
class GoproLogger {
  static final GoproLogger silent = GoproLogger(minLevel: LogLevel.off);

  final LogLevel minLevel;
  final LogSink? onLog;
  final bool collectEntries;
  final List<LogEntry> _entries = [];

  GoproLogger({
    this.minLevel = LogLevel.warn,
    this.onLog,
    this.collectEntries = false,
  });

  /// Creates a logger that formats and prints matching entries to `stderr`.
  factory GoproLogger.stderr({
    LogLevel minLevel = LogLevel.warn,
    bool collectEntries = false,
  }) {
    return GoproLogger(
      minLevel: minLevel,
      collectEntries: collectEntries,
      onLog: (entry) => stderr.writeln(entry.formatLine()),
    );
  }

  List<LogEntry> get entries => List.unmodifiable(_entries);

  bool shouldLog(LogLevel level) =>
      minLevel != LogLevel.off && level.severity >= minLevel.severity;

  void log({
    required LogLevel level,
    required PipelineStage stage,
    required String sourceName,
    required String sourceUrl,
    required String message,
    FailureCategory? category,
    int? durationMs,
    Object? error,
  }) {
    if (!shouldLog(level)) return;
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      stage: stage,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      category: category,
      durationMs: durationMs,
      message: message,
      error: error == null ? null : FailureClassifier.summarizeError(error),
    );
    if (collectEntries) {
      _entries.add(entry);
    }
    onLog?.call(entry);
  }

  void debug({
    required PipelineStage stage,
    required String sourceName,
    required String sourceUrl,
    required String message,
    int? durationMs,
  }) {
    log(
      level: LogLevel.debug,
      stage: stage,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      message: message,
      durationMs: durationMs,
    );
  }

  void info({
    required PipelineStage stage,
    required String sourceName,
    required String sourceUrl,
    required String message,
    int? durationMs,
  }) {
    log(
      level: LogLevel.info,
      stage: stage,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      message: message,
      durationMs: durationMs,
    );
  }

  void warn({
    required PipelineStage stage,
    required String sourceName,
    required String sourceUrl,
    required String message,
    FailureCategory? category,
    int? durationMs,
    Object? error,
  }) {
    log(
      level: LogLevel.warn,
      stage: stage,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      message: message,
      category: category,
      durationMs: durationMs,
      error: error,
    );
  }

  void error({
    required PipelineStage stage,
    required String sourceName,
    required String sourceUrl,
    required String message,
    FailureCategory? category,
    int? durationMs,
    Object? error,
  }) {
    log(
      level: LogLevel.error,
      stage: stage,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      message: message,
      category: category,
      durationMs: durationMs,
      error: error,
    );
  }

  void clearEntries() => _entries.clear();
}

/// Formats an aligned ASCII health summary table across sources.
abstract final class SourceHealthSummaryFormatter {
  static String format(Iterable<NovelSource> sources, {int? totalElapsedMs}) {
    final all = sources.toList();
    final active = [
      for (final s in all)
        if (s.stats.totalCount > 0) s,
    ];
    final rowsSource = active.isNotEmpty ? active : all;
    if (rowsSource.isEmpty) {
      return 'Source Health Summary: no sources evaluated.';
    }

    final rows = <_SummaryRow>[];
    var totalOk = 0;
    var totalFail = 0;
    final categoryTotals = <FailureCategory, int>{};

    for (final src in rowsSource) {
      final st = src.stats;
      totalOk += st.successCount;
      totalFail += st.failedCount;
      for (final entry in st.failureCounts.entries) {
        categoryTotals[entry.key] =
            (categoryTotals[entry.key] ?? 0) + entry.value;
      }

      final stageParts = <String>[
        for (final stage in PipelineStage.values)
          if (st.forStage(stage).totalCount > 0)
            '${stage.shortCode}:${st.forStage(stage).successCount}/${st.forStage(stage).failedCount}',
      ];

      final issueText = st.lastFailureCategory == null
          ? '-'
          : '${st.lastFailureCategory!.label}: ${_truncate(st.lastError ?? '', 34)}';

      final rawName = src.bookSourceName.isNotEmpty
          ? src.bookSourceName
          : src.bookSourceUrl;

      rows.add(
        _SummaryRow(
          source: _truncate(rawName, 22),
          ok: st.successCount.toString(),
          fail: st.failedCount.toString(),
          avgMs: st.totalCount == 0 ? '-' : st.avgDurationMs.round().toString(),
          stages: stageParts.isEmpty ? '-' : stageParts.join(' '),
          lastIssue: issueText,
        ),
      );
    }

    var wSource = 'Source'.length;
    var wOk = 'OK'.length;
    var wFail = 'Fail'.length;
    var wAvg = 'Avg(ms)'.length;
    var wStages = 'Stages(S/I/T/C)'.length;
    var wIssue = 'Last Issue'.length;

    for (final r in rows) {
      if (r.source.length > wSource) wSource = r.source.length;
      if (r.ok.length > wOk) wOk = r.ok.length;
      if (r.fail.length > wFail) wFail = r.fail.length;
      if (r.avgMs.length > wAvg) wAvg = r.avgMs.length;
      if (r.stages.length > wStages) wStages = r.stages.length;
      if (r.lastIssue.length > wIssue) wIssue = r.lastIssue.length;
    }

    String line(
      String source,
      String ok,
      String fail,
      String avgMs,
      String stages,
      String issue,
    ) {
      return '${source.padRight(wSource)} | '
          '${ok.padLeft(wOk)} | '
          '${fail.padLeft(wFail)} | '
          '${avgMs.padLeft(wAvg)} | '
          '${stages.padRight(wStages)} | '
          '$issue';
    }

    final header = line(
      'Source',
      'OK',
      'Fail',
      'Avg(ms)',
      'Stages(S/I/T/C)',
      'Last Issue',
    );
    final separator = '-' * header.length;

    final buf = StringBuffer()
      ..writeln('Source Health Summary (${rowsSource.length} sources)')
      ..writeln(separator)
      ..writeln(header)
      ..writeln(separator);

    for (final r in rows) {
      buf.writeln(line(r.source, r.ok, r.fail, r.avgMs, r.stages, r.lastIssue));
    }

    final totalRuns = totalOk + totalFail;
    final ratePct = totalRuns == 0
        ? '0.0%'
        : '${((totalOk / totalRuns) * 100).toStringAsFixed(1)}%';
    final catSummary = categoryTotals.isEmpty
        ? 'none'
        : [
            for (final entry in categoryTotals.entries)
              '${entry.key.label}=${entry.value}',
          ].join(', ');
    final elapsedPart = totalElapsedMs == null
        ? ''
        : ', elapsed=${totalElapsedMs}ms';

    buf
      ..writeln(separator)
      ..write(
        'Totals: requests=$totalRuns, ok=$totalOk, fail=$totalFail, '
        'successRate=$ratePct, failures=[$catSummary]$elapsedPart',
      );
    return buf.toString();
  }

  static String _truncate(String value, int maxLen) {
    if (value.length <= maxLen) return value;
    if (maxLen <= 3) return value.substring(0, maxLen);
    return '${value.substring(0, maxLen - 3)}...';
  }
}

class _SummaryRow {
  final String source;
  final String ok;
  final String fail;
  final String avgMs;
  final String stages;
  final String lastIssue;

  const _SummaryRow({
    required this.source,
    required this.ok,
    required this.fail,
    required this.avgMs,
    required this.stages,
    required this.lastIssue,
  });
}
