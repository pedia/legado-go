/// Applies a regex to [content] and returns captured groups for the first match.
List<String> regexGetElement(String content, String pattern) {
  try {
    final re = RegExp(pattern);
    final match = re.firstMatch(content);
    if (match == null) return const [];
    return [for (var i = 0; i <= match.groupCount; i++) match.group(i) ?? ''];
  } on FormatException {
    return const [];
  }
}

/// Applies a regex to [content] and returns all matches as lists of groups.
List<List<String>> regexGetElements(String content, String pattern) {
  try {
    final re = RegExp(pattern);
    return [
      for (final match in re.allMatches(content))
        [for (var i = 0; i <= match.groupCount; i++) match.group(i) ?? ''],
    ];
  } on FormatException {
    return const [];
  }
}

/// Applies the OnlyOne regex format: `pattern##replacement`.
String applyOnlyOne(String content, String rule) => applyRegex(rule, content);

/// Applies the AllInOne regex format (starts with `:`).
List<String> applyAllInOne(String content, String rule) {
  final cleaned = rule.startsWith(':') ? rule.substring(1) : rule;
  return regexGetElement(content, cleaned);
}

/// Applies a `pattern##replacement` rule and returns the replaced result.
String applyRegex(String rule, String content) {
  final parts = splitN(rule, '##', 3);
  if (parts.length < 2 || parts[0].trim().isEmpty) {
    return content;
  }
  final pattern = parts[0];
  final replacement = parts.length >= 3 ? parts[2] : parts[1];
  try {
    final re = RegExp(pattern);
    return regexReplaceAll(re, content, replacement);
  } on FormatException {
    return content;
  }
}

/// Applies a regex and returns captured groups as a list.
List<String> applyRegexList(String rule, String content) =>
    regexGetElement(content, rule);

/// Replaces all matches of [re] in [input] with [replacement],
/// expanding `$0`, `$1`, `${1}`, `$$` capture group references.
String regexReplaceAll(RegExp re, String input, String replacement) {
  if (!replacement.contains(r'$')) {
    return input.replaceAll(re, replacement);
  }
  return input.replaceAllMapped(re, (match) {
    final buf = StringBuffer();
    var i = 0;
    while (i < replacement.length) {
      if (replacement[i] == r'$' && i + 1 < replacement.length) {
        final next = replacement[i + 1];
        if (next == r'$') {
          buf.write(r'$');
          i += 2;
          continue;
        }
        if (next == '{') {
          final close = replacement.indexOf('}', i + 2);
          if (close != -1) {
            final key = replacement.substring(i + 2, close);
            final idx = int.tryParse(key);
            if (idx != null && idx >= 0 && idx <= match.groupCount) {
              buf.write(match.group(idx) ?? '');
            } else if (match is RegExpMatch) {
              try {
                buf.write(match.namedGroup(key) ?? '');
              } on ArgumentError {
                // Unknown group name outputs empty string.
              }
            }
            i = close + 1;
            continue;
          }
        }
        var end = i + 1;
        while (end < replacement.length &&
            replacement.codeUnitAt(end) >= 48 &&
            replacement.codeUnitAt(end) <= 57) {
          end++;
        }
        if (end > i + 1) {
          final idx = int.tryParse(replacement.substring(i + 1, end));
          if (idx != null && idx >= 0 && idx <= match.groupCount) {
            buf.write(match.group(idx) ?? '');
          }
          i = end;
          continue;
        }
      }
      buf.write(replacement[i]);
      i++;
    }
    return buf.toString();
  });
}

/// Splits [input] into at most [n] parts separated by [separator].
List<String> splitN(String input, String separator, int n) {
  if (n <= 0) return const [];
  if (n == 1) return [input];
  final result = <String>[];
  var start = 0;
  for (var i = 0; i < n - 1; i++) {
    final idx = input.indexOf(separator, start);
    if (idx == -1) break;
    result.add(input.substring(start, idx));
    start = idx + separator.length;
  }
  result.add(input.substring(start));
  return result;
}
