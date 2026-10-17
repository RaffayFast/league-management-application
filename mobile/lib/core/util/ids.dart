import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Contract-safe ids: 1-64 chars of `A-Za-z0-9_.:-` (prefix + uuid v4 = 40 chars).
String newId(String prefix) => '$prefix-${_uuid.v4()}';

final _idPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

bool isValidContractId(String id) => _idPattern.hasMatch(id);
