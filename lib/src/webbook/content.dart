import '../analyzer/analyzer.dart';
import '../analyzer/regex.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/chapter.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches the content of a [chapter], handling `nextContentUrl` pagination.
Future<String> getContent(
  NovelSource source,
  Novel novel,
  BookChapter chapter,
) {
  return withSyncHttpBridge(() async {
    if (chapter.url.isEmpty) return '';

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
  });
}

Future<({String content, String nextUrl})> _parseContentPage(
  NovelSource source,
  String pageUrl,
) async {
  final aurl = AnalyzeUrl(pageUrl, '', 0, source.bookSourceUrl, source.header);

  final body = await aurl.getStrResponse();
  if (body.isEmpty) {
    return (content: '', nextUrl: '');
  }

  final ar = AnalyzeRule(body, aurl.finalUrl);
  final contentRule = source.ruleContent;

  var content = contentRule.content.isNotEmpty
      ? ar.getString(contentRule.content)
      : '';

  if (content.isNotEmpty) {
    content = content.trim();
    if (contentRule.replaceRegex.isNotEmpty) {
      content = applyRegex(contentRule.replaceRegex, content);
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
