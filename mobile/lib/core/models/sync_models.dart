import 'json.dart';

/// One per-action result of POST /api/v1/sync (A12).
class SyncResult {
  const SyncResult({
    required this.actionId,
    required this.status,
    required this.resolution,
    this.errorCode,
    required this.processedOrder,
    this.serverVersion,
    this.signature,
  });

  final String actionId;
  final String status; // applied | rejected | duplicate
  final String
      resolution; // appended | rebased_append | server_wins | skipped_duplicate
  final String? errorCode;
  final int processedOrder;
  final int? serverVersion;
  final String? signature;

  bool get isApplied => status == 'applied';
  bool get isDuplicate => status == 'duplicate';
  bool get isRejected => status == 'rejected';

  factory SyncResult.fromJson(Json j) => SyncResult(
        actionId: asString(j['action_id']),
        status: asString(j['status']),
        resolution: asString(j['resolution']),
        errorCode: asStringOrNull(j['error_code']),
        processedOrder: asInt(j['processed_order']),
        serverVersion: asIntOrNull(j['server_version']),
        signature: asStringOrNull(j['signature']),
      );
}

class SyncResponse {
  const SyncResponse({required this.deviceId, required this.results});
  final String deviceId;
  final List<SyncResult> results;

  factory SyncResponse.fromJson(Json j) {
    if (j['results'] is! List) {
      throw MalformedResponse('sync response without results');
    }
    return SyncResponse(
      deviceId: asString(j['device_id']),
      results: mapList(j['results'], SyncResult.fromJson),
    );
  }
}
