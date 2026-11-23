import 'dart:async';

import '../analyzer/analyzer.dart';
import '../analyzeurl/analyzeurl.dart';
import '../model/booksource.dart';
import '../model/novel.dart';
import 'url_utils.dart';

class SourceError {
  final String sourceName;
  final String sourceUrl;
  final String stage;
  final String error;

  const SourceError({
    required this.sourceName,
    required this.sourceUrl,
    required this.stage,
    required this.error,
  });

  Map<String, dynamic> toJson() => {
    'sourceName': sourceName,
    'sourceUrl': sourceUrl,
    'stage': stage,
    'error': error,
  };
}

class SearchReport {
  final List<SearchBook> results;
  final List<SourceError> errors;

  const SearchReport({required this.results, this.errors = const []});

  Map<String, dynamic> toJson() => {
    'results': results.map((r) => r.toJson()).toList(),
    if (errors.isNotEmpty) 'errors': errors.map((e) => e.toJson()).toList(),
  };
}

/// Searches novels across multiple sources concurrently.
Future<List<SearchBook>> searchBooks(
  List<BookSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  JsPool? jsPool,
]) async {
  final report = await searchBooksDetailed(
    sources,
    key,
    page,
    maxConcurrency,
    jsPool,
  );
  return report.results;
}

/// Like [searchBooks] but preserves per-source diagnostics.
Future<SearchReport> searchBooksDetailed(
  List<BookSource> sources,
  String key,
  int page, [
  int maxConcurrency = 10,
  JsPool? jsPool,
]) async {
  final concurrency = maxConcurrency <= 0 ? 10 : maxConcurrency;
  final activeSources = [
    for (final s in sources)
      if (s.enabled && s.searchUrl.isNotEmpty) s,
  ];

  final results = <SearchBook>[];
  final errors = <SourceError>[];

  var nextIndex = 0;
  Future<void> worker() async {
    while (nextIndex < activeSources.length) {
      final src = activeSources[nextIndex++];
      try {
        final found = await searchFromSource(src, key, page, jsPool);
        results.addAll(found);
      } catch (e) {
        errors.add(
          SourceError(
            sourceName: src.bookSourceName,
            sourceUrl: src.bookSourceUrl,
            stage: 'search',
            error: e.toString(),
          ),
        );
      }
    }
  }

  final workerCount = concurrency < activeSources.length
      ? concurrency
      : activeSources.length;
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);

  return SearchReport(results: results, errors: errors);
}

/// Searches novels from a single [source].
Future<List<SearchBook>> searchFromSource(
  BookSource source,
  String key,
  int page, [
  JsPool? jsPool,
]) async {
  final aurl = AnalyzeUrl(
    source.searchUrl,
    key,
    page,
    source.bookSourceUrl,
    source.header,
    jsPool,
  )..setComment(source.bookSourceComment);

  final body = await aurl.getStrResponse(jsPool);
  if (body.isEmpty) {
    return const [];
  }

  final ar = AnalyzeRule(body, aurl.finalUrl, jsPool);
  final bookListRule = source.ruleSearch.bookList;
  if (bookListRule.isEmpty) {
    return const [];
  }

  final bookItems = ar.getElements(bookListRule);
  if (bookItems.isEmpty) {
    throw StateError(
      'no results matched rule "$bookListRule" (body len=${body.length})',
    );
  }

  final items = <SearchBook>[];
  for (final item in bookItems) {
    final itemAr = AnalyzeRule(item, aurl.finalUrl, jsPool);
    var bookUrl = itemAr.getString(source.ruleSearch.bookUrl);
    var coverUrl = itemAr.getString(source.ruleSearch.coverUrl);

    if (bookUrl.isNotEmpty) {
      bookUrl = resolveWebUrl(aurl.finalUrl, bookUrl);
    }
    if (coverUrl.isNotEmpty) {
      coverUrl = resolveWebUrl(aurl.finalUrl, coverUrl);
    }

    final found = SearchBook(
      name: itemAr.getString(source.ruleSearch.name),
      author: itemAr.getString(source.ruleSearch.author),
      coverUrl: coverUrl,
      intro: itemAr.getString(source.ruleSearch.intro),
      kind: itemAr.getString(source.ruleSearch.kind),
      lastChapter: itemAr.getString(source.ruleSearch.lastChapter),
      wordCount: itemAr.getString(source.ruleSearch.wordCount),
      bookUrl: bookUrl,
      origin: source.bookSourceUrl,
      originName: source.bookSourceName,
    );

    if (found.name.isNotEmpty) {
      items.add(found);
    }
  }
  return items;
}
