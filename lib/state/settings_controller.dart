import 'package:aios/core/constants.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:flutter/foundation.dart';

/// User + device settings backed by the Hive settings box.
class SettingsController extends ChangeNotifier {
  // ---- Identity ----

  String get deviceId => AppStore.settings.get('deviceId') as String? ?? '';

  String get deviceName =>
      AppStore.settings.get('deviceName') as String? ?? 'My Device';

  set deviceName(String v) {
    AppStore.settings.put('deviceName', v.trim().isEmpty ? 'My Device' : v);
    notifyListeners();
  }

  // ---- Connectivity ----

  String get relayUrl =>
      AppStore.settings.get('relayUrl') as String? ?? K.defaultRelayUrl;

  set relayUrl(String v) {
    AppStore.settings.put('relayUrl', v.trim().isEmpty ? K.defaultRelayUrl : v);
    notifyListeners();
  }

  String get groupId =>
      AppStore.settings.get('groupId') as String? ?? K.defaultGroupId;

  set groupId(String v) {
    AppStore.settings.put('groupId', v.trim().isEmpty ? K.defaultGroupId : v);
    notifyListeners();
  }

  int get port => AppStore.settings.get('port') as int? ?? K.defaultPort;

  set port(int v) {
    final clamped = v.clamp(1024, 65535);
    AppStore.settings.put('port', clamped);
    notifyListeners();
  }

  // ---- Feature toggles ----

  bool _flag(String key, bool def) =>
      AppStore.settings.get(key) as bool? ?? def;

  void _setFlag(String key, bool value) {
    AppStore.settings.put(key, value);
    notifyListeners();
  }

  bool get syncContacts => _flag('syncContacts', true);
  set syncContacts(bool v) => _setFlag('syncContacts', v);

  bool get syncCalendars => _flag('syncCalendars', true);
  set syncCalendars(bool v) => _setFlag('syncCalendars', v);

  bool get clipboardSync => _flag('clipboardSync', true);
  set clipboardSync(bool v) => _setFlag('clipboardSync', v);

  bool get applyClipboard => _flag('applyClipboard', true);
  set applyClipboard(bool v) => _setFlag('applyClipboard', v);

  bool get receiveFiles => _flag('receiveFiles', true);
  set receiveFiles(bool v) => _setFlag('receiveFiles', v);

  bool get photoAutoSync => _flag('photoAutoSync', false);
  set photoAutoSync(bool v) => _setFlag('photoAutoSync', v);

  /// Master switch for file & photo sync.
  bool get syncFiles => _flag('syncFiles', true);
  set syncFiles(bool v) => _setFlag('syncFiles', v);

  /// Master switch for notes sync.
  bool get syncNotes => _flag('syncNotes', true);
  set syncNotes(bool v) => _setFlag('syncNotes', v);

  /// Whether the cloud relay is used (in addition to local Wi-Fi).
  bool get useRelay => _flag('useRelay', true);
  set useRelay(bool v) => _setFlag('useRelay', v);

  /// True once the user completed the first-run onboarding wizard.
  bool get onboardingDone => _flag('onboardingDone', false);
  set onboardingDone(bool v) => _setFlag('onboardingDone', v);

  List<String> get photoAutoPeers =>
      (AppStore.settings.get('photoAutoPeers') as List?)?.cast<String>() ??
      const [];

  void togglePhotoPeer(String peerId) {
    final list = List<String>.from(photoAutoPeers);
    if (list.contains(peerId)) {
      list.remove(peerId);
    } else {
      list.add(peerId);
    }
    AppStore.settings.put('photoAutoPeers', list);
    notifyListeners();
  }

  // ---- Last sync timestamps ----

  int lastSyncOf(String key) => AppStore.settings.get('lastSync_$key') as int? ?? 0;

  void setLastSync(String key, DateTime t) {
    AppStore.settings.put('lastSync_$key', t.millisecondsSinceEpoch);
    notifyListeners();
  }
}
