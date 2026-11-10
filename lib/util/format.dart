import 'package:aios/core/models.dart';
import 'package:aios/core/net/connection_manager.dart';

String shortId(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// Friendly name for a device id, falling back to a short id.
String nameOf(String id, PeerStore? peers) =>
    peers?.byId(id)?.name ?? shortId(id);

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

String formatDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

String formatAgo(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return formatDate(t);
}

String platformLabel(PeerPlatform p) {
  switch (p) {
    case PeerPlatform.android:
      return 'Android';
    case PeerPlatform.ios:
      return 'iPhone/iPad';
    case PeerPlatform.macos:
      return 'Mac';
    case PeerPlatform.windows:
      return 'Windows';
    case PeerPlatform.unknown:
      return 'Device';
  }
}
