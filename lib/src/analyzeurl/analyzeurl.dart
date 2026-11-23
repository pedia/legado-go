import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:js_interpreter/js_interpreter.dart';

import '../analyzer/analyzer.dart';
import '../analyzer/legado_stub.dart';
import '../analyzer/sync_http_bridge.dart';

final RegExp _pagePattern = RegExp(r'\{\{page(?:\|(\d+(?:,\d+)*))?\}\}');
final RegExp _keyPattern = RegExp(r'\{\{key\}\}');
final RegExp _angleBracketPagePattern = RegExp(r'<(.*?)>');

const String _defaultUserAgent =
    'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// Represents the JSON option appended after a URL (comma-separated).
class URLOption {
  final String method;
  final Map<String, String> headers;
  final Object? body;
  final String charset;
  final String type;
  final String js;
  final Object? retry;
  final Object? webView;
  final String webJs;
  final Object? serverID;
  final Object? webViewDelayTime;
  final String proxy;

  const URLOption({
    this.method = '',
    this.headers = const {},
    this.body,
    this.charset = '',
    this.type = '',
    this.js = '',
    this.retry,
    this.webView,
    this.webJs = '',
    this.serverID,
    this.webViewDelayTime,
    this.proxy = '',
  });

  factory URLOption.fromJson(Map<String, dynamic> json) {
    final hdrs = <String, String>{};
    final rawHdrs = json['headers'];
    if (rawHdrs is Map) {
      rawHdrs.forEach((k, v) {
        hdrs[k.toString()] = _stringifyOptionValue(v);
      });
    }
    return URLOption(
      method: (json['method'] ?? '').toString(),
      headers: hdrs,
      body: json['body'],
      charset: (json['charset'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      js: (json['js'] ?? '').toString(),
      retry: json['retry'],
      webView: json['webView'],
      webJs: (json['webJs'] ?? '').toString(),
      serverID: json['serverID'],
      webViewDelayTime: json['webViewDelayTime'],
      proxy: (json['proxy'] ?? '').toString(),
    );
  }
}

/// Handles Legado URL template expansion and HTTP requests.
class AnalyzeUrl {
  String ruleUrl;
  String finalUrl = '';
  String method = 'GET';
  String body = '';
  Map<String, String> headerMap = {};
  String charset = '';
  String sourceUrl;
  String sourceHeader;
  String jsCode = '';
  final JsPool? _jsPool;
  String _encodedKey = '';
  String _rawKey = '';
  int page = 0;
  String sourceComment = '';
  String type = '';
  int retry = 0;
  bool useWebView = false;
  String webJs = '';
  String serverID = '';
  int webViewDelay = 0;
  String proxy = '';

  AnalyzeUrl(
    this.ruleUrl,
    String key,
    int page,
    this.sourceUrl,
    this.sourceHeader, [
    this._jsPool,
  ]) {
    _initUrl(key, page);
  }

  AnalyzeUrl.empty({
    this.ruleUrl = '',
    this.method = 'GET',
    this.sourceUrl = '',
    this.sourceHeader = '',
    this.page = 0,
    JsPool? jsPool,
  }) : _jsPool = jsPool;

  /// Stores [comment] (`bookSourceComment`) for `eval()` in inline expressions
  /// and re-derives the URL from the original template.
  void setComment(String comment) {
    sourceComment = comment;
    if (sourceComment.isEmpty) return;

    var url = ruleUrl.replaceAll(_keyPattern, _encodedKey);
    if (page > 0) {
      url = _replacePagePattern(url, page);
    }
    if (jsCode.isNotEmpty) return;

    if (url.contains('{{')) {
      finalUrl = url;
      if (_jsPool != null) {
        resolveInlineExpressions();
      }
    } else {
      url = resolveAngleBracketPages(url);
      finalUrl = processUrl(url);
    }
  }

  void _initUrl(String key, int pageNum) {
    var url = ruleUrl;
    _encodedKey = Uri.encodeQueryComponent(key);
    _rawKey = key;
    url = url.replaceAll(_keyPattern, _encodedKey);

    page = pageNum;
    if (pageNum > 0) {
      url = _replacePagePattern(url, pageNum);
    }

    if (url.startsWith('@js:')) {
      jsCode = url.substring(4);
      url = '';
    } else if (url.startsWith('<js>')) {
      final end = url.indexOf('</js>');
      if (end != -1) {
        jsCode = url.substring(4, end);
        url = url.substring(end + 5).trim();
      }
    }

    if (url.contains('{{')) {
      finalUrl = url;
      if (_jsPool != null) {
        resolveInlineExpressions();
      }
    } else {
      url = resolveAngleBracketPages(url);
      finalUrl = processUrl(url);
    }

    final parsedHeaders = parseStringMap(sourceHeader, sourceUrl);
    for (final entry in parsedHeaders.entries) {
      if (entry.key.toLowerCase() == 'proxy') {
        proxy = entry.value;
        continue;
      }
      headerMap.putIfAbsent(entry.key, () => entry.value);
    }

    if (!headerMap.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headerMap['User-Agent'] = _defaultUserAgent;
    }
  }

  String _replacePagePattern(String url, int pageNum) {
    return url.replaceAllMapped(_pagePattern, (match) {
      final custom = match.group(1);
      if (custom != null && custom.isNotEmpty) {
        final pageStrs = custom.split(',');
        final idx = pageNum - 1;
        return idx < pageStrs.length
            ? pageStrs[idx].trim()
            : pageStrs.last.trim();
      }
      return pageNum.toString();
    });
  }

  /// Parses the URL option JSON string.
  void parseUrlOption(String optionStr) {
    final jsonStr = normalizeJsonLike(optionStr);
    final URLOption opt;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;
      opt = URLOption.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (_) {
      return;
    }

    if (opt.method.isNotEmpty) {
      method = opt.method.toUpperCase();
    }
    if (opt.body != null) {
      body = _stringifyOptionValue(opt.body);
      if (_encodedKey != _rawKey && _encodedKey.isNotEmpty) {
        body = body.replaceAll(_encodedKey, _rawKey);
      }
    }
    if (opt.charset.isNotEmpty) {
      charset = opt.charset;
    }
    if (opt.type.isNotEmpty) {
      type = opt.type;
    }
    if (opt.js.isNotEmpty) {
      _evalOptionJS(opt.js);
    }
    if (opt.retry != null) {
      retry = _intFromAny(opt.retry);
    }
    if (opt.webView != null) {
      useWebView = _truthyOption(opt.webView);
    }
    if (opt.webJs.isNotEmpty) {
      webJs = opt.webJs;
    }
    if (opt.serverID != null) {
      serverID = _stringifyOptionValue(opt.serverID);
    }
    if (opt.webViewDelayTime != null) {
      webViewDelay = _intFromAny(opt.webViewDelayTime);
    }
    if (opt.proxy.isNotEmpty) {
      proxy = opt.proxy;
    }
    for (final entry in opt.headers.entries) {
      if (entry.key.toLowerCase() == 'proxy') {
        proxy = entry.value;
      } else {
        headerMap[entry.key] = entry.value;
      }
    }
  }

  /// Handles Legado's `<val1,val2,...>` page syntax.
  String resolveAngleBracketPages(String urlStr) {
    final match = _angleBracketPagePattern.firstMatch(urlStr);
    if (match == null) return urlStr;
    final fullMatch = match.group(0)!;
    final pagesStr = match.group(1) ?? '';
    final pages = pagesStr.split(',');
    final idx = (page - 1).clamp(0, pages.length - 1);
    final replacement = pages.isNotEmpty ? pages[idx].trim() : '';

    var result = urlStr.replaceFirst(fullMatch, replacement);
    if (page > 0) {
      result = result.replaceAll(r'${page}', page.toString());
    }
    result = result.replaceAll(r'${key}', _encodedKey);
    return result;
  }

  /// Parses URL options and resolves relative URLs.
  String processUrl(String rawUrl) {
    var url = resolveAngleBracketPages(rawUrl);
    if (page > 0) {
      url = url.replaceAll(_pagePattern, page.toString());
    }
    url = url.replaceAll(_keyPattern, _encodedKey);
    if (page > 0) {
      url = url.replaceAll(r'${page}', page.toString());
    }
    url = url.replaceAll(r'${key}', _encodedKey);

    var urlOption = '';
    final commaIdx = findOptionSeparator(url);
    if (commaIdx != -1) {
      urlOption = url.substring(commaIdx + 1);
      url = url.substring(0, commaIdx);
    }
    var result = resolveURL(sourceUrl, url);
    finalUrl = result;
    if (urlOption.isNotEmpty) {
      parseUrlOption(urlOption);
      result = finalUrl;
    }
    return result;
  }

  /// Evaluates `{{expression}}` JS templates in [finalUrl].
  void resolveInlineExpressions() {
    final pool = _jsPool;
    if (pool == null || !finalUrl.contains('{{')) return;

    for (var i = 0; i < 5; i++) {
      final (:start, :end, :expr) = findTemplateExpr(finalUrl);
      if (expr.isEmpty || !_looksLikeJSExpression(expr)) break;

      final js = pool.acquire();
      var resultStr = '';
      try {
        _injectJSContext(js, '');
        try {
          final res = js.eval(expr);
          if (!res.isUndefined && !res.isNull) {
            resultStr = res.toString();
          }
        } catch (_) {}

        if (resultStr.isEmpty) {
          try {
            final gv = js.eval(
              'typeof result !== "undefined" && result !== null ? String(result) : ""',
            );
            if (!gv.isUndefined && !gv.isNull && gv.toString().isNotEmpty) {
              resultStr = gv.toString();
            }
          } catch (_) {}
        }
      } finally {
        pool.release(js);
      }

      finalUrl =
          finalUrl.substring(0, start) + resultStr + finalUrl.substring(end);
      finalUrl = finalUrl.replaceAll(_keyPattern, _encodedKey);
      finalUrl = finalUrl.replaceAll(_pagePattern, page.toString());
      if (page > 0) {
        finalUrl = finalUrl.replaceAll(r'${page}', page.toString());
      }
      finalUrl = finalUrl.replaceAll(r'${key}', _encodedKey);
    }

    finalUrl = finalUrl.trim();
    if (finalUrl.contains('{{')) return;
    finalUrl = processUrl(finalUrl);
  }

  void _resolveJS([JsPool? customPool]) {
    final pool = customPool ?? _jsPool;
    if (pool == null) return;
    final js = pool.acquire();
    try {
      _injectJSContext(js, '');
      var resultStr = '';
      try {
        final res = js.eval(jsCode);
        if (!res.isUndefined && !res.isNull) {
          resultStr = res.toString();
        }
      } catch (_) {
        return;
      }
      if (resultStr.isEmpty) {
        try {
          final rv = js.eval(
            'typeof result !== "undefined" && result !== null ? String(result) : ""',
          );
          if (!rv.isUndefined && !rv.isNull) {
            resultStr = rv.toString();
          }
        } catch (_) {}
      }
      if (resultStr.isEmpty) return;

      final commaIdx = findOptionSeparator(resultStr);
      if (commaIdx != -1) {
        final optStr = resultStr.substring(commaIdx + 1);
        resultStr = resultStr.substring(0, commaIdx);
        parseUrlOption(optStr);
      }
      if (resultStr.isNotEmpty) {
        finalUrl = resolveURL(sourceUrl, resultStr);
      }
    } finally {
      pool.release(js);
    }
  }

  void _injectJSContext(JSInterpreter js, String result) {
    injectLegadoStubs(js);
    var decodedKey = _encodedKey;
    try {
      decodedKey = Uri.decodeQueryComponent(_encodedKey);
    } catch (_) {}
    js.setGlobal('baseUrl', sourceUrl);
    js.setGlobal('key', decodedKey);
    js.setGlobal('page', page);
    js.setGlobal('result', result);
    js.setGlobal('src', result);
    final qUrl = quoteJS(sourceUrl);
    final qComment = quoteJS(sourceComment);
    js.eval(
      'source.key = $qUrl;'
      'source.bookSourceUrl = $qUrl;'
      'source.bookSourceComment = $qComment;'
      'source.getKey = function(){return $qUrl;};',
    );
  }

  void _evalOptionJS(String code) {
    final pool = _jsPool;
    if (pool == null || code.trim().isEmpty) return;
    final js = pool.acquire();
    try {
      _injectJSContext(js, finalUrl);
      final qFinal = quoteJS(finalUrl);
      js.eval(
        'var url = $qFinal;'
        'java.url = url;'
        'java._headers = {};'
        'java.headerMap = {put:function(k,v){java._headers[String(k)] = String(v);}};',
      );
      try {
        final res = js.eval(code);
        if (!res.isUndefined && !res.isNull && res.toString().isNotEmpty) {
          finalUrl = resolveURL(sourceUrl, res.toString());
        }
      } catch (_) {}

      try {
        final v = js.eval(
          'typeof url !== "undefined" && url !== null ? String(url) : ""',
        );
        if (!v.isUndefined && !v.isNull && v.toString().isNotEmpty) {
          finalUrl = resolveURL(sourceUrl, v.toString());
        }
      } catch (_) {}

      try {
        final hJson = js.eval('JSON.stringify(java._headers || {})');
        if (!hJson.isUndefined && !hJson.isNull) {
          final decoded = jsonDecode(hJson.toString());
          if (decoded is Map) {
            decoded.forEach((k, v) {
              headerMap[k.toString()] = v.toString();
            });
          }
        }
      } catch (_) {}
    } finally {
      pool.release(js);
    }
  }

  /// Sends the HTTP request using `package:http` (`IOClient`) and returns
  /// the response body decoded according to [charset] (or hex when [type] is set).
  Future<String> getStrResponse([JsPool? customPool]) async {
    if (jsCode.isNotEmpty) {
      await withSyncHttpBridge(() async {
        _resolveJS(customPool);
      });
    }
    if (finalUrl.trim().isEmpty) {
      throw StateError('empty final url after analyzing rule "$ruleUrl"');
    }

    final client = IOClient(_createHttpClient());
    try {
      final attempts = (retry + 1) < 1 ? 1 : (retry + 1);
      http.StreamedResponse? response;
      Object? lastError;

      for (var i = 0; i < attempts; i++) {
        try {
          final uri = Uri.parse(finalUrl);
          final req = http.Request(method, uri)
            ..followRedirects = true
            ..maxRedirects = 10;

          if (method == 'POST') {
            final reqBytes = encodedRequestBodyBytes();
            if (!headerMap.keys.any((k) => k.toLowerCase() == 'content-type') &&
                body.isNotEmpty) {
              if (_isJsonStr(body)) {
                req.headers['Content-Type'] = 'application/json';
              } else if (_isXmlStr(body)) {
                req.headers['Content-Type'] = 'application/xml';
              } else {
                req.headers['Content-Type'] =
                    'application/x-www-form-urlencoded';
              }
            }
            headerMap.forEach((k, v) => req.headers[k] = v);
            req.bodyBytes = reqBytes;
          } else {
            headerMap.forEach((k, v) => req.headers[k] = v);
          }

          final resp = await client
              .send(req)
              .timeout(const Duration(seconds: 30));
          if (resp.statusCode < 500 || i == attempts - 1) {
            response = resp;
            break;
          }
          await resp.stream.drain<void>();
        } catch (e) {
          lastError = e;
          if (i == attempts - 1) rethrow;
        }
      }

      if (response == null) {
        throw lastError ?? StateError('Request failed without response');
      }

      if (response.statusCode != HttpStatus.ok) {
        await response.stream.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase ?? ''}',
          uri: Uri.parse(finalUrl),
        );
      }

      final bytes = await response.stream.toBytes();

      if (type.isNotEmpty) {
        return _bytesToHex(bytes);
      }

      if (_isGbk(charset)) {
        try {
          return const GbkCodec(allowMalformed: true).decode(bytes);
        } catch (_) {}
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  HttpClient _createHttpClient() {
    final client = HttpClient()
      ..badCertificateCallback = ((_, _, _) => true)
      ..connectionTimeout = const Duration(seconds: 30);

    if (proxy.isNotEmpty) {
      var proxyUrl = proxy.trim();
      final schemeIdx = proxyUrl.indexOf('://');
      final lastAt = proxyUrl.lastIndexOf('@');
      if (schemeIdx >= 0 && lastAt > schemeIdx + 2) {
        proxyUrl = proxyUrl.substring(0, lastAt);
      }
      final uri = Uri.tryParse(proxyUrl);
      if (uri != null && uri.host.isNotEmpty) {
        final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
        client.findProxy = (_) => 'PROXY $hostPort';
      }
    }
    return client;
  }

  /// Returns the encoded POST request body string.
  String encodedRequestBody() {
    if (body.isEmpty) return '';
    final contentType = (headerMap['Content-Type'] ?? '').toLowerCase();
    if (_isJsonStr(body) ||
        _isXmlStr(body) ||
        (contentType.isNotEmpty &&
            !contentType.contains('x-www-form-urlencoded'))) {
      return _encodeWholeBody(body, charset);
    }
    return _encodeFormBody(body, charset);
  }

  /// Returns the exact bytes for the POST request body.
  List<int> encodedRequestBodyBytes() {
    if (body.isEmpty) return const [];
    final contentType = (headerMap['Content-Type'] ?? '').toLowerCase();
    if (_isJsonStr(body) ||
        _isXmlStr(body) ||
        (contentType.isNotEmpty &&
            !contentType.contains('x-www-form-urlencoded'))) {
      if (_isGbk(charset)) {
        try {
          return const GbkCodec(allowMalformed: true).encode(body);
        } catch (_) {}
      }
      return utf8.encode(body);
    }
    return utf8.encode(_encodeFormBody(body, charset));
  }

  /// Executes JavaScript on [responseBody] and returns the result.
  String executeJS(String code, String responseBody, [JsPool? customPool]) {
    final pool = customPool ?? _jsPool;
    if (pool == null) return responseBody;
    final js = pool.acquire();
    try {
      js.setGlobal('result', responseBody);
      js.setGlobal('baseUrl', finalUrl);
      js.setGlobal('src', responseBody);
      final res = js.eval(code);
      if (res.isUndefined || res.isNull) return '';
      return res.toString();
    } catch (_) {
      return responseBody;
    } finally {
      pool.release(js);
    }
  }
}

/// Finds the comma that separates a URL from its trailing JSON option.
int findOptionSeparator(String urlStr) {
  for (var i = 0; i < urlStr.length; i++) {
    if (urlStr[i] == ',') {
      final rest = urlStr.substring(i + 1).trim();
      if (rest.startsWith('{') || rest.startsWith('"')) {
        return i;
      }
    }
  }
  return -1;
}

/// Finds the first `{{...}}` expression in [s] using brace-depth counting.
({int start, int end, String expr}) findTemplateExpr(String s) {
  final start = s.indexOf('{{');
  if (start < 0) return (start: -1, end: -1, expr: '');
  var depth = 0;
  for (var i = start; i < s.length - 1; i++) {
    if (s[i] == '{' && s[i + 1] == '{') {
      depth++;
      i++;
      continue;
    }
    if (s[i] == '}' && s[i + 1] == '}') {
      depth--;
      if (depth == 0) {
        return (start: start, end: i + 2, expr: s.substring(start + 2, i));
      }
      i++;
    }
  }
  return (start: -1, end: -1, expr: '');
}

/// Converts single-quoted JSON-like strings to double-quoted JSON.
String singleToDoubleQuote(String s) {
  final b = StringBuffer();
  var inDouble = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '"') {
      inDouble = !inDouble;
      b.write(ch);
    } else if (ch == "'" && !inDouble) {
      b.write('"');
    } else {
      b.write(ch);
    }
  }
  return b.toString();
}

String normalizeJsonLike(String s) {
  final trimmed = s.trim();
  return trimmed.contains("'") ? singleToDoubleQuote(trimmed) : trimmed;
}

Map<String, String> parseStringMap(String raw, String baseUrl) {
  var trimmed = raw.trim();
  if (trimmed.isEmpty) return const {};
  trimmed = trimmed.replaceAll('{{baseUrl}}', baseUrl);
  var jsonStr = normalizeJsonLike(trimmed);
  if (!jsonStr.trim().startsWith('{')) {
    jsonStr = '{$jsonStr}';
  }
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) return const {};
    return decoded.map(
      (k, v) => MapEntry(k.toString(), _stringifyOptionValue(v)),
    );
  } catch (_) {
    return const {};
  }
}

String quoteJS(String s) {
  final b = StringBuffer("'");
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    switch (ch) {
      case r'\':
        b.write(r'\\');
      case "'":
        b.write(r"\'");
      case '\n':
        b.write(r'\n');
      case '\r':
        b.write(r'\r');
      case '\t':
        b.write(r'\t');
      default:
        b.write(ch);
    }
  }
  b.write("'");
  return b.toString();
}

/// Resolves a relative URL [ref] against [baseURL].
String resolveURL(String baseURL, String ref) {
  if (ref.isEmpty) return baseURL;
  if (ref.startsWith('http://') || ref.startsWith('https://')) {
    return ref;
  }
  final base = Uri.tryParse(baseURL);
  if (base == null) return ref;
  try {
    return base.resolve(ref).toString();
  } catch (_) {
    return ref;
  }
}

bool _looksLikeJSExpression(String expr) {
  final e = expr.trim();
  if (e.isEmpty) return false;
  if (e == 'key' || e == 'page') return true;
  const operators = '().+-*/?:=;[]{}"\'`';
  for (var i = 0; i < operators.length; i++) {
    if (e.contains(operators[i])) return true;
  }
  return e.contains('java') ||
      e.contains('source') ||
      e.contains('cookie') ||
      e.contains('cache');
}

String _stringifyOptionValue(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num) {
    return (v is int || v == v.toInt()) ? v.toInt().toString() : v.toString();
  }
  if (v is bool) return v ? 'true' : 'false';
  try {
    return jsonEncode(v);
  } catch (_) {
    return v.toString();
  }
}

int _intFromAny(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

bool _truthyOption(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is String) {
    final lower = v.trim().toLowerCase();
    return lower.isNotEmpty &&
        lower != 'false' &&
        lower != '0' &&
        lower != 'null';
  }
  return true;
}

String _encodeWholeBody(String body, String charset) {
  if (_isGbk(charset)) {
    try {
      final bytes = const GbkCodec(allowMalformed: true).encode(body);
      return latin1.decode(bytes);
    } catch (_) {}
  }
  return body;
}

String _encodeFormBody(String body, String charset) {
  return [
    for (final part in body.split('&'))
      if (part.indexOf('=') case final eq when eq == -1)
        _encodeFormComponent(part, charset)
      else
        '${_encodeFormComponent(part.substring(0, part.indexOf('=')), charset)}='
            '${_encodeFormComponent(part.substring(part.indexOf('=') + 1), charset)}',
  ].join('&');
}

String _encodeFormComponent(String s, String charset) {
  if (s.isEmpty || _alreadyEncoded(s)) return s;
  if (_isGbk(charset)) {
    try {
      final encoded = const GbkCodec(allowMalformed: true).encode(s);
      return _percentEncodeBytes(encoded);
    } catch (_) {}
  }
  return Uri.encodeQueryComponent(s);
}

String _percentEncodeBytes(List<int> bytes) {
  const hexChars = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final c in bytes) {
    if ((c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 45 ||
        c == 95 ||
        c == 46 ||
        c == 42) {
      out.writeCharCode(c);
    } else if (c == 32) {
      out.write('+');
    } else {
      out.write('%');
      out.write(hexChars[(c >> 4) & 0x0f]);
      out.write(hexChars[c & 0x0f]);
    }
  }
  return out.toString();
}

bool _alreadyEncoded(String s) {
  for (var i = 0; i < s.length - 2; i++) {
    if (s.codeUnitAt(i) == 37 &&
        _isHex(s.codeUnitAt(i + 1)) &&
        _isHex(s.codeUnitAt(i + 2))) {
      return true;
    }
  }
  return false;
}

bool _isHex(int b) =>
    (b >= 48 && b <= 57) || (b >= 97 && b <= 102) || (b >= 65 && b <= 70);

bool _isGbk(String charset) {
  final c = charset.trim().toLowerCase();
  return c == 'gbk' || c == 'gb2312' || c == 'gb18030';
}

bool _isJsonStr(String s) {
  final t = s.trim();
  return (t.startsWith('{') && t.endsWith('}')) ||
      (t.startsWith('[') && t.endsWith(']'));
}

bool _isXmlStr(String s) => s.contains('<?xml') || s.contains('<rss');

String _bytesToHex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
