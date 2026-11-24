import '../diagnostics/diagnostics.dart';
import 'json_helpers.dart';

/// Defines rules for parsing search and explore/discover results.
class SearchRule {
  final String bookList;
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String wordCount;

  const SearchRule({
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.bookUrl = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
  });

  factory SearchRule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SearchRule();
    return SearchRule(
      bookList: jsonAsString(json['bookList']),
      name: jsonAsString(json['name']),
      author: jsonAsString(json['author']),
      bookUrl: jsonAsString(json['bookUrl']),
      coverUrl: jsonAsString(json['coverUrl']),
      intro: jsonAsString(json['intro']),
      kind: jsonAsString(json['kind']),
      lastChapter: jsonAsString(json['lastChapter']),
      wordCount: jsonAsString(json['wordCount']),
    );
  }

  Map<String, dynamic> toJson() => {
    'bookList': bookList,
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
    'coverUrl': coverUrl,
    'intro': intro,
    'kind': kind,
    'lastChapter': lastChapter,
    'wordCount': wordCount,
  };
}

/// Explore/discover rules share the same schema as [SearchRule].
typedef ExploreRule = SearchRule;

/// Defines rules for parsing novel detail pages.
class NovelInfoRule {
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String tocUrl;
  final String init;
  final String wordCount;

  const NovelInfoRule({
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.tocUrl = '',
    this.init = '',
    this.wordCount = '',
  });

  factory NovelInfoRule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const NovelInfoRule();
    return NovelInfoRule(
      name: jsonAsString(json['name']),
      author: jsonAsString(json['author']),
      coverUrl: jsonAsString(json['coverUrl']),
      intro: jsonAsString(json['intro']),
      kind: jsonAsString(json['kind']),
      lastChapter: jsonAsString(json['lastChapter']),
      tocUrl: jsonAsString(json['tocUrl']),
      init: jsonAsString(json['init']),
      wordCount: jsonAsString(json['wordCount']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'author': author,
    'coverUrl': coverUrl,
    'intro': intro,
    'kind': kind,
    'lastChapter': lastChapter,
    'tocUrl': tocUrl,
    'init': init,
    'wordCount': wordCount,
  };
}

/// Defines rules for parsing a table of contents.
class TocRule {
  final String chapterList;
  final String chapterName;
  final String chapterUrl;
  final String nextTocUrl;

  const TocRule({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.nextTocUrl = '',
  });

  factory TocRule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TocRule();
    return TocRule(
      chapterList: jsonAsString(json['chapterList']),
      chapterName: jsonAsString(json['chapterName']),
      chapterUrl: jsonAsString(json['chapterUrl']),
      nextTocUrl: jsonAsString(json['nextTocUrl']),
    );
  }

  Map<String, dynamic> toJson() => {
    'chapterList': chapterList,
    'chapterName': chapterName,
    'chapterUrl': chapterUrl,
    'nextTocUrl': nextTocUrl,
  };
}

/// Defines rules for parsing chapter content.
class ContentRule {
  final String content;
  final String nextContentUrl;
  final String title;
  final String replaceRegex;
  final String imageStyle;

  const ContentRule({
    this.content = '',
    this.nextContentUrl = '',
    this.title = '',
    this.replaceRegex = '',
    this.imageStyle = '',
  });

  factory ContentRule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ContentRule();
    return ContentRule(
      content: jsonAsString(json['content']),
      nextContentUrl: jsonAsString(json['nextContentUrl']),
      title: jsonAsString(json['title']),
      replaceRegex: jsonAsString(json['replaceRegex']),
      imageStyle: jsonAsString(json['imageStyle']),
    );
  }

  Map<String, dynamic> toJson() => {
    'content': content,
    'nextContentUrl': nextContentUrl,
    'title': title,
    'replaceRegex': replaceRegex,
    'imageStyle': imageStyle,
  };
}

/// Represents a Legado novel source JSON definition.
///
/// JSON field keys remain aligned with the Legado schema (`bookSourceName`,
/// `ruleBookInfo`, etc.) for compatibility with existing source files.
class NovelSource {
  final String bookSourceName;
  final String bookSourceUrl;
  final String bookSourceGroup;
  final String bookSourceComment;
  final int bookSourceType;
  final bool enabled;
  final bool enabledExplore;
  final bool enabledCookieJar;
  final String searchUrl;
  final String header;
  final int weight;
  final int customOrder;
  final int lastUpdateTime;
  final SearchRule ruleSearch;
  final NovelInfoRule ruleNovelInfo;
  final TocRule ruleToc;
  final ContentRule ruleContent;
  final ExploreRule ruleExplore;
  final Object? exploreUrl;

  /// Runtime per-source success, failure, latency, and stage counters.
  final SourceStats stats;

  NovelSource({
    this.bookSourceName = '',
    this.bookSourceUrl = '',
    this.bookSourceGroup = '',
    this.bookSourceComment = '',
    this.bookSourceType = 0,
    this.enabled = false,
    this.enabledExplore = false,
    this.enabledCookieJar = false,
    this.searchUrl = '',
    this.header = '',
    this.weight = 0,
    this.customOrder = 0,
    this.lastUpdateTime = 0,
    this.ruleSearch = const SearchRule(),
    this.ruleNovelInfo = const NovelInfoRule(),
    this.ruleToc = const TocRule(),
    this.ruleContent = const ContentRule(),
    this.ruleExplore = const SearchRule(),
    this.exploreUrl,
    SourceStats? stats,
  }) : stats = stats ?? SourceStats();

  factory NovelSource.fromJson(Map<String, dynamic> json) => NovelSource(
    bookSourceName: jsonAsString(json['bookSourceName']),
    bookSourceUrl: jsonAsString(json['bookSourceUrl']),
    bookSourceGroup: jsonAsString(json['bookSourceGroup']),
    bookSourceComment: jsonAsString(json['bookSourceComment']),
    bookSourceType: jsonAsInt(json['bookSourceType']),
    enabled: jsonAsBool(json['enabled']),
    enabledExplore: jsonAsBool(json['enabledExplore']),
    enabledCookieJar: jsonAsBool(json['enabledCookieJar']),
    searchUrl: jsonAsString(json['searchUrl']),
    header: jsonAsString(json['header']),
    weight: jsonAsInt(json['weight']),
    customOrder: jsonAsInt(json['customOrder']),
    lastUpdateTime: jsonAsInt(json['lastUpdateTime']),
    ruleSearch: SearchRule.fromJson(jsonAsMap(json['ruleSearch'])),
    ruleNovelInfo: NovelInfoRule.fromJson(jsonAsMap(json['ruleBookInfo'])),
    ruleToc: TocRule.fromJson(jsonAsMap(json['ruleToc'])),
    ruleContent: ContentRule.fromJson(jsonAsMap(json['ruleContent'])),
    ruleExplore: SearchRule.fromJson(jsonAsMap(json['ruleExplore'])),
    exploreUrl: json['exploreUrl'],
  );

  Map<String, dynamic> toJson() => {
    'bookSourceName': bookSourceName,
    'bookSourceUrl': bookSourceUrl,
    'bookSourceGroup': bookSourceGroup,
    'bookSourceComment': bookSourceComment,
    'bookSourceType': bookSourceType,
    'enabled': enabled,
    'enabledExplore': enabledExplore,
    'enabledCookieJar': enabledCookieJar,
    'searchUrl': searchUrl,
    'header': header,
    'weight': weight,
    'customOrder': customOrder,
    'lastUpdateTime': lastUpdateTime,
    'ruleSearch': ruleSearch.toJson(),
    'ruleBookInfo': ruleNovelInfo.toJson(),
    'ruleToc': ruleToc.toJson(),
    'ruleContent': ruleContent.toJson(),
    'ruleExplore': ruleExplore.toJson(),
    'exploreUrl': exploreUrl,
  };

  /// Serializes the Legado source definition alongside runtime [stats].
  Map<String, dynamic> toJsonWithStats() => {
    ...toJson(),
    'stats': stats.toJson(),
  };

  @override
  String toString() =>
      'NovelSource(name: $bookSourceName, url: $bookSourceUrl, enabled: $enabled)';
}
