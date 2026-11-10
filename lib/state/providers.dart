import 'package:aios/core/activity.dart';
import 'package:aios/core/features/calendar_sync.dart';
import 'package:aios/core/features/clipboard_sync.dart';
import 'package:aios/core/features/contact_sync.dart';
import 'package:aios/core/features/photo_sync.dart';
import 'package:aios/core/net/connection_manager.dart';
import 'package:aios/core/net/discovery.dart';
import 'package:aios/core/sync/sync_engine.dart';
import 'package:aios/core/transfers/transfer_manager.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final settingsProvider =
    ChangeNotifierProvider<SettingsController>((ref) => SettingsController());

final activityProvider = ChangeNotifierProvider<ActivityLog>((ref) {
  final a = ActivityLog();
  a.load();
  return a;
});

final peerStoreProvider = ChangeNotifierProvider<PeerStore>((ref) {
  final p = PeerStore();
  p.load();
  return p;
});

final connectionManagerProvider =
    ChangeNotifierProvider<ConnectionManager>((ref) {
  return ConnectionManager(
    ref.watch(settingsProvider),
    ref.watch(peerStoreProvider),
    ref.watch(activityProvider),
  );
});

/// The discovery service owned by the connection manager.
final discoveryProvider =
    ChangeNotifierProvider<DiscoveryService>((ref) {
  return ref.watch(connectionManagerProvider).discovery;
});

final syncEngineProvider = ChangeNotifierProvider<SyncEngine>((ref) {
  final engine = SyncEngine(
    ref.watch(connectionManagerProvider),
    ref.watch(settingsProvider),
    ref.watch(peerStoreProvider),
  );
  engine.attach();
  return engine;
});

final transferManagerProvider =
    ChangeNotifierProvider<TransferManager>((ref) {
  final t = TransferManager(
    ref.watch(connectionManagerProvider),
    ref.watch(settingsProvider),
    ref.watch(activityProvider),
  );
  t.attach();
  return t;
});

final clipboardProvider =
    ChangeNotifierProvider<ClipboardSyncService>((ref) {
  final c = ClipboardSyncService(
    ref.watch(syncEngineProvider),
    ref.watch(settingsProvider),
    ref.watch(activityProvider),
  );
  c.register();
  c.start();
  return c;
});

final contactSyncProvider =
    ChangeNotifierProvider<ContactSyncService>((ref) {
  final c = ContactSyncService(
    ref.watch(syncEngineProvider),
    ref.watch(settingsProvider),
    ref.watch(activityProvider),
  );
  c.register();
  return c;
});

final calendarSyncProvider =
    ChangeNotifierProvider<CalendarSyncService>((ref) {
  final c = CalendarSyncService(
    ref.watch(syncEngineProvider),
    ref.watch(settingsProvider),
    ref.watch(activityProvider),
  );
  c.register();
  return c;
});

final photoSyncProvider = ChangeNotifierProvider<PhotoSyncService>((ref) {
  return PhotoSyncService(
    ref.watch(transferManagerProvider),
    ref.watch(settingsProvider),
    ref.watch(connectionManagerProvider),
  );
});
