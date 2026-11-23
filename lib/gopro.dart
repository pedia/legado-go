import 'src/analyzer/analyzer.dart';
import 'src/model/booksource.dart';
import 'src/model/chapter.dart';
import 'src/model/novel.dart';
import 'src/webbook/bookinfo.dart' as wb_bookinfo;
import 'src/webbook/chapterlist.dart' as wb_chapters;
import 'src/webbook/content.dart' as wb_content;
import 'src/webbook/search.dart' as wb_search;

export 'src/analyzer/analyzer.dart';
export 'src/analyzer/css.dart';
export 'src/analyzer/jsonpath.dart';
export 'src/analyzer/legado_stub.dart';
export 'src/analyzer/regex.dart';
export 'src/analyzer/source_rule.dart';
export 'src/analyzer/sync_http_bridge.dart';
export 'src/analyzer/xpath.dart';
export 'src/analyzeurl/analyzeurl.dart';
export 'src/compare/cli_compare.dart';
export 'src/model/booksource.dart';
export 'src/model/chapter.dart';
export 'src/model/loader.dart';
export 'src/model/novel.dart';
export 'src/webbook/bookinfo.dart';
export 'src/webbook/chapterlist.dart';
export 'src/webbook/content.dart';
export 'src/webbook/search.dart';

final JsPool _defaultJsPool = JsPool(5);

/// Searches novels across multiple [sources] concurrently.
Future<List<SearchBook>> searchBooks(
  List<BookSource> sources,
  String key,
  int page,
) => wb_search.searchBooks(sources, key, page, 10, _defaultJsPool);

/// Fetches metadata for a novel at [bookUrl] from [source].
Future<Novel?> getBookInfo(BookSource source, String bookUrl) =>
    wb_bookinfo.getBookInfo(source, bookUrl, _defaultJsPool);

/// Fetches the table of contents for [novel] from [source].
Future<List<BookChapter>> getChapterList(BookSource source, Novel novel) =>
    wb_chapters.getChapterList(source, novel, _defaultJsPool);

/// Fetches the content of [chapter] for [novel] from [source].
Future<String> getContent(
  BookSource source,
  Novel novel,
  BookChapter chapter,
) => wb_content.getContent(source, novel, chapter, _defaultJsPool);
