import '../analyzer/analyzer.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/booksource.dart';
import '../model/novel.dart';
import 'url_utils.dart';

/// Fetches metadata for a novel from its detail page.
Future<Novel?> getBookInfo(
  BookSource source,
  String bookUrl, [
  JsPool? jsPool,
]) async {
  final aurl = AnalyzeUrl(
    bookUrl,
    '',
    0,
    source.bookSourceUrl,
    source.header,
    jsPool,
  );

  final body = await aurl.getStrResponse(jsPool);
  if (body.isEmpty) {
    return null;
  }

  final ar = AnalyzeRule(body, aurl.finalUrl, jsPool);
  final infoRule = source.ruleBookInfo;

  if (infoRule.init.isNotEmpty) {
    final initResult = ar.getElement(infoRule.init);
    if (initResult.isNotEmpty) {
      ar.setContent(initResult, aurl.finalUrl);
    }
  }

  final rawCoverUrl = infoRule.coverUrl.isNotEmpty
      ? ar.getString(infoRule.coverUrl)
      : '';
  final rawTocUrl = infoRule.tocUrl.isNotEmpty
      ? ar.getString(infoRule.tocUrl)
      : '';

  final coverUrl = rawCoverUrl.isNotEmpty
      ? resolveWebUrl(aurl.finalUrl, rawCoverUrl)
      : '';
  final tocUrl = rawTocUrl.isNotEmpty
      ? resolveWebUrl(aurl.finalUrl, rawTocUrl)
      : aurl.finalUrl;

  return Novel(
    name: infoRule.name.isNotEmpty ? ar.getString(infoRule.name) : '',
    author: infoRule.author.isNotEmpty ? ar.getString(infoRule.author) : '',
    coverUrl: coverUrl,
    intro: infoRule.intro.isNotEmpty ? ar.getString(infoRule.intro) : '',
    kind: infoRule.kind.isNotEmpty ? ar.getString(infoRule.kind) : '',
    lastChapter: infoRule.lastChapter.isNotEmpty
        ? ar.getString(infoRule.lastChapter)
        : '',
    wordCount: infoRule.wordCount.isNotEmpty
        ? ar.getString(infoRule.wordCount)
        : '',
    tocUrl: tocUrl,
    bookUrl: bookUrl,
    origin: source.bookSourceUrl,
    originName: source.bookSourceName,
  );
}
