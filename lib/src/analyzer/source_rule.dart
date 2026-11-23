/// Parsing mode for a Legado rule.
enum RuleMode {
  defaultMode, // JSoup @ syntax / CSS
  xpath,
  json,
  js,
  regex,
}

/// Matches `<js>...</js>` or `@js:...`. In Legado `@js:` is usually the
/// final segment of a rule, so it may span multiple lines.
final RegExp jsPattern = RegExp(r'@js:([\s\S]+)|<js>([\s\S]*?)</js>');

/// Represents a single parsed rule with its [RuleMode].
class SourceRule {
  final String rule;
  final RuleMode mode;

  const SourceRule(this.rule, this.mode);

  bool get isJs => mode == RuleMode.js;
}

/// Detects the mode of a rule string based on prefix.
RuleMode detectMode(String ruleStr, bool isJson) {
  final upper = ruleStr.toUpperCase();
  if (upper.startsWith('@CSS:')) {
    return RuleMode.defaultMode;
  }
  if (ruleStr.startsWith('@@')) {
    return RuleMode.defaultMode;
  }
  if (upper.startsWith('@XPATH:')) {
    return RuleMode.xpath;
  }
  if (upper.startsWith('@JSON:')) {
    return RuleMode.json;
  }
  if (isJson || ruleStr.startsWith(r'$.') || ruleStr.startsWith(r'$[')) {
    return RuleMode.json;
  }
  if (ruleStr.startsWith('//')) {
    return RuleMode.xpath;
  }
  if (ruleStr.startsWith(':')) {
    return RuleMode.regex;
  }
  return RuleMode.defaultMode;
}

/// Splits a rule string into a list of [SourceRule]s,
/// handling `<js>...</js>` and `@js:` markers.
List<SourceRule> splitSourceRule(
  String ruleStr,
  bool isJson, [
  bool allInOne = false,
]) {
  if (ruleStr.isEmpty) {
    return const [];
  }
  final result = <SourceRule>[];
  var mode = RuleMode.defaultMode;
  var start = 0;

  // AllInOne regex mode
  if (allInOne && ruleStr.startsWith(':')) {
    mode = RuleMode.regex;
    start = 1;
  }

  final matches = jsPattern.allMatches(ruleStr).toList();
  if (matches.isEmpty) {
    final r = ruleStr.substring(start);
    if (mode != RuleMode.regex) {
      mode = detectMode(r, isJson);
    }
    if (r.contains('##') && mode != RuleMode.js) {
      mode = RuleMode.regex;
    }
    result.add(SourceRule(_cleanRule(r), mode));
    return result;
  }

  for (final m in matches) {
    if (m.start > start) {
      final before = ruleStr.substring(start, m.start).trim();
      if (before.isNotEmpty) {
        var beforeMode = mode;
        if (before.contains('##') && beforeMode != RuleMode.js) {
          beforeMode = RuleMode.regex;
        }
        result.add(SourceRule(_cleanRule(before), beforeMode));
      }
    }
    // JS part: group 1 = @js:..., group 2 = <js>...</js>
    final jsCode = m.group(1) ?? m.group(2) ?? '';
    if (jsCode.isNotEmpty) {
      result.add(SourceRule(jsCode, RuleMode.js));
    }
    start = m.end;
  }

  if (start < ruleStr.length) {
    final after = ruleStr.substring(start).trim();
    if (after.isNotEmpty) {
      result.add(SourceRule(_cleanRule(after), mode));
    }
  }
  return result;
}

String _cleanRule(String rule) {
  final upper = rule.toUpperCase();
  if (upper.startsWith('@CSS:')) {
    return rule.substring(5);
  }
  if (rule.startsWith('@@')) {
    return rule.substring(2);
  }
  if (upper.startsWith('@XPATH:')) {
    return rule.substring(7);
  }
  if (upper.startsWith('@JSON:')) {
    return rule.substring(6);
  }
  return rule;
}
