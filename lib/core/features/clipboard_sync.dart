import 'dart:async';

import 'package:aios/core/activity.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/sync/sync_engine.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

/// Watches the local clipboard and shares new text with paired devices;
/// applies incoming clipboard records locally.
class ClipboardSyncService extends ChangeNotifier {
  ClipboardSyncService(this.engine, this.settings, this.activity);

  final SyncEngine engine;
  final SettingsController settings;
  final ActivityLog activity;

  Timer? _timer;
  String? _lastText;
  bool _applyingRemote = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<SyncRecord> get history => engine.recordsOf(DataType.clipboard);

  void register() {
    engine.registerApply(DataType.clipboard, _onRemote);
  }

  void start() {
    _timer ??= Timer.periodic(
        const Duration(milliseconds: 1500), (_) => tick());
  }

  Future<void> tick() async {
    if (_applyingRemote || !settings.clipboardSync) return;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null || text.isEmpty || text == _lastText) return;
      _lastText = text;
      await engine.putLocal(
          DataType.clipboard, const Uuid().v4(), {'text': text});
      engine.prune(DataType.clipboard, keep: 300);
    } catch (_) {
      // Clipboard access can fail while the app is backgrounded.
    }
  }

  void _onRemote(SyncRecord r) async {
    if (r.deleted || !settings.applyClipboard) return;
    final text = r.data['text'] as String?;
    if (text == null || text == _lastText) return;
    _applyingRemote = true;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _lastText = text;
      final preview = text.length > 60 ? '${text.substring(0, 60)}…' : text;
      activity.add('📋', 'Clipboard received', preview);
      _notify();
    } catch (_) {
    } finally {
      _applyingRemote = false;
    }
  }

  Future<void> copyToClipboard(String text) async {
    _applyingRemote = true;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _lastText = text;
    } catch (_) {
    } finally {
      _applyingRemote = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
