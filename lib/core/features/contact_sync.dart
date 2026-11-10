import 'dart:convert';
import 'dart:io';

import 'package:aios/core/activity.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/core/sync/sync_engine.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:uuid/uuid.dart';

/// Two-way contact sync via the platform contact store.
///
/// Supported on Android, iOS and macOS. Not available on Windows
/// (flutter_contacts has no Windows implementation yet).
class ContactSyncService extends ChangeNotifier {
  ContactSyncService(this.engine, this.settings, this.activity);

  final SyncEngine engine;
  final SettingsController settings;
  final ActivityLog activity;

  bool available = !Platform.isWindows;
  bool permissionGranted = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get enabled => settings.syncContacts;
  int get syncedCount => engine.recordCount(DataType.contact);
  DateTime? get lastSync {
    final ts = settings.lastSyncOf('contacts');
    return ts == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ts);
  }

  void register() {
    engine.registerApply(DataType.contact, _onRemote);
  }

  Future<bool> ensurePermission() async {
    try {
      final granted = await FlutterContacts.requestPermission();
      permissionGranted = granted;
      return granted;
    } catch (e) {
      debugPrint('contacts: permission error: $e');
      available = false;
      permissionGranted = false;
      _notify();
      return false;
    }
  }

  /// Pulls the platform contact store, diffs it against the last snapshot
  /// and turns the changes into sync records.
  Future<void> syncNow() async {
    if (!available) return;
    if (!await ensurePermission()) {
      activity.add('⚠️', 'Contact permission denied');
      _notify();
      return;
    }
    try {
      final contacts =
          await FlutterContacts.getContacts(withProperties: true);

      final pidMap = _map('contact_pid'); // platformId -> recordId
      final ridMap = _map('contact_rid'); // recordId -> platformId
      final hashes = _map('contact_hashes'); // platformId -> content hash

      final seen = <String>{};
      for (final c in contacts) {
        final pid = c.id;
        if (pid.isEmpty) continue;
        seen.add(pid);
        final data = contactToJson(c);
        final h = hashOf(data);
        final existing = pidMap[pid];
        if (existing == null) {
          final rid = const Uuid().v4();
          await engine.putLocal(DataType.contact, rid, data);
          pidMap[pid] = rid;
          ridMap[rid] = pid;
          hashes[pid] = h;
        } else if (hashes[pid] != h) {
          await engine.putLocal(DataType.contact, existing, data);
          hashes[pid] = h;
        }
      }

      // Deletions: platform ids that disappeared from the store.
      for (final pid in hashes.keys.toList()) {
        if (seen.contains(pid)) continue;
        final rid = pidMap[pid];
        if (rid != null) {
          await engine.deleteLocal(DataType.contact, rid);
        }
        pidMap.remove(pid);
        ridMap.remove(rid);
        hashes.remove(pid);
      }

      _saveMaps(pidMap, ridMap, hashes);
      settings.setLastSync('contacts', DateTime.now());
      activity.add('👥', 'Contacts synced', '${contacts.length} on device');
      _notify();
    } catch (e) {
      available = false;
      activity.add('⚠️', 'Contact sync failed', '$e');
      _notify();
    }
  }

  // ---------------------------------------------------------------------
  // Remote -> local
  // ---------------------------------------------------------------------

  void _onRemote(SyncRecord r) {
    if (!enabled || !available) return;
    if (r.deleted) {
      _applyDelete(r);
    } else {
      _applyUpsert(r);
    }
  }

  Future<void> _applyUpsert(SyncRecord r) async {
    try {
      final data = r.data;
      final ridMap = _map('contact_rid');
      final pidMap = _map('contact_pid');
      final hashes = _map('contact_hashes');

      final existingId = ridMap[r.id];
      final phones = (data['phones'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Phone(
                '${m['n'] ?? ''}',
                label: _phoneLabel(m['l'] as String?),
              ))
          .where((p) => p.number.isNotEmpty)
          .toList();
      final emails = (data['emails'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Email(
                '${m['a'] ?? ''}',
                label: _emailLabel(m['l'] as String?),
              ))
          .where((e) => e.address.isNotEmpty)
          .toList();
      final org = data['org'] as String?;
      final notesText = data['notes'] as String?;
      final birthday = DateTime.tryParse(data['birthday'] as String? ?? '');

      final contact = Contact(
        id: existingId ?? '',
        name: Name(
          first: data['first'] as String? ?? '',
          last: data['last'] as String? ?? '',
        ),
        phones: phones,
        emails: emails,
        organizations: (org == null || org.isEmpty)
            ? []
            : [Organization(company: org)],
        events: birthday == null
            ? []
            : [
                Event(
                    year: birthday.year,
                    month: birthday.month,
                    day: birthday.day)
              ],
        notes: (notesText == null || notesText.isEmpty)
            ? []
            : [Note(notesText)],
      );

      if (existingId != null) {
        await contact.update();
      } else {
        await contact.insert();
      }
      final newId = contact.id;
      if (newId.isNotEmpty) {
        ridMap[r.id] = newId;
        pidMap[newId] = r.id;
        hashes[newId] = hashOf(data);
        _saveMaps(pidMap, ridMap, hashes);
      }
      _notify();
    } catch (e) {
      debugPrint('contacts: apply failed: $e');
      activity.add('⚠️', 'Could not write contact to device', '$e');
    }
  }

  Future<void> _applyDelete(SyncRecord r) async {
    try {
      final ridMap = _map('contact_rid');
      final pidMap = _map('contact_pid');
      final hashes = _map('contact_hashes');
      final pid = ridMap[r.id];
      if (pid != null) {
        await Contact(id: pid).delete();
        ridMap.remove(r.id);
        pidMap.remove(pid);
        hashes.remove(pid);
        _saveMaps(pidMap, ridMap, hashes);
      }
      _notify();
    } catch (e) {
      debugPrint('contacts: delete failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  Map<String, String> _map(String key) {
    final raw = AppStore.snapshots.get(key) as Map?;
    return raw?.map((k, v) => MapEntry('$k', '$v')) ?? {};
  }

  void _saveMaps(Map<String, String> pid, Map<String, String> rid,
      Map<String, String> hashes) {
    AppStore.snapshots.put('contact_pid', pid);
    AppStore.snapshots.put('contact_rid', rid);
    AppStore.snapshots.put('contact_hashes', hashes);
  }

  static Map<String, dynamic> contactToJson(Contact c) => {
        'first': c.name.first,
        'last': c.name.last,
        'phones': [
          for (final p in c.phones) {'n': p.number, 'l': p.label.name}
        ],
        'emails': [
          for (final e in c.emails) {'a': e.address, 'l': e.label.name}
        ],
        'org': c.organizations.isNotEmpty ? c.organizations.first.company : '',
        'birthday': _birthdayOf(c)?.toIso8601String() ?? '',
        'notes': [for (final n in c.notes) n.note].join('\n'),
      };

  static DateTime? _birthdayOf(Contact c) {
    for (final e in c.events) {
      if (e.label == EventLabel.birthday) {
        return DateTime(e.year ?? 2000, e.month, e.day);
      }
    }
    return null;
  }

  static String hashOf(Map<String, dynamic> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();

  static PhoneLabel _phoneLabel(String? s) => s == null
      ? PhoneLabel.mobile
      : PhoneLabel.values.firstWhere((e) => e.name == s,
          orElse: () => PhoneLabel.mobile);

  static EmailLabel _emailLabel(String? s) => s == null
      ? EmailLabel.home
      : EmailLabel.values.firstWhere((e) => e.name == s,
          orElse: () => EmailLabel.home);
}
