import 'dart:convert';

import 'package:json_path/json_path.dart';

/// Applies a JSONPath rule and returns the first match.
String jsonPathGetString(String rule, String content) {
  final list = jsonPathGetStringList(rule, content);
  return list.isEmpty ? '' : list.first;
}

/// Applies a JSONPath rule and returns all matches.
List<String> jsonPathGetStringList(String rule, String content) {
  if (rule.isEmpty || content.isEmpty) {
    return const [];
  }

  final cleaned = rule.toLowerCase().startsWith('@json:')
      ? rule.substring(6)
      : rule;

  final Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    return const [];
  }

  final JsonPath expr;
  try {
    expr = JsonPath(cleaned);
  } on FormatException {
    return const [];
  }

  final out = <String>[];
  for (final r in expr.readValues(decoded)) {
    if (r == null) {
      continue;
    } else if (r is String) {
      out.add(r);
    } else {
      try {
        out.add(jsonEncode(r));
      } catch (_) {
        out.add(r.toString());
      }
    }
  }
  return out;
}
