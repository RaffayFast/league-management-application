import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:leaguehub/core/network/api_client.dart';
import 'package:leaguehub/core/storage/local_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fresh on-disk SQLite database per call (file-backed so reopen tests work).
Future<(LocalDb, String)> openTestDb([String? existingPath]) async {
  sqfliteFfiInit();
  final path = existingPath ?? p.join(Directory.systemTemp.createTempSync('leaguehub_test').path, 'test.db');
  final db = await LocalDb.open(factory: databaseFactoryFfi, path: path);
  return (db, path);
}

typedef Handler = Future<ResponseBody> Function(RequestOptions options);

/// Dio adapter that never touches the network.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Never connectionError(RequestOptions o) =>
    throw DioException(requestOptions: o, type: DioExceptionType.connectionError);

ApiClient testClient(FakeAdapter adapter, {void Function()? onUnauthorized, void Function(bool)? onReachability}) =>
    ApiClient(
      baseUrl: 'http://test.local',
      tokenProvider: () => 'token',
      adapter: adapter,
      onUnauthorized: onUnauthorized,
      onReachability: onReachability,
    );
