import 'package:gopro/gopro.dart';
import 'package:test/test.dart';

const String _testHTML = '''
<html><body>
<div class="txt-list">
  <ul>
    <li><a href="/book/1">Book One</a><span class="author">Author A</span></li>
    <li><a href="/book/2">Book Two</a><span class="author">Author B</span></li>
  </ul>
</div>
<div class="v-list-item">
  <div class="v-title">Novel Title</div>
  <div class="v-author">Author C</div>
  <img src="/cover.jpg" />
</div>
<div class="novel-item">
  <a href="/book/3">Book Three</a>
</div>
<div id="booklist">
  <table><tbody>
    <tr><td>Row1</td></tr>
    <tr><td>Row2</td></tr>
  </tbody></table>
</div>
</body></html>
''';

void main() {
  test('cssGetStringList .v-list-item returns text', () {
    final results = cssGetStringList('.v-list-item', _testHTML, '');
    expect(results, isNotEmpty);
    expect(results.first, contains('Novel Title'));
    expect(results.first, contains('Author C'));
  });

  test('cssGetStringList class.txt-list.0@tag.li returns li texts', () {
    final results = cssGetStringList('class.txt-list.0@tag.li', _testHTML, '');
    expect(results.length, 2);
    for (final r in results) {
      expect(r, isNotEmpty);
    }
  });

  test('cssGetStringList class.txt-list.0@tag.a.0@href extracts href', () {
    final results = cssGetStringList(
      'class.txt-list.0@tag.a.0@href',
      _testHTML,
      '',
    );
    expect(results, isNotEmpty);
    expect(results.first, '/book/1');
  });

  test('cssGetStringList .v-list-item@img@src extracts img src', () {
    final results = cssGetStringList('.v-list-item@img@src', _testHTML, '');
    expect(results, isNotEmpty);
    expect(results.first, '/cover.jpg');
  });

  test('cssGetStringList class.novel-item returns text', () {
    final results = cssGetStringList('class.novel-item', _testHTML, '');
    expect(results, isNotEmpty);
    expect(results.first, 'Book Three');
  });

  test('cssGetStringList #booklist@tag.tr finds tr elements', () {
    final results = cssGetStringList('#booklist@tag.tr', _testHTML, '');
    expect(results.length, greaterThanOrEqualTo(2));
  });
}
