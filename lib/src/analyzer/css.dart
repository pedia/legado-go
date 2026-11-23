import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Parses [content] with CSS/JSoup rules and returns the outer HTML of matches.
///
/// Used by `AnalyzeRule.getElements` so child rules can re-parse each result.
/// Handles `||` cascades by returning the first non-empty alternative.
List<String> cssGetElementList(
  String rule,
  String content, [
  String baseUrl = '',
]) {
  if (rule.isEmpty) {
    return [content];
  }
  if (findTopLevelOr(rule) >= 0) {
    for (var part in splitByTopLevelOr(rule)) {
      part = part.trim();
      if (part.isEmpty) continue;
      final result = _cssGetElementListSingle(part, content);
      if (result.isNotEmpty) {
        return result;
      }
    }
    return const [];
  }
  return _cssGetElementListSingle(rule, content);
}

List<String> _cssGetElementListSingle(String rule, String content) {
  if (rule.isEmpty) {
    return [content];
  }
  if (rule.toLowerCase().startsWith('@css:')) {
    return _cssSelectHtml(rule.substring(5), content);
  }
  final normalized = rule.startsWith('@') ? rule.substring(1) : rule;
  return _jsoupSelect(normalized, content, asElements: true);
}

List<String> _cssSelectHtml(String selector, String content) {
  final root = html_parser.parse(content).documentElement;
  if (root == null) return const [];
  return [
    for (final el in _safeQuerySelectorAll(root, selector))
      if (el.outerHtml.isNotEmpty) el.outerHtml,
  ];
}

/// Parses [content] with CSS/JSoup rules and returns the first match.
String cssGetString(String rule, String content, [String baseUrl = '']) {
  final list = cssGetStringList(rule, content, baseUrl);
  return list.isEmpty ? '' : list.first;
}

/// Parses [content] with CSS/JSoup rules and returns all matches.
///
/// Handles `||` cascades by returning the first non-empty alternative.
List<String> cssGetStringList(
  String rule,
  String content, [
  String baseUrl = '',
]) {
  if (rule.isEmpty) {
    return [content];
  }
  if (findTopLevelOr(rule) >= 0) {
    for (var part in splitByTopLevelOr(rule)) {
      part = part.trim();
      if (part.isEmpty || part == '""' || part == "''") {
        continue;
      }
      final result = _cssGetStringListSingle(part, content);
      if (result.isNotEmpty) {
        return result;
      }
    }
    return const [];
  }
  return _cssGetStringListSingle(rule, content);
}

List<String> _cssGetStringListSingle(String rule, String content) {
  if (rule.isEmpty) {
    return [content];
  }
  if (rule.toLowerCase().startsWith('@css:')) {
    return _cssSelectText(rule.substring(5), content);
  }
  final normalized = rule.startsWith('@') ? rule.substring(1) : rule;
  return _jsoupSelect(normalized, content, asElements: false);
}

List<int> _topLevelOrOffsets(String rule) {
  final offsets = <int>[];
  var inQuote = '';
  var depth = 0;
  for (var i = 0; i < rule.length; i++) {
    final ch = rule[i];
    if (inQuote.isNotEmpty) {
      if (ch == r'\') {
        i++;
        continue;
      }
      if (ch == inQuote) {
        inQuote = '';
      }
      continue;
    }
    if (ch == "'" || ch == '"' || ch == '`') {
      inQuote = ch;
    } else if (ch == '{' || ch == '[' || ch == '(') {
      depth++;
    } else if (ch == '}' || ch == ']' || ch == ')') {
      if (depth > 0) depth--;
    } else if (ch == '|' &&
        i + 1 < rule.length &&
        rule[i + 1] == '|' &&
        depth == 0) {
      offsets.add(i);
      i++;
    }
  }
  return offsets;
}

/// Returns the index of the first top-level `||` in [rule], or `-1`.
int findTopLevelOr(String rule) {
  final offsets = _topLevelOrOffsets(rule);
  return offsets.isEmpty ? -1 : offsets.first;
}

/// Splits [rule] by top-level `||` (ignoring delimiters inside quotes/braces).
List<String> splitByTopLevelOr(String rule) {
  final offsets = _topLevelOrOffsets(rule);
  if (offsets.isEmpty) return [rule];
  final parts = <String>[];
  var last = 0;
  for (final offset in offsets) {
    parts.add(rule.substring(last, offset));
    last = offset + 2;
  }
  parts.add(rule.substring(last));
  return parts;
}

List<String> _cssSelectText(String selector, String content) {
  final root = html_parser.parse(content).documentElement;
  if (root == null) return const [];
  return [
    for (final el in _safeQuerySelectorAll(root, selector))
      if (el.text.trim().isNotEmpty) el.text.trim(),
  ];
}

List<String> _jsoupSelect(
  String rule,
  String content, {
  required bool asElements,
}) {
  final root = html_parser.parse(content).documentElement;
  if (root == null) return const [];

  final parts = rule.split('@');
  var selections = <Element>[root];

  final lastIdx = parts.length - 1;
  var end = lastIdx;
  if (lastIdx > 0 && _isExtractionInstruction(parts[lastIdx].trim())) {
    end = lastIdx - 1;
  }

  for (var i = 0; i <= end; i++) {
    final part = parts[i].trim();
    if (part.isEmpty) continue;
    selections = [for (final sel in selections) ..._applyJsoupStep(sel, part)];
  }

  if (lastIdx > 0 && end == lastIdx - 1) {
    return _extractContent(selections, parts[lastIdx].trim());
  }
  if (asElements) {
    return [
      for (final sel in selections)
        if (sel.outerHtml.isNotEmpty) sel.outerHtml,
    ];
  }
  return _extractContent(selections, 'text');
}

const Set<String> _htmlTags = {
  'a',
  'abbr',
  'address',
  'area',
  'article',
  'aside',
  'audio',
  'b',
  'base',
  'bdi',
  'bdo',
  'blockquote',
  'body',
  'br',
  'button',
  'canvas',
  'caption',
  'cite',
  'code',
  'col',
  'colgroup',
  'data',
  'datalist',
  'dd',
  'del',
  'details',
  'dfn',
  'dialog',
  'div',
  'dl',
  'dt',
  'em',
  'embed',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'head',
  'header',
  'hr',
  'html',
  'i',
  'iframe',
  'img',
  'input',
  'ins',
  'kbd',
  'label',
  'legend',
  'li',
  'link',
  'main',
  'map',
  'mark',
  'math',
  'menu',
  'meta',
  'meter',
  'nav',
  'noscript',
  'object',
  'ol',
  'optgroup',
  'option',
  'output',
  'p',
  'param',
  'picture',
  'pre',
  'progress',
  'q',
  'rb',
  'rp',
  'rt',
  'rtc',
  'ruby',
  's',
  'samp',
  'script',
  'section',
  'select',
  'slot',
  'small',
  'source',
  'span',
  'strong',
  'style',
  'sub',
  'summary',
  'sup',
  'svg',
  'table',
  'tbody',
  'td',
  'template',
  'textarea',
  'tfoot',
  'th',
  'thead',
  'time',
  'title',
  'tr',
  'track',
  'u',
  'ul',
  'var',
  'video',
  'wbr',
};

bool _isExtractionInstruction(String step) {
  final pieces = step.split('.');
  final first = pieces[0].toLowerCase();
  switch (first) {
    case 'text':
    case 'textnodes':
    case 'owntext':
    case 'html':
    case 'all':
    case 'href':
    case 'src':
      return true;
    case 'tag':
    case 'class':
    case 'id':
    case 'children':
      return false;
  }
  if (int.tryParse(first) != null || _htmlTags.contains(first)) {
    return false;
  }
  return pieces.length <= 1;
}

class _BracketFilter {
  final bool has;
  final bool exclude;
  final int index;

  const _BracketFilter({
    this.has = false,
    this.exclude = false,
    this.index = 0,
  });
}

(String, _BracketFilter) _splitBracketFilter(String step) {
  if (!step.endsWith(']')) {
    return (step, const _BracketFilter());
  }
  final start = step.lastIndexOf('[');
  if (start < 0) {
    return (step, const _BracketFilter());
  }
  var inside = step.substring(start + 1, step.length - 1).trim();
  var exclude = false;
  if (inside.startsWith('!')) {
    exclude = true;
    inside = inside.substring(1).trim();
  }
  if (inside.contains(':')) {
    return (step, const _BracketFilter());
  }
  final idx = int.tryParse(inside);
  if (idx == null) {
    return (step, const _BracketFilter());
  }
  return (
    step.substring(0, start),
    _BracketFilter(has: true, exclude: exclude, index: idx),
  );
}

int _normalizeIndex(int idx, int length) => idx < 0 ? length + idx : idx;

List<Element> _applyJsoupStep(Element sel, String rawStep) {
  var step = rawStep;
  if (step.startsWith('-') && !step.contains('.')) {
    step = step.substring(1);
  }
  final (cleanedStep, bracketFilter) = _splitBracketFilter(step);
  step = cleanedStep;

  var excludeMode = false;
  var excludeIdx = -1;
  final bangIdx = step.indexOf('!');
  if (bangIdx > 0) {
    excludeMode = true;
    final idxStr = step.substring(bangIdx + 1);
    step = step.substring(0, bangIdx);
    excludeIdx = int.tryParse(idxStr) ?? -1;
  }

  final pieces = step.split('.');
  if (pieces.length < 2) {
    final found = _safeQuerySelectorAll(sel, step);
    return _filterFoundElements(found, bracketFilter, excludeMode, excludeIdx);
  }

  final selectorType = pieces[0];
  final selectorName = pieces[1];
  var index = -1;
  var hasIndex = false;
  if (pieces.length > 2) {
    final parsed = int.tryParse(pieces[2]);
    if (parsed != null) {
      index = parsed;
      hasIndex = true;
    }
  }
  if (bracketFilter.has && !bracketFilter.exclude) {
    index = bracketFilter.index;
    hasIndex = true;
  }

  final List<Element> found;
  switch (selectorType.toLowerCase()) {
    case 'tag':
      found = selectorName.isNotEmpty
          ? _safeQuerySelectorAll(sel, selectorName)
          : sel.children;
    case 'class':
      found = _safeQuerySelectorAll(
        sel,
        '.${selectorName.replaceAll(' ', '.')}',
      );
    case 'id':
      found = _safeQuerySelectorAll(sel, '#$selectorName');
    case 'children':
      found = sel.children;
    case 'text':
      return [sel];
    default:
      final direct = _safeQuerySelectorAll(sel, step);
      if (direct.isEmpty && selectorName.isNotEmpty) {
        final parsed = int.tryParse(selectorName);
        if (parsed != null) {
          final tagMatches = _safeQuerySelectorAll(sel, selectorType);
          if (tagMatches.isNotEmpty) {
            final idx = _normalizeIndex(parsed, tagMatches.length);
            return (idx >= 0 && idx < tagMatches.length)
                ? [tagMatches[idx]]
                : const [];
          }
        }
      }
      found = direct;
  }

  if (found.isEmpty) return const [];

  if (hasIndex) {
    final idx = _normalizeIndex(index, found.length);
    return (idx >= 0 && idx < found.length) ? [found[idx]] : const [];
  }

  return _filterFoundElements(found, bracketFilter, excludeMode, excludeIdx);
}

List<Element> _filterFoundElements(
  List<Element> found,
  _BracketFilter bracketFilter,
  bool excludeMode,
  int excludeIdx,
) {
  if (bracketFilter.has && !bracketFilter.exclude) {
    final idx = _normalizeIndex(bracketFilter.index, found.length);
    return (idx >= 0 && idx < found.length) ? [found[idx]] : const [];
  }
  return [
    for (var i = 0; i < found.length; i++)
      if (!(excludeMode && _normalizeIndex(excludeIdx, found.length) == i) &&
          !(bracketFilter.has &&
              bracketFilter.exclude &&
              _normalizeIndex(bracketFilter.index, found.length) == i))
        found[i],
  ];
}

List<Element> _safeQuerySelectorAll(Element root, String selector) {
  if (selector.trim().isEmpty) return const [];
  try {
    return root.querySelectorAll(selector);
  } catch (_) {
    return const [];
  }
}

List<String> _extractContent(List<Element> selections, String lastStep) {
  final pieces = lastStep.split('.');
  var contentType = 'text';
  if (pieces.length >= 2) {
    contentType = switch (pieces[0].toLowerCase()) {
      'tag' || 'class' || 'id' || 'children' => 'text',
      _ => pieces[1].toLowerCase(),
    };
  } else {
    final lower = lastStep.trim().toLowerCase();
    contentType = switch (lower) {
      'html' || 'all' => 'html',
      _ => lower,
    };
  }

  final results = <String>[];
  for (final sel in selections) {
    final text = switch (contentType) {
      'text' => sel.text.trim(),
      'owntext' || 'textnodes' => _directText(sel).trim(),
      'html' || 'all' => sel.innerHtml.trim(),
      'href' || 'src' => (sel.attributes[contentType] ?? '').trim(),
      _ =>
        (sel.attributes[contentType]?.isNotEmpty ?? false)
            ? sel.attributes[contentType]!.trim()
            : sel.text.trim(),
    };
    if (text.isNotEmpty) {
      results.add(text);
    }
  }
  return results;
}

String _directText(Element sel) {
  return [
    for (final node in sel.nodes)
      if (node.nodeType == Node.TEXT_NODE &&
          (node.text ?? '').trim().isNotEmpty)
        node.text!.trim(),
  ].join(' ');
}
