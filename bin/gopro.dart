import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:gopro/gopro.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'page',
      abbr: 'p',
      defaultsTo: '1',
      help: 'Search result page number.',
    )
    ..addOption(
      'log-level',
      abbr: 'l',
      defaultsTo: 'warn',
      allowed: ['debug', 'info', 'warn', 'error', 'off'],
      help: 'Diagnostic log verbosity written to stderr.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Shortcut for --log-level=debug.',
    )
    ..addFlag(
      'summary',
      defaultsTo: true,
      help: 'Print end-of-run source health summary table to stderr.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    _printUsage(parser);
    exit(64);
  }

  if (parsed['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final rest = parsed.rest;
  if (rest.length < 2) {
    _printUsage(parser);
    return;
  }

  final jsonFile = rest[0];
  final command = rest[1];
  if (command != 'search' || rest.length < 3) {
    if (command == 'search') {
      stderr.writeln('Usage: gopro <json_file> search <keyword>');
      exit(1);
    }
    _printUsage(parser);
    return;
  }

  final page = int.tryParse(parsed['page'] as String) ?? 1;
  final keyword = rest.sublist(2).join(' ');
  final verbose = parsed['verbose'] as bool;
  final showSummary = parsed['summary'] as bool;
  final logLevel = verbose
      ? LogLevel.debug
      : LogLevel.parse(parsed['log-level'] as String);

  final List<NovelSource> sources;
  try {
    sources = await loadSources(jsonFile);
  } catch (e) {
    stderr.writeln('Failed to load sources: $e');
    exit(1);
  }

  stderr.writeln('Loaded ${sources.length} enabled sources');
  stderr.writeln('Searching for: $keyword');

  final logger = GoproLogger.stderr(minLevel: logLevel);
  final sw = Stopwatch()..start();
  final report = await searchBooksDetailed(sources, keyword, page, 10, logger);
  sw.stop();

  stderr.writeln(
    'Found ${report.results.length} results '
    '(${report.errors.length} failed sources, ${sw.elapsedMilliseconds}ms)',
  );
  if (showSummary) {
    stderr.writeln(
      SourceHealthSummaryFormatter.format(
        sources,
        totalElapsedMs: sw.elapsedMilliseconds,
      ),
    );
  }

  const encoder = JsonEncoder.withIndent('  ');
  print(encoder.convert([for (final r in report.results) r.toJson()]));
}

void _printUsage(ArgParser parser) {
  print('''
GoPro - Legado Book Source Reader (Dart CLI)

Usage:
  dart run bin/gopro.dart [options] <json_file> search <keyword>

Options:
${parser.usage}

Example:
  dart run bin/gopro.dart -l info doc/example.json search "斗破苍穹"''');
}
