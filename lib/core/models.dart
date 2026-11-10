import 'dart:io';
import 'dart:typed_data';

/// Platform of a peer device.
enum PeerPlatform { android, ios, macos, windows, unknown }

PeerPlatform platformFromString(String? s) {
  switch (s) {
    case 'android':
      return PeerPlatform.android;
    case 'ios':
      return PeerPlatform.ios;
    case 'macos':
      return PeerPlatform.macos;
    case 'windows':
      return PeerPlatform.windows;
    default:
      return PeerPlatform.unknown;
  }
}

String platformToString(PeerPlatform p) => p.name;

PeerPlatform currentPlatform() {
  if (Platform.isAndroid) return PeerPlatform.android;
  if (Platform.isIOS) return PeerPlatform.ios;
  if (Platform.isMacOS) return PeerPlatform.macos;
  if (Platform.isWindows) return PeerPlatform.windows;
  return PeerPlatform.unknown;
}

/// A paired, trusted device.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.pairedAt,
  });

  final String id;
  final String name;
  final PeerPlatform platform;
  final Uint8List publicKey;
  final DateTime pairedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platformToString(platform),
        'pub': publicKey,
        'pairedAt': pairedAt.millisecondsSinceEpoch,
      };

  factory Peer.fromJson(Map<dynamic, dynamic> json) => Peer(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Unknown',
        platform: platformFromString(json['platform'] as String?),
        publicKey: Uint8List.fromList((json['pub'] as List).cast<int>()),
        pairedAt: DateTime.fromMillisecondsSinceEpoch(
            json['pairedAt'] as int? ?? 0),
      );
}

/// A device that was discovered but is not necessarily paired yet.
class DeviceCandidate {
  const DeviceCandidate({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.source,
    this.publicKey,
    this.discoveredAt,
  });

  final String id;
  final String name;
  final PeerPlatform platform;
  final String address;
  final int port;

  /// 'local' (broadcast discovery), 'relay' (relay presence) or 'manual'.
  final String source;
  final Uint8List? publicKey;
  final DateTime? discoveredAt;
}

enum PeerLinkType { local, relay }

class PeerStatus {
  const PeerStatus({required this.online, this.via, this.lastSeen});

  final bool online;
  final PeerLinkType? via;
  final DateTime? lastSeen;
}

/// One entry in the activity feed.
class ActivityEntry {
  const ActivityEntry({
    required this.ts,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final DateTime ts;
  final String icon;
  final String title;
  final String? subtitle;

  Map<String, dynamic> toJson() => {
        'ts': ts.millisecondsSinceEpoch,
        'icon': icon,
        'title': title,
        'subtitle': subtitle,
      };

  factory ActivityEntry.fromJson(Map<dynamic, dynamic> json) => ActivityEntry(
        ts: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int? ?? 0),
        icon: json['icon'] as String? ?? '',
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String?,
      );
}

/// The kinds of data synchronized as versioned records.
enum DataType { note, clipboard, contact, calendar }

/// A single versioned record exchanged between devices.
/// Conflict resolution is last-write-wins on [updatedAt].
class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.type,
    required this.deviceId,
    required this.updatedAt,
    required this.deleted,
    required this.data,
  });

  final String id;
  final DataType type;
  final String deviceId;
  final DateTime updatedAt;
  final bool deleted;
  final Map<String, dynamic> data;

  String get key => '${type.name}:$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        't': type.name,
        'd': deviceId,
        'u': updatedAt.millisecondsSinceEpoch,
        'del': deleted,
        'data': data,
      };

  factory SyncRecord.fromJson(Map<dynamic, dynamic> json) => SyncRecord(
        id: json['id'] as String,
        type: DataType.values.firstWhere((t) => t.name == json['t'],
            orElse: () => DataType.note),
        deviceId: json['d'] as String? ?? '',
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(json['u'] as int? ?? 0),
        deleted: json['del'] as bool? ?? false,
        data: (json['data'] as Map?)?.cast<String, dynamic>() ?? {},
      );
}

enum TransferDirection { send, receive }

enum TransferStatus {
  hashing,
  offering,
  sending,
  receiving,
  verifying,
  done,
  failed,
}

/// One file/photo transfer in flight.
class TransferItem {
  TransferItem({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.name,
    required this.size,
    required this.direction,
    required this.category,
  });

  final String id;
  final String peerId;
  String peerName;
  final String name;
  final int size;
  final TransferDirection direction;

  /// 'file' or 'photo'
  final String category;

  TransferStatus status = TransferStatus.hashing;
  int bytesDone = 0;
  String? error;
  DateTime startedAt = DateTime.now();
}
