import '../analyzer/analyzer.dart';
import '../analyzer/regex.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/booksource.dart';
import '../model/chapter.dart';
import '../model/novel.dart';
import 'url_utils.dart';

/// Fetches the content of a [chapter], handling `nextContentUrl` pagination.
Future<String> getContent(
  BookSource source,
  Novel novel,
  BookChapter chapter, [
  JsPool? jsPool,
]) async {
  if (chapter.url.isEmpty) {
    return '';
  }

  final contentParts = <String>[];
  final visited = <String>{};
  const maxPages = 10;

  var currentUrl = chapter.url;
  for (var i = 0; i < maxPages; i++) {
    if (currentUrl.isEmpty || !visited.add(currentUrl)) {
      break;
    }

    try {
      final (:content, :nextUrl) = await _parseContentPage(
        source,
        currentUrl,
        jsPool,
      );
      if (content.isNotEmpty) {
        contentParts.add(content);
      }
      currentUrl = nextUrl;
    } catch (_) {
      if (i == 0) rethrow;
      break;
    }
  }

  return contentParts.join('\n');
}

Future<({String content, String nextUrl})> _parseContentPage(
  BookSource source,
  String pageUrl,
  JsPool? jsPool,
) async {
  final aurl = AnalyzeUrl(
    pageUrl,
    '',
    0,
    source.bookSourceUrl,
    source.header,
    jsPool,
  );

  final body = await aurl.getStrResponse(jsPool);
  if (body.isEmpty) {
    return (content: '', nextUrl: '');
  }

  final ar = AnalyzeRule(body, aurl.finalUrl, jsPool);
  final contentRule = source.ruleContent;

  var content = contentRule.content.isNotEmpty
      ? ar.getString(contentRule.content)
      : '';

  if (content.isNotEmpty) {
    content = content.trim();
    if (contentRule.replaceRegex.isNotEmpty) {
      content = _applyReplaceRegex(content, contentRule.replaceRegex);
    }
    content = cleanContent(content);
  }

  var nextUrl = '';
  if (contentRule.nextContentUrl.isNotEmpty) {
    nextUrl = ar.getString(contentRule.nextContentUrl);
    if (nextUrl.isNotEmpty) {
      nextUrl = resolveWebUrl(aurl.finalUrl, nextUrl);
    }
  }

  return (content: content, nextUrl: nextUrl);
}

String _applyReplaceRegex(String content, String rule) {
  final parts = splitN(rule, '##', 3);
  var pattern = rule;
  var replacement = '';
  if (parts.length >= 2) {
    pattern = parts[0];
    replacement = parts[1];
  }
  if (parts.length == 3) {
    replacement = parts[2];
  }
  if (pattern.trim().isEmpty) {
    return content;
  }
  try {
    final re = RegExp(pattern);
    return regexReplaceAll(re, content, replacement);
  } on FormatException {
    return content;
  }
}

/// Removes common ad patterns and normalizes whitespace lines.
String cleanContent(String raw) {
  var content = raw;
  const adPatterns = [
    '请到最新章节',
    '手机阅读：',
    '一秒记住',
    '请记住本书首发域名',
    '天才一秒记住',
    '最新章节！',
  ];

  for (final pattern in adPatterns) {
    final idx = content.indexOf(pattern);
    if (idx != -1) {
      final endIdx = content.indexOf('\n', idx);
      content = endIdx != -1
          ? content.substring(0, idx) + content.substring(endIdx + 1)
          : content.substring(0, idx);
    }
  }

  return [
    for (final line in content.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ].join('\n');
}
