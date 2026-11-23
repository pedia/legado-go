import 'json_helpers.dart';

/// Represents a novel found during search.
class SearchBook {
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String bookUrl;
  final String wordCount;
  final String origin;
  final String originName;

  const SearchBook({
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.bookUrl = '',
    this.wordCount = '',
    this.origin = '',
    this.originName = '',
  });

  factory SearchBook.fromJson(Map<String, dynamic> json) => SearchBook(
    name: jsonAsString(json['name']),
    author: jsonAsString(json['author']),
    coverUrl: jsonAsString(json['coverUrl']),
    intro: jsonAsString(json['intro']),
    kind: jsonAsString(json['kind']),
    lastChapter: jsonAsString(json['lastChapter']),
    bookUrl: jsonAsString(json['bookUrl']),
    wordCount: jsonAsString(json['wordCount']),
    origin: jsonAsString(json['origin']),
    originName: jsonAsString(json['originName']),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'author': author,
    'coverUrl': coverUrl,
    'intro': intro,
    'kind': kind,
    'lastChapter': lastChapter,
    'bookUrl': bookUrl,
    'wordCount': wordCount,
    'origin': origin,
    'originName': originName,
  };

  /// Converts this [SearchBook] summary into a [Novel].
  Novel toNovel() => Novel(
    name: name,
    author: author,
    coverUrl: coverUrl,
    intro: intro,
    kind: kind,
    lastChapter: lastChapter,
    wordCount: wordCount,
    bookUrl: bookUrl,
    origin: origin,
    originName: originName,
  );

  SearchBook copyWith({
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
    String? kind,
    String? lastChapter,
    String? bookUrl,
    String? wordCount,
    String? origin,
    String? originName,
  }) {
    return SearchBook(
      name: name ?? this.name,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      kind: kind ?? this.kind,
      lastChapter: lastChapter ?? this.lastChapter,
      bookUrl: bookUrl ?? this.bookUrl,
      wordCount: wordCount ?? this.wordCount,
      origin: origin ?? this.origin,
      originName: originName ?? this.originName,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchBook &&
          name == other.name &&
          author == other.author &&
          coverUrl == other.coverUrl &&
          intro == other.intro &&
          kind == other.kind &&
          lastChapter == other.lastChapter &&
          bookUrl == other.bookUrl &&
          wordCount == other.wordCount &&
          origin == other.origin &&
          originName == other.originName;

  @override
  int get hashCode => Object.hash(
    name,
    author,
    coverUrl,
    intro,
    kind,
    lastChapter,
    bookUrl,
    wordCount,
    origin,
    originName,
  );

  @override
  String toString() =>
      'SearchBook(name: $name, author: $author, origin: $originName)';
}

/// Represents a novel with full detail metadata.
class Novel {
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String wordCount;
  final String tocUrl;
  final String bookUrl;
  final String origin;
  final String originName;

  const Novel({
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
    this.tocUrl = '',
    this.bookUrl = '',
    this.origin = '',
    this.originName = '',
  });

  factory Novel.fromJson(Map<String, dynamic> json) => Novel(
    name: jsonAsString(json['name']),
    author: jsonAsString(json['author']),
    coverUrl: jsonAsString(json['coverUrl']),
    intro: jsonAsString(json['intro']),
    kind: jsonAsString(json['kind']),
    lastChapter: jsonAsString(json['lastChapter']),
    wordCount: jsonAsString(json['wordCount']),
    tocUrl: jsonAsString(json['tocUrl']),
    bookUrl: jsonAsString(json['bookUrl']),
    origin: jsonAsString(json['origin']),
    originName: jsonAsString(json['originName']),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'author': author,
    'coverUrl': coverUrl,
    'intro': intro,
    'kind': kind,
    'lastChapter': lastChapter,
    'wordCount': wordCount,
    'tocUrl': tocUrl,
    'bookUrl': bookUrl,
    'origin': origin,
    'originName': originName,
  };

  Novel copyWith({
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
    String? kind,
    String? lastChapter,
    String? wordCount,
    String? tocUrl,
    String? bookUrl,
    String? origin,
    String? originName,
  }) {
    return Novel(
      name: name ?? this.name,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      kind: kind ?? this.kind,
      lastChapter: lastChapter ?? this.lastChapter,
      wordCount: wordCount ?? this.wordCount,
      tocUrl: tocUrl ?? this.tocUrl,
      bookUrl: bookUrl ?? this.bookUrl,
      origin: origin ?? this.origin,
      originName: originName ?? this.originName,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Novel &&
          name == other.name &&
          author == other.author &&
          coverUrl == other.coverUrl &&
          intro == other.intro &&
          kind == other.kind &&
          lastChapter == other.lastChapter &&
          wordCount == other.wordCount &&
          tocUrl == other.tocUrl &&
          bookUrl == other.bookUrl &&
          origin == other.origin &&
          originName == other.originName;

  @override
  int get hashCode => Object.hash(
    name,
    author,
    coverUrl,
    intro,
    kind,
    lastChapter,
    wordCount,
    tocUrl,
    bookUrl,
    origin,
    originName,
  );

  @override
  String toString() => 'Novel(name: $name, author: $author, bookUrl: $bookUrl)';
}
