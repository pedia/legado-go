import 'dart:convert';
import 'dart:io';

import 'novel_source.dart';

/// Reads a JSON file and returns all enabled [NovelSource] entries.
///
/// Disabled sources (`enabled == false`) are filtered out.
Future<List<NovelSource>> loadSources(String jsonPath) async {
  final data = await File(jsonPath).readAsString();
  return parseSources(data);
}

/// Synchronous variant of [loadSources].
List<NovelSource> loadSourcesSync(String jsonPath) {
  final data = File(jsonPath).readAsStringSync();
  return parseSources(data);
}

/// Parses a JSON array string into enabled [NovelSource] entries.
///
/// Disabled sources (`enabled == false`) are filtered out.
List<NovelSource> parseSources(String data) {
  final decoded = jsonDecode(data);
  if (decoded is! List) {
    throw const FormatException('Novel sources JSON must be a JSON array');
  }
  return [
    for (final item in decoded)
      if (item is Map)
        NovelSource.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
  ].where((source) => source.enabled).toList();
}
