import 'dart:async';

import 'package:aios/core/constants.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/net/connection_manager.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:flutter/foundation.dart';

/// Synchronizes versioned records between paired devices.
///
/// Model: every synced item (note, clipboard entry, contact, calendar event)
/// is a [SyncRecord] with a last-write-wins timestamp. Each peer keeps a
/// per-peer outbox of record keys it still needs to deliver. When a record
/// arrives from one peer, it is merged locally and re-queued for every
/// *other* peer, so changes propagate across the whole mesh.
class SyncEngine extends ChangeNotifier {
  SyncEngine(this.manager, this.settings, this.peerStore);

  final ConnectionManager manager;
  final SettingsController settings;
  final PeerStore peerStore;

  /// type name -> apply function, invoked when a *newer* remote record
  /// arrives (and the local device is not the origin).
  final Map<String, void Function(SyncRecord)> applyHandlers = {};
  final Map<String, bool> _syncing = {};

  static const int batchSize = 100;

  void registerApply(DataType type, void Function(SyncRecord) fn) {
    applyHandlers[type.name] = fn;
  }

  /// Whether the user enabled syncing for this data type (Options).
  bool isEnabled(DataType type) => switch (type) {
        DataType.contact => settings.syncContacts,
        DataType.calendar => settings.syncCalendars,
        DataType.clipboard => settings.clipboardSync,
        DataType.note => settings.syncNotes,
      };

  void attach() {
    manager.on(K.msgRecords, _onRecords);
    manager.on(K.msgAcks, _onAcks);
    manager.on(K.msgRecordsDone, (_, __) {});
    manager.onPeerReady = (peerId) => unawaited(beginSync(peerId));
  }

  // ---------------------------------------------------------------------
  // Record store
  // ---------------------------------------------------------------------

  SyncRecord? getByKey(String key) {
    final raw = AppStore.records.get(key) as Map?;
    if (raw == null) return null;
    return SyncRecord.fromJson(raw.cast<dynamic, dynamic>());
  }

  List<SyncRecord> recordsOf(DataType type) {
    final out = <SyncRecord>[];
    for (final raw in AppStore.records.values) {
      final r = SyncRecord.fromJson((raw as Map).cast<dynamic, dynamic>());
      if (r.type == type && !r.deleted) out.add(r);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  int recordCount(DataType type) => recordsOf(type).length;

  // ---------------------------------------------------------------------
  // Local mutations
  // ---------------------------------------------------------------------

  Future<SyncRecord> putLocal(
      DataType type, String id, Map<String, dynamic> data) async {
    final record = SyncRecord(
      id: id,
      type: type,
      deviceId: settings.deviceId,
      updatedAt: DateTime.now(),
      deleted: false,
      data: data,
    );
    await _store(record);
    if (isEnabled(type)) {
      _enqueueToOthers(record.key, origin: settings.deviceId);
      await _pushLive(record);
    }
    notifyListeners();
    return record;
  }

  Future<void> updateLocal(DataType type, String id,
      Map<String, dynamic> Function(Map<String, dynamic>) mutate) async {
    final existing = getByKey('${type.name}:$id');
    final data = mutate(existing?.data ?? {});
    await putLocal(type, id, data);
  }

  Future<void> deleteLocal(DataType type, String id) async {
    final existing = getByKey('${type.name}:$id');
    final record = SyncRecord(
      id: id,
      type: type,
      deviceId: settings.deviceId,
      updatedAt: DateTime.now(),
      deleted: true,
      data: existing?.data ?? {},
    );
    await _store(record);
    if (isEnabled(type)) {
      _enqueueToOthers(record.key, origin: settings.deviceId);
      await _pushLive(record);
    }
    notifyListeners();
  }

  Future<void> _store(SyncRecord r) =>
      AppStore.records.put(r.key, r.toJson());

  // ---------------------------------------------------------------------
  // Outbox
  // ---------------------------------------------------------------------

  List<String> _outboxFor(String peerId) {
    final raw = AppStore.outbox.get(peerId) as List?;
    return raw?.cast<String>() ?? [];
  }

  void _saveOutbox(String peerId, List<String> keys) {
    AppStore.outbox.put(peerId, keys);
  }

  void _enqueueToOthers(String key, {required String origin}) {
    for (final p in peerStore.all) {
      if (p.id == origin) continue;
      final list = _outboxFor(p.id);
      if (!list.contains(key)) {
        list.add(key);
        _saveOutbox(p.id, list);
      }
    }
  }

  Future<void> _pushLive(SyncRecord r) async {
    for (final p in peerStore.all) {
      if (!manager.reachable(p.id)) continue;
      final sent = await manager.send(p.id, K.msgRecords, {
        'r': [r.toJson()],
      });
      if (!sent) continue;
      // Keep it in the outbox too; acks will remove it. If the peer is
      // offline or the message is lost, the next session resends it.
    }
  }

  // ---------------------------------------------------------------------
  // Session sync
  // ---------------------------------------------------------------------

  Future<void> beginSync(String peerId) async {
    if (peerStore.byId(peerId) == null) return;
    if (_syncing[peerId] ?? false) return;
    if (!manager.reachable(peerId)) return;
    _syncing[peerId] = true;
    try {
      await _sendPending(peerId);
    } finally {
      _syncing[peerId] = false;
    }
  }

  Future<void> flushAll() async {
    for (final p in peerStore.all) {
      if (manager.reachable(p.id)) {
        unawaited(beginSync(p.id));
      }
    }
  }

  Future<void> _sendPending(String peerId) async {
    if (!manager.reachable(peerId)) return;
    final pending = _outboxFor(peerId);
    if (pending.isEmpty) {
      await manager.send(peerId, K.msgRecordsDone, {});
      return;
    }
    final batch = <Map<String, dynamic>>[];
    for (final key in pending.take(batchSize)) {
      final r = getByKey(key);
      if (r != null && isEnabled(r.type)) batch.add(r.toJson());
    }
    if (batch.isEmpty) {
      _saveOutbox(peerId, pending);
      await manager.send(peerId, K.msgRecordsDone, {});
      return;
    }
    await manager.send(peerId, K.msgRecords, {'r': batch});
  }

  // ---------------------------------------------------------------------
  // Inbound
  // ---------------------------------------------------------------------

  Future<void> _onRecords(
      Map<String, dynamic> payload, String from) async {
    final list = (payload['r'] as List?) ?? const [];
    final receivedKeys = <String>[];
    var applied = 0;

    for (final item in list) {
      if (item is! Map) continue;
      final incoming = SyncRecord.fromJson(item.cast<dynamic, dynamic>());
      receivedKeys.add(incoming.key);
      final local = getByKey(incoming.key);

      final newer = local == null ||
          incoming.updatedAt.isAfter(local.updatedAt) ||
          (incoming.updatedAt.isAtSameMomentAs(local.updatedAt) &&
              incoming.deviceId.compareTo(local.deviceId) > 0);
      if (!newer) continue;
      // Ignore records of data types the user disabled in Options.
      if (!isEnabled(incoming.type)) continue;

      await _store(incoming);
      _enqueueToOthers(incoming.key, origin: from);
      if (!incoming.deleted) {
        applyHandlers[incoming.type.name]?.call(incoming);
        applied++;
      }
    }

    await manager.send(from, K.msgAcks, {'keys': receivedKeys});
    if (applied > 0) notifyListeners();

    // Send anything we have pending for this peer in return.
    unawaited(_sendPending(from));
  }

  Future<void> _onAcks(Map<String, dynamic> payload, String from) async {
    final keys = ((payload['keys'] as List?) ?? const []).cast<String>();
    final list = _outboxFor(from);
    list.removeWhere(keys.contains);
    _saveOutbox(from, list);
    unawaited(_sendPending(from));
  }

  // ---------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------

  /// Deletes old clipboard records (keeps the store small).
  void prune(DataType type, {int keep = 200}) {
    final all = recordsOf(type);
    if (all.length <= keep) return;
    for (final r in all.skip(keep)) {
      unawaited(deleteLocal(type, r.id));
    }
  }
}
