/// Defensive JSON readers. The backend contract is strict, but cached or
/// partially-populated payloads must never crash the UI.
typedef Json = Map<String, dynamic>;

Json asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> asList(dynamic v) => v is List ? v : const [];

String asString(dynamic v, [String fallback = '']) =>
    v is String ? v : (v == null ? fallback : v.toString());

String? asStringOrNull(dynamic v) => v is String ? v : null;

int asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return fallback;
}

int? asIntOrNull(dynamic v) => v is num ? v.toInt() : null;

double? asDoubleOrNull(dynamic v) => v is num ? v.toDouble() : null;

bool asBool(dynamic v, [bool fallback = false]) => v is bool ? v : fallback;

List<T> mapList<T>(dynamic v, T Function(Json) parse) => asList(v)
    .whereType<Map>()
    .map((e) => parse(Map<String, dynamic>.from(e)))
    .toList();

/// Thrown when the server answers with a shape the app cannot use.
class MalformedResponse implements Exception {
  MalformedResponse(this.message);
  final String message;
  @override
  String toString() => 'MalformedResponse: $message';
}

Json requireMap(dynamic v, String what) {
  if (v is Map) return Map<String, dynamic>.from(v);
  throw MalformedResponse('Expected an object for $what');
}
