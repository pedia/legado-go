import 'dart:convert';
import 'dart:io';

import '../model/novel.dart';

/// Result of executing a CLI command.
class CliExecResult {
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;

  const CliExecResult({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
  });
}

/// Difference on a single field between Go and Dart search results.
class FieldDiff {
  final String field;
  final String goValue;
  final String dartValue;

  const FieldDiff({
    required this.field,
    required this.goValue,
    required this.dartValue,
  });

  Map<String, dynamic> toJson() => {
    'field': field,
    'go': goValue,
    'dart': dartValue,
  };
}

/// Field-level differences for a matched item present in both outputs.
class MatchedNovelDiff {
  final String origin;
  final String originName;
  final String name;
  final String bookUrl;
  final List<FieldDiff> diffs;

  const MatchedNovelDiff({
    required this.origin,
    required this.originName,
    required this.name,
    required this.bookUrl,
    required this.diffs,
  });

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'originName': originName,
    'name': name,
    'bookUrl': bookUrl,
    'diffs': [for (final d in diffs) d.toJson()],
  };
}

/// Per-source result counts in Go vs Dart outputs.
class SourceCountDiff {
  final String origin;
  final String originName;
  final int goCount;
  final int dartCount;

  const SourceCountDiff({
    required this.origin,
    required this.originName,
    required this.goCount,
    required this.dartCount,
  });

  bool get countsMatch => goCount == dartCount;

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'originName': originName,
    'goCount': goCount,
    'dartCount': dartCount,
  };
}

/// Structured comparison report between Go CLI and Dart CLI search outputs.
class CompareReport {
  final int goCount;
  final int dartCount;
  final int matchedCount;
  final int goDurationMs;
  final int dartDurationMs;
  final List<SearchBook> goOnly;
  final List<SearchBook> dartOnly;
  final List<MatchedNovelDiff> fieldDiffs;
  final List<SourceCountDiff> sourceCounts;

  const CompareReport({
    required this.goCount,
    required this.dartCount,
    required this.matchedCount,
    required this.goDurationMs,
    required this.dartDurationMs,
    required this.goOnly,
    required this.dartOnly,
    required this.fieldDiffs,
    required this.sourceCounts,
  });

  bool get isMatch => goOnly.isEmpty && dartOnly.isEmpty && fieldDiffs.isEmpty;

  Map<String, dynamic> toJson() => {
    'match': isMatch,
    'goCount': goCount,
    'dartCount': dartCount,
    'matchedCount': matchedCount,
    'goDurationMs': goDurationMs,
    'dartDurationMs': dartDurationMs,
    'goOnly': [for (final item in goOnly) item.toJson()],
    'dartOnly': [for (final item in dartOnly) item.toJson()],
    'fieldDiffs': [for (final diff in fieldDiffs) diff.toJson()],
    'sourceCounts': [for (final sc in sourceCounts) sc.toJson()],
  };

  /// Formats a human-readable comparison summary.
  String format({bool verbose = false}) {
    final buf = StringBuffer()
      ..writeln('Go vs Dart CLI Comparison')
      ..writeln('==========================')
      ..writeln('Status      : ${isMatch ? 'MATCH' : 'DIFF'}')
      ..writeln('Go results  : $goCount (${goDurationMs}ms)')
      ..writeln('Dart results: $dartCount (${dartDurationMs}ms)')
      ..writeln('Matched     : $matchedCount')
      ..writeln('Go only     : ${goOnly.length}')
      ..writeln('Dart only   : ${dartOnly.length}')
      ..writeln('Field diffs : ${fieldDiffs.length}');

    final mismatchedSources = [
      for (final sc in sourceCounts)
        if (!sc.countsMatch) sc,
    ];
    if (mismatchedSources.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Per-source count differences:');
      for (final sc in mismatchedSources) {
        final label = sc.originName.isNotEmpty ? sc.originName : sc.origin;
        buf.writeln(
          '  - $label (${sc.origin}): Go=${sc.goCount}, Dart=${sc.dartCount}',
        );
      }
    } else if (verbose && sourceCounts.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Per-source counts (all matching):');
      for (final sc in sourceCounts) {
        final label = sc.originName.isNotEmpty ? sc.originName : sc.origin;
        buf.writeln('  - $label (${sc.origin}): ${sc.goCount}');
      }
    }

    if (goOnly.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Only in Go (${goOnly.length}):');
      for (final item in _preview(goOnly, verbose)) {
        buf.writeln(
          '  - [${item.originName}] ${item.name} (${item.author}) -> ${item.bookUrl}',
        );
      }
    }

    if (dartOnly.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Only in Dart (${dartOnly.length}):');
      for (final item in _preview(dartOnly, verbose)) {
        buf.writeln(
          '  - [${item.originName}] ${item.name} (${item.author}) -> ${item.bookUrl}',
        );
      }
    }

    if (fieldDiffs.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(
          'Matched items with field differences (${fieldDiffs.length}):',
        );
      for (final item in _preview(fieldDiffs, verbose)) {
        buf.writeln('  - [${item.originName}] ${item.name} (${item.bookUrl}):');
        for (final d in item.diffs) {
          buf.writeln(
            '      ${d.field}: Go=${jsonEncode(d.goValue)} vs Dart=${jsonEncode(d.dartValue)}',
          );
        }
      }
    }

    return buf.toString().trimRight();
  }

  static List<T> _preview<T>(List<T> items, bool verbose) {
    if (verbose || items.length <= 20) return items;
    return items.sublist(0, 20);
  }
}

/// Parses CLI stdout JSON (either `null` or a JSON array of [SearchBook]).
List<SearchBook> parseSearchCliOutput(String stdoutText) {
  final trimmed = stdoutText.trim();
  if (trimmed.isEmpty || trimmed == 'null') {
    return const [];
  }
  final decoded = jsonDecode(trimmed);
  if (decoded == null) {
    return const [];
  }
  if (decoded is! List) {
    throw const FormatException('CLI output must be a JSON array or null');
  }
  return [
    for (final item in decoded)
      if (item is Map)
        SearchBook.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
  ];
}

/// Compares Go and Dart [SearchBook] result lists order-independently.
CompareReport compareSearchResults({
  required List<SearchBook> goResults,
  required List<SearchBook> dartResults,
  int goDurationMs = 0,
  int dartDurationMs = 0,
  Set<String> ignoreFields = const {},
}) {
  final sortedGo = [...goResults]..sort(_compareSearchBook);
  final sortedDart = [...dartResults]..sort(_compareSearchBook);

  // Pair strictly by (origin, bookUrl, name) first, then fallback to
  // (origin, name) so differences in resolved bookUrl show up as field diffs.
  final matchedPairs = <(SearchBook, SearchBook)>[];
  final unmatchedGo = <SearchBook>[];
  final dartBucketsStrict = <String, List<SearchBook>>{};

  for (final item in sortedDart) {
    final key = '${item.origin}\u0000${item.bookUrl}\u0000${item.name}';
    dartBucketsStrict.putIfAbsent(key, () => []).add(item);
  }

  for (final goItem in sortedGo) {
    final key = '${goItem.origin}\u0000${goItem.bookUrl}\u0000${goItem.name}';
    final bucket = dartBucketsStrict[key];
    if (bucket != null && bucket.isNotEmpty) {
      matchedPairs.add((goItem, bucket.removeAt(0)));
    } else {
      unmatchedGo.add(goItem);
    }
  }

  final remainingDart = [
    for (final bucket in dartBucketsStrict.values) ...bucket,
  ]..sort(_compareSearchBook);

  final dartBucketsLoose = <String, List<SearchBook>>{};
  for (final item in remainingDart) {
    final key = '${item.origin}\u0000${item.name}';
    dartBucketsLoose.putIfAbsent(key, () => []).add(item);
  }

  final goOnly = <SearchBook>[];
  for (final goItem in unmatchedGo) {
    final key = '${goItem.origin}\u0000${goItem.name}';
    final bucket = dartBucketsLoose[key];
    if (bucket != null && bucket.isNotEmpty) {
      matchedPairs.add((goItem, bucket.removeAt(0)));
    } else {
      goOnly.add(goItem);
    }
  }

  final dartOnly = [for (final bucket in dartBucketsLoose.values) ...bucket]
    ..sort(_compareSearchBook);

  final fieldDiffs = <MatchedNovelDiff>[];
  for (final (goItem, dartItem) in matchedPairs) {
    final diffs = _diffSearchBook(goItem, dartItem, ignoreFields);
    if (diffs.isNotEmpty) {
      fieldDiffs.add(
        MatchedNovelDiff(
          origin: goItem.origin,
          originName: goItem.originName,
          name: goItem.name,
          bookUrl: goItem.bookUrl.isNotEmpty
              ? goItem.bookUrl
              : dartItem.bookUrl,
          diffs: diffs,
        ),
      );
    }
  }

  final sourceCounts = _computeSourceCounts(sortedGo, sortedDart);

  return CompareReport(
    goCount: sortedGo.length,
    dartCount: sortedDart.length,
    matchedCount: matchedPairs.length,
    goDurationMs: goDurationMs,
    dartDurationMs: dartDurationMs,
    goOnly: goOnly,
    dartOnly: dartOnly,
    fieldDiffs: fieldDiffs,
    sourceCounts: sourceCounts,
  );
}

List<SourceCountDiff> _computeSourceCounts(
  List<SearchBook> goResults,
  List<SearchBook> dartResults,
) {
  final goCounts = <String, int>{};
  final dartCounts = <String, int>{};
  final names = <String, String>{};

  for (final item in goResults) {
    goCounts[item.origin] = (goCounts[item.origin] ?? 0) + 1;
    if (item.originName.isNotEmpty) {
      names.putIfAbsent(item.origin, () => item.originName);
    }
  }
  for (final item in dartResults) {
    dartCounts[item.origin] = (dartCounts[item.origin] ?? 0) + 1;
    if (item.originName.isNotEmpty) {
      names.putIfAbsent(item.origin, () => item.originName);
    }
  }

  final origins = {...goCounts.keys, ...dartCounts.keys}.toList()..sort();
  return [
    for (final origin in origins)
      SourceCountDiff(
        origin: origin,
        originName: names[origin] ?? '',
        goCount: goCounts[origin] ?? 0,
        dartCount: dartCounts[origin] ?? 0,
      ),
  ];
}

List<FieldDiff> _diffSearchBook(
  SearchBook goItem,
  SearchBook dartItem,
  Set<String> ignoreFields,
) {
  final goMap = goItem.toJson();
  final dartMap = dartItem.toJson();
  final diffs = <FieldDiff>[];

  for (final entry in goMap.entries) {
    final field = entry.key;
    if (ignoreFields.contains(field)) continue;
    final goVal = (entry.value ?? '').toString();
    final dartVal = (dartMap[field] ?? '').toString();
    if (goVal != dartVal) {
      diffs.add(FieldDiff(field: field, goValue: goVal, dartValue: dartVal));
    }
  }
  return diffs;
}

int _compareSearchBook(SearchBook a, SearchBook b) {
  var c = a.origin.compareTo(b.origin);
  if (c != 0) return c;
  c = a.bookUrl.compareTo(b.bookUrl);
  if (c != 0) return c;
  c = a.name.compareTo(b.name);
  if (c != 0) return c;
  return a.author.compareTo(b.author);
}

/// Splits a shell-style command string into executable + arguments,
/// respecting single and double quotes.
List<String> splitCommandLine(String commandLine) {
  final args = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var hasToken = false;

  for (var i = 0; i < commandLine.length; i++) {
    final ch = commandLine[i];
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
      hasToken = true;
    } else if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
      hasToken = true;
    } else if (ch == r'\' && !inSingle && i + 1 < commandLine.length) {
      current.write(commandLine[++i]);
      hasToken = true;
    } else if ((ch == ' ' || ch == '\t') && !inSingle && !inDouble) {
      if (hasToken) {
        args.add(current.toString());
        current.clear();
        hasToken = false;
      }
    } else {
      current.write(ch);
      hasToken = true;
    }
  }
  if (hasToken) {
    args.add(current.toString());
  }
  return args;
}

/// Runs a CLI command with appended [extraArgs] and records timing & output.
Future<CliExecResult> executeCliCommand(
  List<String> baseCommand,
  List<String> extraArgs, {
  String? workingDirectory,
}) async {
  if (baseCommand.isEmpty) {
    throw ArgumentError('baseCommand must not be empty');
  }
  final executable = baseCommand.first;
  final args = [...baseCommand.skip(1), ...extraArgs];
  final fullCommand = [executable, ...args].join(' ');
  final sw = Stopwatch()..start();
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  sw.stop();
  return CliExecResult(
    command: fullCommand,
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    durationMs: sw.elapsedMilliseconds,
  );
}

/// Detects the default Go CLI command (`go run reader.go` or local binary).
Future<List<String>?> detectDefaultGoCommand({
  String workingDirectory = '.',
}) async {
  for (final candidate in ['gopro_go', 'gopro']) {
    final file = File('$workingDirectory/$candidate');
    if (file.existsSync()) {
      return [file.path];
    }
  }
  try {
    final check = await Process.run('go', ['version']);
    if (check.exitCode == 0) {
      return const ['go', 'run', 'reader.go'];
    }
  } catch (_) {}
  return null;
}

/// Detects the default Dart CLI command.
List<String> detectDefaultDartCommand({String workingDirectory = '.'}) {
  final exe = File('$workingDirectory/build/gopro');
  if (exe.existsSync()) {
    return [exe.path];
  }
  final dill = File('$workingDirectory/.dart_tool/gopro.dill');
  if (dill.existsSync()) {
    return ['dart', dill.path];
  }
  return const ['dart', 'run', 'bin/gopro.dart'];
}
