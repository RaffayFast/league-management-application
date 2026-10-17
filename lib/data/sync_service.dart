import 'dart:convert';
import 'package:dio/dio.dart';
import 'local_db.dart';

class SyncService {
  final Dio dio;
  final String baseUrl; // e.g., "http://192.168.56.253:8080"

  SyncService({required this.dio, required this.baseUrl});

  Future<Map<String, dynamic>> syncPendingActions(String deviceId) async {
    final pending = await LocalDatabase.getPendingActions();
    if (pending.isEmpty) return {'status': 'empty'};

    // Build contract-compliant payload
    final actionsPayload = pending.map((row) {
      return {
        'action_id': row['action_id'],
        'type': row['type'],
        'queued_at': row['queued_at'],
        'base_version': row['base_version'],
        'payload': jsonDecode(row['payload_json'] as String),
      };
    }).toList();

    final body = {
      'device_id': deviceId,
      'actions': actionsPayload,
    };

    try {
      final response = await dio.post('$baseUrl/api/v1/sync', data: body);
      final results = response.data['results'] as List<dynamic>;

      // Process per-action feedback
      for (var res in results) {
        final actionId = res['action_id'] as String;
        final status = res['status'] as String; // 'applied', 'rejected', or 'duplicate'
        await LocalDatabase.markActionSynced(actionId, status, res as Map<String, dynamic>);
      }

      return response.data as Map<String, dynamic>;
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }
}