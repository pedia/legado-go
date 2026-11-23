import 'dart:convert';

import 'package:js_interpreter/js_interpreter.dart';

import 'css.dart';
import 'jsonpath.dart';
import 'legado_stub.dart';
import 'regex.dart';
import 'source_rule.dart';
import 'xpath.dart';

/// Matches `{{expression}}` inline templates (non-greedy).
final RegExp templateExprPattern = RegExp(r'\{\{[\s\S]*?\}\}');

/// Lightweight JS pool abstraction matching Go's `qjs.Pool` role.
class JsPool {
  final int size;

  JsPool([this.size = 5]);

  JSInterpreter acquire() => JSInterpreter();

  void release(JSInterpreter interpreter) {}
}

/// Main Legado rule dispatcher.
class AnalyzeRule {
  String _content;
  String _baseUrl;
  bool _isJson;
  final JsPool? _jsPool;

  AnalyzeRule(this._content, this._baseUrl, [this._jsPool])
    : _isJson = isJsonContent(_content);

  String get content => _content;
  String get baseUrl => _baseUrl;
  bool get isJson => _isJson;

  /// Updates the content and optionally the [baseUrl] to parse.
  void setContent(String content, [String baseUrl = '']) {
    _content = content;
    if (baseUrl.isNotEmpty) {
      _baseUrl = baseUrl;
    }
    _isJson = isJsonContent(content);
  }

  /// Applies [ruleStr] and returns the first non-empty result.
  String getString(String ruleStr) {
    if (ruleStr.isEmpty) return '';
    final rules = splitSourceRule(ruleStr, _isJson, false);
    return _getStringFromRules(rules, _content);
  }

  /// Applies [ruleStr] and returns all matches.
  List<String> getStringList(String ruleStr) {
    if (ruleStr.isEmpty) return const [];
    final rules = splitSourceRule(ruleStr, _isJson, false);
    return _getStringListFromRules(rules, _content);
  }

  /// Returns a single element matching [ruleStr] (for init-type rules).
  String getElement(String ruleStr) {
    if (ruleStr.isEmpty) return _content;
    final rules = splitSourceRule(ruleStr, _isJson, false);
    return _getStringFromRules(rules, _content);
  }

  /// Returns all elements matching [ruleStr] as HTML/JSON/text strings
  /// so child rules can re-parse each item.
  List<String> getElements(String ruleStr) {
    if (ruleStr.isEmpty) return const [];
    final rules = splitSourceRule(ruleStr, _isJson, false);
    return _getElementListFromRules(rules, _content);
  }

  List<String> _getElementListFromRules(
    List<SourceRule> rules,
    String initialContent,
  ) {
    var results = <String>[];
    var current = initialContent;
    for (final r in rules) {
      if (r.isJs) {
        current = _evalJS(r.rule, current);
        continue;
      }
      if (r.rule.contains('%%')) {
        return _handlePercentInterleaveList(r.rule, current);
      }
      switch (r.mode) {
        case RuleMode.js:
          final jsResult = _evalJS(r.rule, current);
          if (jsResult.isEmpty) return const [];
          final parsedList = _tryParseJsArrayResult(jsResult);
          if (parsedList != null && parsedList.isNotEmpty) {
            return parsedList;
          }
          current = jsResult;
        case RuleMode.regex:
          return applyRegexList(r.rule, current);
        case RuleMode.json:
          results = jsonPathGetStringList(r.rule, current);
          if (results.isEmpty) return const [];
          current = results.first;
        case RuleMode.xpath:
          results = xpathGetElementList(r.rule, current);
          if (results.isEmpty) return const [];
          current = results.first;
        case RuleMode.defaultMode:
          results = cssGetElementList(r.rule, current, _baseUrl);
          if (results.isEmpty) return const [];
          current = results.first;
      }
    }
    if (results.isEmpty) {
      return current.isNotEmpty ? [current] : const [];
    }
    return results;
  }

  String _getStringFromRules(List<SourceRule> rules, String initialContent) {
    var result = initialContent;
    for (final r in rules) {
      if (r.isJs) {
        result = _evalJS(r.rule, result);
        continue;
      }
      final rule = r.rule;
      if (rule.contains('{{')) {
        result = _resolveInlineTemplates(rule, result);
        continue;
      }
      if (rule.contains('%%')) {
        result = _handlePercentInterleaveString(rule, result);
        continue;
      }
      if (rule.contains('&&')) {
        result = _handleAndConcat(rule, result);
        continue;
      }
      final (:mainRule, :replaceRegex, :replacement) = _splitHashReplacement(
        rule,
      );
      var mode = r.mode;
      if (replaceRegex.isNotEmpty && mode == RuleMode.regex) {
        mode = detectMode(mainRule, _isJson);
      }
      result = switch (mode) {
        RuleMode.js => _evalJS(mainRule, result),
        RuleMode.regex => applyRegex(mainRule, result),
        RuleMode.json => jsonPathGetString(mainRule, result),
        RuleMode.xpath => xpathGetString(mainRule, result),
        RuleMode.defaultMode => cssGetString(mainRule, result, _baseUrl),
      };
      if (replaceRegex.isNotEmpty) {
        result = _applyRegexPost(result, replaceRegex, replacement);
      }
    }
    return result;
  }

  List<String> _getStringListFromRules(
    List<SourceRule> rules,
    String initialContent,
  ) {
    var results = <String>[];
    var current = initialContent;
    for (final r in rules) {
      if (r.isJs) {
        current = _evalJS(r.rule, current);
        continue;
      }
      switch (r.mode) {
        case RuleMode.js:
          final jsResult = _evalJS(r.rule, current);
          if (jsResult.isEmpty) return const [];
          final parsedList = _tryParseJsArrayResult(jsResult);
          if (parsedList != null && parsedList.isNotEmpty) {
            return parsedList;
          }
          current = jsResult;
        case RuleMode.regex:
          return applyRegexList(r.rule, current);
        case RuleMode.json:
          results = jsonPathGetStringList(r.rule, current);
          if (results.isEmpty) return const [];
          current = results.first;
        case RuleMode.xpath:
          results = xpathGetStringList(r.rule, current);
          if (results.isEmpty) return const [];
          current = results.first;
        case RuleMode.defaultMode:
          results = cssGetStringList(r.rule, current, _baseUrl);
          if (results.isEmpty) return const [];
          current = results.first;
      }
    }
    if (results.isEmpty) {
      return current.isNotEmpty ? [current] : const [];
    }
    return results;
  }

  List<String>? _tryParseJsArrayResult(String jsResult) {
    if (!jsResult.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(jsResult);
      if (decoded is List && decoded.isNotEmpty) {
        return [
          for (final item in decoded) item is String ? item : jsonEncode(item),
        ];
      }
    } catch (_) {}
    return null;
  }

  String _handlePercentInterleaveString(String rule, String content) =>
      _handlePercentInterleaveList(rule, content).join(' ');

  List<String> _handlePercentInterleaveList(String rule, String content) {
    final lists = <List<String>>[];
    var maxLen = 0;
    for (var part in rule.split('%%')) {
      part = part.trim();
      if (part.isEmpty) continue;
      final vals = _evalSingleRuleList(part, content);
      if (vals.isEmpty) continue;
      lists.add(vals);
      if (vals.length > maxLen) {
        maxLen = vals.length;
      }
    }
    return [
      for (var i = 0; i < maxLen; i++)
        for (final vals in lists)
          if (i < vals.length && vals[i].trim().isNotEmpty) vals[i],
    ];
  }

  ({String mainRule, String replaceRegex, String replacement})
  _splitHashReplacement(String rule) {
    if (!rule.contains('##')) {
      return (mainRule: rule, replaceRegex: '', replacement: '');
    }
    final parts = splitN(rule, '##', 3);
    return (
      mainRule: parts[0].trim(),
      replaceRegex: parts.length >= 2 ? parts[1] : '',
      replacement: parts.length >= 3 ? parts[2] : '',
    );
  }

  String _applyRegexPost(String content, String pattern, String replacement) {
    if (content.isEmpty || pattern.isEmpty) return content;
    try {
      final re = RegExp(pattern);
      return regexReplaceAll(re, content, replacement).trim();
    } on FormatException {
      return content;
    }
  }

  String _handleAndConcat(String rule, String content) {
    return [
      for (final part in rule.split('&&'))
        if (part.trim().isNotEmpty)
          if (_evalSingleRule(part.trim(), content) case final val
              when val.isNotEmpty)
            val,
    ].join(' ');
  }

  String _evalSingleRule(String rule, String content) {
    return switch (detectMode(rule, _isJson)) {
      RuleMode.js => _evalJS(rule, content),
      RuleMode.regex => applyRegex(rule, content),
      RuleMode.json => jsonPathGetString(rule, content),
      RuleMode.xpath => xpathGetString(rule, content),
      RuleMode.defaultMode => cssGetString(rule, content, _baseUrl),
    };
  }

  List<String> _evalSingleRuleList(String rule, String content) {
    switch (detectMode(rule, _isJson)) {
      case RuleMode.js:
        final s = _evalJS(rule, content);
        return s.isNotEmpty ? [s] : const [];
      case RuleMode.regex:
        return applyRegexList(rule, content);
      case RuleMode.json:
        return jsonPathGetStringList(rule, content);
      case RuleMode.xpath:
        return xpathGetStringList(rule, content);
      case RuleMode.defaultMode:
        return cssGetStringList(rule, content, _baseUrl);
    }
  }

  String _resolveInlineTemplates(String rule, String content) {
    final matches = templateExprPattern.allMatches(rule).toList();
    if (matches.isEmpty) return rule;

    final result = StringBuffer();
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        result.write(rule.substring(lastEnd, m.start));
      }
      final expr = rule.substring(m.start + 2, m.end - 2);
      result.write(_resolveTemplateExpr(expr, content));
      lastEnd = m.end;
    }
    if (lastEnd < rule.length) {
      result.write(rule.substring(lastEnd));
    }

    final resolved = result.toString();
    final idx = resolved.indexOf('##');
    if (idx != -1) {
      final mainRule = resolved.substring(0, idx).trim();
      var regexPart = resolved.substring(idx + 2);
      var replacement = '';
      final idx2 = regexPart.indexOf('##');
      if (idx2 != -1) {
        replacement = regexPart.substring(idx2 + 2);
        regexPart = regexPart.substring(0, idx2);
      }
      if (regexPart.isNotEmpty) {
        try {
          final re = RegExp(regexPart);
          return regexReplaceAll(re, mainRule, replacement).trim();
        } on FormatException {
          return mainRule;
        }
      }
      return mainRule;
    }

    return resolved.trim();
  }

  String _resolveTemplateExpr(String expr, String content) {
    if (expr.startsWith('@')) {
      return cssGetString(expr.substring(1), content, _baseUrl);
    }
    for (var alt in _splitTopLevelOr(expr)) {
      alt = alt.trim();
      if (alt.isEmpty || alt == '""' || alt == "''") continue;
      final val = _evalSingleExpr(alt, content);
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  String _evalSingleExpr(String expr, String content) {
    if (expr.startsWith(r'$.') || expr.startsWith(r'$[')) {
      return jsonPathGetString(expr, content);
    }
    if (expr.startsWith('//')) {
      return xpathGetString(expr, content);
    }
    return _evalJS(expr, content);
  }

  List<String> _splitTopLevelOr(String s) {
    final parts = <String>[];
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var last = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == "'" && !inDouble && !inBacktick) {
        inSingle = !inSingle;
      } else if (ch == '"' && !inSingle && !inBacktick) {
        inDouble = !inDouble;
      } else if (ch == '`' && !inSingle && !inDouble) {
        inBacktick = !inBacktick;
      } else if (ch == r'\' && (inSingle || inDouble || inBacktick)) {
        i++;
      } else if (ch == '{' && !inSingle && !inDouble && !inBacktick) {
        depth++;
      } else if (ch == '}' && !inSingle && !inDouble && !inBacktick) {
        if (depth > 0) depth--;
      } else if (ch == '|' &&
          i + 1 < s.length &&
          s[i + 1] == '|' &&
          !inSingle &&
          !inDouble &&
          !inBacktick &&
          depth == 0) {
        parts.add(s.substring(last, i));
        last = i + 2;
        i++;
      }
    }
    parts.add(s.substring(last));
    return parts;
  }

  String _evalJS(String jsCode, String result) {
    final pool = _jsPool ?? JsPool(1);
    final js = pool.acquire();
    try {
      injectLegadoStubs(js);
      js.setGlobal('result', result);
      js.setGlobal('baseUrl', _baseUrl);
      js.setGlobal('src', _content);
      final quoted = jsonEncode(_baseUrl);
      js.eval(
        'source.getKey = function(){return $quoted;}; source.key = $quoted;',
      );
      final res = js.eval(jsCode);
      if (res.isUndefined || res.isNull) {
        return '';
      }
      if (res is JSObject || res is JSArray) {
        js.setGlobal('__eval_result', res);
        final jsonRes = js.eval('JSON.stringify(__eval_result)');
        if (!jsonRes.isUndefined && !jsonRes.isNull) {
          return jsonRes.toString();
        }
      }
      return res.toString();
    } catch (_) {
      return result;
    } finally {
      pool.release(js);
    }
  }
}

/// Returns whether [s] looks like a JSON object or array payload.
bool isJsonContent(String s) {
  final t = s.trim();
  return (t.startsWith('{') && t.endsWith('}')) ||
      (t.startsWith('[') && t.endsWith(']'));
}
