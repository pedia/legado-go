import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

/// Applies an XPath rule and returns the first match.
String xpathGetString(String rule, String content) {
  final list = xpathGetStringList(rule, content);
  return list.isEmpty ? '' : list.first;
}

/// Applies an XPath rule and returns all text/attribute matches.
List<String> xpathGetStringList(String rule, String content) =>
    _evaluateXPath(rule, content, asElements: false);

/// Applies an XPath rule and returns outer XML/HTML for matched elements
/// (or text/attribute values for non-element nodes), used by `getElements`.
List<String> xpathGetElementList(String rule, String content) =>
    _evaluateXPath(rule, content, asElements: true);

List<String> _evaluateXPath(
  String rule,
  String content, {
  required bool asElements,
}) {
  if (rule.isEmpty || content.isEmpty) {
    return const [];
  }
  final cleaned = rule.toLowerCase().startsWith('@xpath:')
      ? rule.substring(7)
      : rule;

  final dom.Document htmlDoc;
  try {
    htmlDoc = html_parser.parse(content);
  } catch (_) {
    return const [];
  }

  final xmlDoc = _htmlToXmlDocument(htmlDoc);

  final XPathValue value;
  try {
    // ignore: experimental_member_use
    value = xmlDoc.xpathEvaluate(cleaned);
  } catch (_) {
    return const [];
  }

  if (value is XPathNodeSet) {
    final results = <String>[];
    for (final node in value.nodes) {
      final val = _extractXNodeValue(node, asElements: asElements);
      if (val.isNotEmpty) {
        results.add(val);
      }
    }
    return results;
  }

  final str = value.string.trim();
  return str.isNotEmpty ? [str] : const [];
}

String _extractXNodeValue(XmlNode node, {required bool asElements}) {
  if (node is XmlAttribute) return node.value.trim();
  if (node is XmlText) return node.value.trim();
  if (node is XmlCDATA) return node.value.trim();
  if (node is XmlElement) {
    return asElements ? node.toXmlString() : node.innerText.trim();
  }
  return node.innerText.trim();
}

final RegExp _invalidXmlNameStart = RegExp(r'^[^a-zA-Z_:]');
final RegExp _invalidXmlNameChars = RegExp(r'[^a-zA-Z0-9_:\-.]');

String _sanitizeXmlName(String raw) {
  if (raw.isEmpty) return 'div';
  var cleaned = raw.replaceAll(_invalidXmlNameChars, '_');
  if (_invalidXmlNameStart.hasMatch(cleaned)) {
    cleaned = '_$cleaned';
  }
  return cleaned;
}

XmlDocument _htmlToXmlDocument(dom.Document doc) {
  return XmlDocument([
    for (final node in doc.nodes)
      if (_convertDomNode(node) case final converted?) converted,
  ]);
}

XmlNode? _convertDomNode(dom.Node node) {
  if (node is dom.Element) {
    final tagName = _sanitizeXmlName(node.localName ?? 'div');
    final attrs = <XmlAttribute>[];
    final seenAttrNames = <String>{};
    node.attributes.forEach((key, value) {
      final attrName = _sanitizeXmlName(key.toString());
      if (seenAttrNames.add(attrName)) {
        attrs.add(XmlAttribute(XmlName(attrName), value));
      }
    });
    final childNodes = <XmlNode>[
      for (final child in node.nodes)
        if (_convertDomNode(child) case final converted?) converted,
    ];
    return XmlElement(XmlName(tagName), attrs, childNodes);
  }
  if (node is dom.Text) {
    return XmlText(node.text);
  }
  if (node is dom.Comment) {
    return XmlComment(node.data ?? '');
  }
  return null;
}
