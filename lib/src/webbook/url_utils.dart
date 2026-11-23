/// Resolves a relative URL [ref] against [baseUrl].
String resolveWebUrl(String baseUrl, String ref) {
  if (ref.isEmpty) return baseUrl;
  if (ref.startsWith('http://') || ref.startsWith('https://')) {
    return ref;
  }
  if (ref.startsWith('/')) {
    var idx = baseUrl.length;
    final schemeEnd = baseUrl.indexOf('://');
    if (schemeEnd != -1) {
      idx = schemeEnd + 3;
      final pathStart = baseUrl.indexOf('/', idx);
      if (pathStart != -1) {
        idx = pathStart;
      }
    }
    return '${baseUrl.substring(0, idx)}$ref';
  }
  final lastSlash = baseUrl.lastIndexOf('/');
  if (lastSlash == -1) {
    return '$baseUrl/$ref';
  }
  return '${baseUrl.substring(0, lastSlash + 1)}$ref';
}
