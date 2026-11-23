import 'json_helpers.dart';

/// Represents a chapter in a novel's table of contents.
class BookChapter {
  final String title;
  final String url;
  final String bookUrl;
  final int index;

  const BookChapter({
    this.title = '',
    this.url = '',
    this.bookUrl = '',
    this.index = 0,
  });

  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
    title: jsonAsString(json['title']),
    url: jsonAsString(json['url']),
    bookUrl: jsonAsString(json['bookUrl']),
    index: jsonAsInt(json['index']),
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'bookUrl': bookUrl,
    'index': index,
  };

  BookChapter copyWith({
    String? title,
    String? url,
    String? bookUrl,
    int? index,
  }) {
    return BookChapter(
      title: title ?? this.title,
      url: url ?? this.url,
      bookUrl: bookUrl ?? this.bookUrl,
      index: index ?? this.index,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookChapter &&
          title == other.title &&
          url == other.url &&
          bookUrl == other.bookUrl &&
          index == other.index;

  @override
  int get hashCode => Object.hash(title, url, bookUrl, index);

  @override
  String toString() => 'BookChapter(index: $index, title: $title)';
}
