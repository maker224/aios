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

// NOTE: these are app-lifetime singletons. Dependencies are read (not
// watched) inside the creators — watching would recreate the service
// (disposing the old one) every time a dependency notifies, which crashes
// any async work still running on the old instance.

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
    ref.read(settingsProvider),
    ref.read(peerStoreProvider),
    ref.read(activityProvider),
  );
});

/// The discovery service owned by the connection manager.
final discoveryProvider =
    ChangeNotifierProvider<DiscoveryService>((ref) {
  return ref.read(connectionManagerProvider).discovery;
});

final syncEngineProvider = ChangeNotifierProvider<SyncEngine>((ref) {
  final engine = SyncEngine(
    ref.read(connectionManagerProvider),
    ref.read(settingsProvider),
    ref.read(peerStoreProvider),
  );
  engine.attach();
  return engine;
});

final transferManagerProvider =
    ChangeNotifierProvider<TransferManager>((ref) {
  final t = TransferManager(
    ref.read(connectionManagerProvider),
    ref.read(settingsProvider),
    ref.read(activityProvider),
  );
  t.attach();
  return t;
});

final clipboardProvider =
    ChangeNotifierProvider<ClipboardSyncService>((ref) {
  final c = ClipboardSyncService(
    ref.read(syncEngineProvider),
    ref.read(settingsProvider),
    ref.read(activityProvider),
  );
  c.register();
  c.start();
  return c;
});

final contactSyncProvider =
    ChangeNotifierProvider<ContactSyncService>((ref) {
  final c = ContactSyncService(
    ref.read(syncEngineProvider),
    ref.read(settingsProvider),
    ref.read(activityProvider),
  );
  c.register();
  return c;
});

final calendarSyncProvider =
    ChangeNotifierProvider<CalendarSyncService>((ref) {
  final c = CalendarSyncService(
    ref.read(syncEngineProvider),
    ref.read(settingsProvider),
    ref.read(activityProvider),
  );
  c.register();
  return c;
});

final photoSyncProvider = ChangeNotifierProvider<PhotoSyncService>((ref) {
  return PhotoSyncService(
    ref.read(transferManagerProvider),
    ref.read(settingsProvider),
    ref.read(connectionManagerProvider),
  );
});
