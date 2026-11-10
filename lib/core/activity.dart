import 'package:aios/core/models.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:flutter/foundation.dart';

/// In-memory + persisted activity feed (shown on the dashboard).
class ActivityLog extends ChangeNotifier {
  List<ActivityEntry> entries = [];
  static const int maxEntries = 200;

  void load() {
    final stored = AppStore.activityBox.get('entries') as List?;
    entries = (stored ?? const [])
        .map((e) => ActivityEntry.fromJson((e as Map).cast<dynamic, dynamic>()))
        .toList();
    notifyListeners();
  }

  void add(String icon, String title, [String? subtitle]) {
    entries.insert(0, ActivityEntry(
        ts: DateTime.now(), icon: icon, title: title, subtitle: subtitle));
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }
    AppStore.activityBox.put(
        'entries', entries.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  void clear() {
    entries.clear();
    AppStore.activityBox.delete('entries');
    notifyListeners();
  }
}
