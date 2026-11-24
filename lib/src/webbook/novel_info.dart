import '../analyzer/analyzer.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches metadata for a novel from its detail page.
Future<Novel?> getNovelInfo(NovelSource source, String bookUrl) {
  return withSyncHttpBridge(() async {
    final aurl = AnalyzeUrl(
      bookUrl,
      '',
      0,
      source.bookSourceUrl,
      source.header,
    );

    final body = await aurl.getStrResponse();
    if (body.isEmpty) return null;

    final ar = AnalyzeRule(body, aurl.finalUrl);
    final infoRule = source.ruleNovelInfo;

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

    return Novel(
      name: infoRule.name.isNotEmpty ? ar.getString(infoRule.name) : '',
      author: infoRule.author.isNotEmpty ? ar.getString(infoRule.author) : '',
      coverUrl: rawCoverUrl.isNotEmpty
          ? resolveWebUrl(aurl.finalUrl, rawCoverUrl)
          : '',
      intro: infoRule.intro.isNotEmpty ? ar.getString(infoRule.intro) : '',
      kind: infoRule.kind.isNotEmpty ? ar.getString(infoRule.kind) : '',
      lastChapter: infoRule.lastChapter.isNotEmpty
          ? ar.getString(infoRule.lastChapter)
          : '',
      wordCount: infoRule.wordCount.isNotEmpty
          ? ar.getString(infoRule.wordCount)
          : '',
      tocUrl: rawTocUrl.isNotEmpty
          ? resolveWebUrl(aurl.finalUrl, rawTocUrl)
          : aurl.finalUrl,
      bookUrl: bookUrl,
      origin: source.bookSourceUrl,
      originName: source.bookSourceName,
    );
  });
}
