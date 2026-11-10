import 'dart:convert';
import 'dart:io';

import 'package:aios/core/activity.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/core/sync/sync_engine.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

/// Two-way calendar sync via the platform calendar store.
///
/// Supported on Android and iOS only (device_calendar limitation).
/// Events are kept in a dedicated "AIoS Synced" calendar on each device.
class CalendarSyncService extends ChangeNotifier {
  CalendarSyncService(this.engine, this.settings, this.activity);

  final SyncEngine engine;
  final SettingsController settings;
  final ActivityLog activity;

  static const String calendarName = 'AIoS Synced';

  final DeviceCalendarPlugin _plugin = DeviceCalendarPlugin();
  String? _calendarId;
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

  bool get available => Platform.isAndroid || Platform.isIOS;
  bool get enabled => settings.syncCalendars;
  int get syncedCount => engine.recordCount(DataType.calendar);
  DateTime? get lastSync {
    final ts = settings.lastSyncOf('calendars');
    return ts == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ts);
  }

  void register() {
    engine.registerApply(DataType.calendar, _onRemote);
  }

  Future<bool> ensurePermission() async {
    try {
      final res = await _plugin.requestPermissions();
      permissionGranted = res.isSuccess;
      return permissionGranted;
    } catch (e) {
      debugPrint('calendar: permission error: $e');
      return false;
    }
  }

  Future<String?> _ensureCalendar() async {
    if (_calendarId != null) return _calendarId;
    final res = await _plugin.retrieveCalendars();
    final calendars = res.data ?? const <Calendar>[];
    for (final c in calendars) {
      if (c.name == calendarName && !(c.isReadOnly ?? false)) {
        _calendarId = c.id;
        return _calendarId;
      }
    }
    try {
      final created = await _plugin.createCalendar(
        calendarName,
        calendarColor: const Color(0xFF4F6DF5),
      );
      if (created.isSuccess && created.data != null) {
        _calendarId = created.data;
      }
    } catch (e) {
      debugPrint('calendar: create failed: $e');
    }
    return _calendarId;
  }

  Future<void> syncNow() async {
    if (!available) return;
    if (!await ensurePermission()) {
      activity.add('⚠️', 'Calendar permission denied');
      _notify();
      return;
    }
    try {
      final calId = await _ensureCalendar();
      if (calId == null) {
        activity.add('⚠️', 'Could not create AIoS calendar');
        _notify();
        return;
      }
      final now = tz.TZDateTime.now(tz.local);
      final res = await _plugin.retrieveEvents(
        calId,
        RetrieveEventsParams(
          startDate: now.subtract(const Duration(days: 30)),
          endDate: now.add(const Duration(days: 366)),
        ),
      );
      final events = res.data ?? const <Event>[];

      final pidMap = _map('cal_pid');
      final ridMap = _map('cal_rid');
      final hashes = _map('cal_hashes');

      final seen = <String>{};
      for (final e in events) {
        final pid = e.eventId ?? '';
        if (pid.isEmpty) continue;
        seen.add(pid);
        final data = eventToJson(e);
        final h = hashOf(data);
        final existing = pidMap[pid];
        if (existing == null) {
          final rid = const Uuid().v4();
          await engine.putLocal(DataType.calendar, rid, data);
          pidMap[pid] = rid;
          ridMap[rid] = pid;
          hashes[pid] = h;
        } else if (hashes[pid] != h) {
          await engine.putLocal(DataType.calendar, existing, data);
          hashes[pid] = h;
        }
      }

      for (final pid in hashes.keys.toList()) {
        if (seen.contains(pid)) continue;
        final rid = pidMap[pid];
        if (rid != null) {
          await engine.deleteLocal(DataType.calendar, rid);
        }
        pidMap.remove(pid);
        ridMap.remove(rid);
        hashes.remove(pid);
      }

      _saveMaps(pidMap, ridMap, hashes);
      settings.setLastSync('calendars', DateTime.now());
      activity.add('📅', 'Calendar synced', '${events.length} events');
      _notify();
    } catch (e) {
      activity.add('⚠️', 'Calendar sync failed', '$e');
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
      final calId = await _ensureCalendar();
      if (calId == null) return;
      final data = r.data;
      final ridMap = _map('cal_rid');
      final pidMap = _map('cal_pid');
      final hashes = _map('cal_hashes');

      final start = DateTime.tryParse(data['start'] as String? ?? '') ??
          DateTime.now();
      final end = DateTime.tryParse(data['end'] as String? ?? '') ??
          start.add(const Duration(hours: 1));

      final event = Event(
        calId,
        eventId: ridMap[r.id],
        title: data['title'] as String? ?? 'Untitled',
        description: data['description'] as String?,
        location: data['location'] as String?,
        start: tz.TZDateTime.from(start, tz.local),
        end: tz.TZDateTime.from(end, tz.local),
        allDay: data['allDay'] as bool? ?? false,
      );

      final res = await _plugin.createOrUpdateEvent(event);
      if (res != null && res.isSuccess && res.data != null) {
        final pid = res.data!;
        ridMap[r.id] = pid;
        pidMap[pid] = r.id;
        hashes[pid] = hashOf(data);
        _saveMaps(pidMap, ridMap, hashes);
      }
      _notify();
    } catch (e) {
      debugPrint('calendar: apply failed: $e');
      activity.add('⚠️', 'Could not write event to device', '$e');
    }
  }

  Future<void> _applyDelete(SyncRecord r) async {
    try {
      final calId = await _ensureCalendar();
      if (calId == null) return;
      final ridMap = _map('cal_rid');
      final pidMap = _map('cal_pid');
      final hashes = _map('cal_hashes');
      final pid = ridMap[r.id];
      if (pid != null) {
        final res = await _plugin.deleteEvent(calId, pid);
        if (res.isSuccess) {
          ridMap.remove(r.id);
          pidMap.remove(pid);
          hashes.remove(pid);
          _saveMaps(pidMap, ridMap, hashes);
        }
      }
      _notify();
    } catch (e) {
      debugPrint('calendar: delete failed: $e');
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
    AppStore.snapshots.put('cal_pid', pid);
    AppStore.snapshots.put('cal_rid', rid);
    AppStore.snapshots.put('cal_hashes', hashes);
  }

  static Map<String, dynamic> eventToJson(Event e) => {
        'title': e.title ?? '',
        'description': e.description ?? '',
        'location': e.location ?? '',
        'start': e.start?.toIso8601String() ?? '',
        'end': e.end?.toIso8601String() ?? '',
        'allDay': e.allDay ?? false,
      };

  static String hashOf(Map<String, dynamic> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();
}
