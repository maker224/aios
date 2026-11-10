import 'package:aios/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SyncRecord survives a JSON roundtrip', () {
    final record = SyncRecord(
      id: 'abc',
      type: DataType.note,
      deviceId: 'device-1',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1234567890),
      deleted: false,
      data: const {'title': 'hello', 'text': 'world'},
    );
    final copy =
        SyncRecord.fromJson(record.toJson().cast<dynamic, dynamic>());
    expect(copy.id, 'abc');
    expect(copy.type, DataType.note);
    expect(copy.deviceId, 'device-1');
    expect(copy.updatedAt.millisecondsSinceEpoch, 1234567890);
    expect(copy.deleted, false);
    expect(copy.data['title'], 'hello');
    expect(copy.key, 'note:abc');
  });

  test('platform strings roundtrip', () {
    expect(platformFromString('windows'), PeerPlatform.windows);
    expect(platformToString(PeerPlatform.ios), 'ios');
  });
}
