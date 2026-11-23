/// Shared JSON coercion helpers for Legado models.
String jsonAsString(Object? value) => value == null ? '' : value.toString();

int jsonAsInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

bool jsonAsBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.trim().toLowerCase() == 'true';
  return false;
}

Map<String, dynamic>? jsonAsMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}
