import 'dart:io';
import 'dart:typed_data';

import 'package:aios/core/constants.dart';
import 'package:aios/core/crypto/keys.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Central storage: Hive boxes + app directories.
///
/// Initialized once from `main()` before `runApp`.
class AppStore {
  AppStore._();

  static late Directory dataDir;
  static late Directory syncedDir;

  static late Box settings;
  static late Box peers;
  static late Box records;
  static late Box outbox;
  static late Box snapshots;
  static late Box activityBox;

  static Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    dataDir = Directory('${base.path}${Platform.pathSeparator}aios');
    dataDir.createSync(recursive: true);

    syncedDir =
        Directory('${dataDir.path}${Platform.pathSeparator}${K.syncedFolderName}');
    syncedDir.createSync(recursive: true);

    Hive.init(dataDir.path);
    settings = await Hive.openBox('settings');
    peers = await Hive.openBox('peers');
    records = await Hive.openBox('records');
    outbox = await Hive.openBox('outbox');
    snapshots = await Hive.openBox('snapshots');
    activityBox = await Hive.openBox('activity');

    await _ensureIdentity();
  }

  static Future<void> _ensureIdentity() async {
    if (settings.get('deviceId') == null) {
      await settings.put('deviceId', const Uuid().v4());
    }
    final pub = settings.get('pubKey');
    final priv = settings.get('privKey');
    if (pub == null || priv == null) {
      final (p, s) = await CryptoKeys.generate();
      await settings.put('pubKey', p);
      await settings.put('privKey', s);
      CryptoKeys.init(p, s);
    } else {
      CryptoKeys.init(
        Uint8List.fromList((pub as List).cast<int>()),
        Uint8List.fromList((priv as List).cast<int>()),
      );
    }
  }
}
