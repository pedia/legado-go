import '../analyzer/analyzer.dart';
import '../analyzer/sync_http_bridge.dart';
import '../analyzeurl/analyzeurl.dart';
import '../diagnostics/diagnostics.dart';
import '../model/novel.dart';
import '../model/novel_source.dart';
import 'url_utils.dart';

/// Fetches metadata for a novel from its detail page.
Future<Novel?> getNovelInfo(
  NovelSource source,
  String bookUrl, {
  GoproLogger? logger,
}) {
  final log = logger ?? GoproLogger.silent;
  return withSyncHttpBridge(() async {
    final sw = Stopwatch()..start();
    try {
      final aurl = AnalyzeUrl(
        bookUrl,
        '',
        0,
        source.bookSourceUrl,
        source.header,
      );

      log.debug(
        stage: PipelineStage.novelInfo,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        message: 'Fetching novel info -> ${aurl.finalUrl}',
      );

      final body = await aurl.getStrResponse();
      if (body.isEmpty) {
        sw.stop();
        const msg = 'Empty HTTP response body';
        source.stats.recordFailure(
          PipelineStage.novelInfo,
          sw.elapsedMilliseconds,
          FailureCategory.emptyResponse,
          msg,
        );
        log.warn(
          stage: PipelineStage.novelInfo,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: FailureCategory.emptyResponse,
          durationMs: sw.elapsedMilliseconds,
          message: 'Novel info page returned empty body (${aurl.finalUrl})',
        );
        return null;
      }

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

      final novel = Novel(
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

      sw.stop();
      if (infoRule.name.isNotEmpty && novel.name.isEmpty) {
        final msg = 'Failed to extract novel name with rule "${infoRule.name}"';
        source.stats.recordFailure(
          PipelineStage.novelInfo,
          sw.elapsedMilliseconds,
          FailureCategory.ruleMismatch,
          msg,
        );
        log.warn(
          stage: PipelineStage.novelInfo,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          category: FailureCategory.ruleMismatch,
          durationMs: sw.elapsedMilliseconds,
          message: '$msg (${aurl.finalUrl})',
        );
      } else {
        source.stats.recordSuccess(
          PipelineStage.novelInfo,
          sw.elapsedMilliseconds,
        );
        log.info(
          stage: PipelineStage.novelInfo,
          sourceName: source.bookSourceName,
          sourceUrl: source.bookSourceUrl,
          durationMs: sw.elapsedMilliseconds,
          message: 'Parsed novel info "${novel.name}"',
        );
      }

      return novel;
    } catch (e) {
      sw.stop();
      final category = FailureClassifier.classify(e);
      final summary = FailureClassifier.summarizeError(e);
      source.stats.recordFailure(
        PipelineStage.novelInfo,
        sw.elapsedMilliseconds,
        category,
        summary,
      );
      log.error(
        stage: PipelineStage.novelInfo,
        sourceName: source.bookSourceName,
        sourceUrl: source.bookSourceUrl,
        category: category,
        durationMs: sw.elapsedMilliseconds,
        message: 'Failed to fetch novel info ($bookUrl)',
        error: e,
      );
      rethrow;
    }
  });
}
