import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:gopro/gopro.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'sources',
      abbr: 's',
      defaultsTo: 'doc/example.json',
      help: 'Path to book sources JSON file.',
    )
    ..addOption('keyword', abbr: 'k', help: 'Search keyword.')
    ..addOption(
      'go-cmd',
      help: 'Go CLI command (e.g. "go run reader.go" or "./gopro_go").',
    )
    ..addOption(
      'dart-cmd',
      help:
          'Dart CLI command (default: auto-detected gopro binary or dart run).',
    )
    ..addOption(
      'go-output',
      help: 'Path to saved Go CLI stdout JSON file (skips running Go CLI).',
    )
    ..addOption(
      'dart-output',
      help: 'Path to saved Dart CLI stdout JSON file (skips running Dart CLI).',
    )
    ..addOption(
      'ignore-fields',
      defaultsTo: '',
      help: 'Comma-separated SearchBook fields to ignore when comparing.',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: 'Emit comparison report as formatted JSON.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show all diffs, per-source counts, and CLI stderr.',
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

  var sourcesPath = parsed['sources'] as String;
  var keyword = (parsed['keyword'] as String?) ?? '';

  // Support `compare_cli <json_file> search <keyword>` syntax matching gopro.
  final rest = parsed.rest;
  if (rest.isNotEmpty) {
    if (rest.length >= 3 && rest[1] == 'search') {
      sourcesPath = rest[0];
      keyword = rest.sublist(2).join(' ');
    } else if (keyword.isEmpty && rest.length == 1) {
      keyword = rest[0];
    } else {
      stderr.writeln('Invalid positional arguments: ${rest.join(' ')}');
      _printUsage(parser);
      exit(64);
    }
  }

  final goOutputFile = parsed['go-output'] as String?;
  final dartOutputFile = parsed['dart-output'] as String?;
  final needsCliExecution = goOutputFile == null || dartOutputFile == null;
  if (needsCliExecution && keyword.trim().isEmpty) {
    stderr.writeln('Error: search keyword is required.');
    _printUsage(parser);
    exit(64);
  }

  final verbose = parsed['verbose'] as bool;
  final jsonOut = parsed['json'] as bool;
  final ignoreFields = {
    for (final f in (parsed['ignore-fields'] as String).split(','))
      if (f.trim().isNotEmpty) f.trim(),
  };

  final CliExecResult goExec;
  if (goOutputFile != null) {
    goExec = CliExecResult(
      command: 'file:$goOutputFile',
      exitCode: 0,
      stdout: await File(goOutputFile).readAsString(),
      stderr: '',
      durationMs: 0,
    );
  } else {
    final goCmdOpt = parsed['go-cmd'] as String?;
    final goCmd = goCmdOpt != null && goCmdOpt.trim().isNotEmpty
        ? splitCommandLine(goCmdOpt)
        : await detectDefaultGoCommand();
    if (goCmd == null) {
      stderr.writeln(
        'Go executable not found on PATH and no ./gopro binary present.\n'
        'Pass --go-cmd="..." or --go-output=<go_stdout.json>.',
      );
      exit(2);
    }
    goExec = await executeCliCommand(goCmd, [sourcesPath, 'search', keyword]);
    if (goExec.exitCode != 0) {
      stderr.writeln(
        'Go CLI failed (exit ${goExec.exitCode}): ${goExec.command}',
      );
      if (goExec.stderr.isNotEmpty) stderr.writeln(goExec.stderr);
      exit(2);
    }
  }

  final CliExecResult dartExec;
  if (dartOutputFile != null) {
    dartExec = CliExecResult(
      command: 'file:$dartOutputFile',
      exitCode: 0,
      stdout: await File(dartOutputFile).readAsString(),
      stderr: '',
      durationMs: 0,
    );
  } else {
    final dartCmdOpt = parsed['dart-cmd'] as String?;
    final dartCmd = dartCmdOpt != null && dartCmdOpt.trim().isNotEmpty
        ? splitCommandLine(dartCmdOpt)
        : detectDefaultDartCommand();
    dartExec = await executeCliCommand(dartCmd, [
      sourcesPath,
      'search',
      keyword,
    ]);
    if (dartExec.exitCode != 0) {
      stderr.writeln(
        'Dart CLI failed (exit ${dartExec.exitCode}): ${dartExec.command}',
      );
      if (dartExec.stderr.isNotEmpty) stderr.writeln(dartExec.stderr);
      exit(2);
    }
  }

  if (verbose) {
    stderr.writeln('[Go]   ${goExec.command} (${goExec.durationMs}ms)');
    if (goExec.stderr.trim().isNotEmpty) stderr.writeln(goExec.stderr.trim());
    stderr.writeln('[Dart] ${dartExec.command} (${dartExec.durationMs}ms)');
    if (dartExec.stderr.trim().isNotEmpty) {
      stderr.writeln(dartExec.stderr.trim());
    }
  }

  final List<SearchBook> goResults;
  final List<SearchBook> dartResults;
  try {
    goResults = parseSearchCliOutput(goExec.stdout);
  } catch (e) {
    stderr.writeln('Failed to parse Go CLI JSON stdout: $e');
    exit(2);
  }
  try {
    dartResults = parseSearchCliOutput(dartExec.stdout);
  } catch (e) {
    stderr.writeln('Failed to parse Dart CLI JSON stdout: $e');
    exit(2);
  }

  final report = compareSearchResults(
    goResults: goResults,
    dartResults: dartResults,
    goDurationMs: goExec.durationMs,
    dartDurationMs: dartExec.durationMs,
    ignoreFields: ignoreFields,
  );

  if (jsonOut) {
    const encoder = JsonEncoder.withIndent('  ');
    print(encoder.convert(report.toJson()));
  } else {
    print(report.format(verbose: verbose));
  }

  if (!report.isMatch) {
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('''
Compare Dart CLI search output with Go CLI search output.

Usage:
  dart run bin/compare_cli.dart <json_file> search <keyword> [options]
  dart run bin/compare_cli.dart --sources=doc/example.json --keyword=斗破苍穹 [options]

Options:
${parser.usage}

Examples:
  dart run bin/compare_cli.dart doc/example.json search "斗破苍穹"
  dart run bin/compare_cli.dart --go-cmd="./gopro_go" doc/example.json search "斗破苍穹"
  dart run bin/compare_cli.dart --go-output=go.json --dart-output=dart.json''');
}
