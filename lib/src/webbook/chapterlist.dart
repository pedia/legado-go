import '../analyzer/analyzer.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/chapter.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches the table of contents for a [novel], handling `nextTocUrl` pagination.
Future<List<BookChapter>> getChapterList(NovelSource source, Novel novel) {
  return withSyncHttpBridge(() async {
    var tocUrl = novel.tocUrl.isNotEmpty ? novel.tocUrl : novel.bookUrl;

    final allChapters = <BookChapter>[];
    final visited = <String>{};
    const maxPages = 20;

    for (var i = 0; i < maxPages; i++) {
      if (tocUrl.isEmpty || !visited.add(tocUrl)) {
        break;
      }

      try {
        final (:chapters, :nextUrl) = await _parseChapterPage(source, tocUrl);
        allChapters.addAll(chapters);
        tocUrl = nextUrl;
      } catch (_) {
        if (i == 0) rethrow;
        break;
      }
    }

    return [
      for (var i = 0; i < allChapters.length; i++)
        allChapters[i].copyWith(index: i, bookUrl: novel.bookUrl),
    ];
  });
}

Future<({List<BookChapter> chapters, String nextUrl})> _parseChapterPage(
  NovelSource source,
  String pageUrl,
) async {
  final aurl = AnalyzeUrl(pageUrl, '', 0, source.bookSourceUrl, source.header);

  final body = await aurl.getStrResponse();
  if (body.isEmpty) {
    return (chapters: const <BookChapter>[], nextUrl: '');
  }

  final ar = AnalyzeRule(body, aurl.finalUrl);
  final tocRule = source.ruleToc;

  var listRule = tocRule.chapterList;
  if (listRule.isEmpty) {
    return (chapters: const <BookChapter>[], nextUrl: '');
  }

  var reverse = false;
  if (listRule.startsWith('-')) {
    reverse = true;
    listRule = listRule.substring(1);
  }

  final chapterElements = ar.getElements(listRule);
  if (chapterElements.isEmpty) {
    return (chapters: const <BookChapter>[], nextUrl: '');
  }

  var chapters = <BookChapter>[];
  for (final elem in chapterElements) {
    final elemAr = AnalyzeRule(elem, aurl.finalUrl);
    final chapterName = tocRule.chapterName.isNotEmpty
        ? elemAr.getString(tocRule.chapterName)
        : '';
    var chapterUrl = tocRule.chapterUrl.isNotEmpty
        ? elemAr.getString(tocRule.chapterUrl)
        : '';
    if (chapterUrl.isNotEmpty) {
      chapterUrl = resolveWebUrl(aurl.finalUrl, chapterUrl);
    }

    if (chapterName.isNotEmpty || chapterUrl.isNotEmpty) {
      chapters.add(BookChapter(title: chapterName, url: chapterUrl));
    }
  }

  if (reverse) {
    chapters = chapters.reversed.toList();
  }

  var nextUrl = '';
  if (tocRule.nextTocUrl.isNotEmpty) {
    nextUrl = ar.getString(tocRule.nextTocUrl);
    if (nextUrl.isNotEmpty) {
      nextUrl = resolveWebUrl(aurl.finalUrl, nextUrl);
    }
  }

  return (chapters: chapters, nextUrl: nextUrl);
}
