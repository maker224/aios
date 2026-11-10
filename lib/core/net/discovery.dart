import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aios/core/constants.dart';
import 'package:aios/core/models.dart';
import 'package:flutter/foundation.dart';

/// Discovers devices on the local network via UDP broadcast.
///
/// Every device binds port [K.discoveryPort] and:
/// * answers `AIOS_PING` datagrams with `AIOS_PONG {info}`;
/// * can send `AIOS_PING` itself (a "scan") and collects pongs for a few
///   seconds.
///
/// Candidates automatically expire after [candidateTtl].
class DiscoveryService extends ChangeNotifier {
  RawDatagramSocket? _socket;
  Timer? _pruneTimer;
  bool running = false;

  String _deviceId = '';
  String _name = '';
  PeerPlatform _platform = PeerPlatform.unknown;
  int _port = K.defaultPort;

  final Map<String, DeviceCandidate> candidates = {};

  static const Duration candidateTtl = Duration(seconds: 12);

  Future<void> start({
    required String deviceId,
    required String name,
    required PeerPlatform platform,
    required int port,
  }) async {
    if (running) return;
    _deviceId = deviceId;
    _name = name;
    _platform = platform;
    _port = port;

    // Some platforms support SO_REUSEPORT, others don't. Try the
    // permissive binding first and fall back to a plain one.
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        K.discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
    } catch (_) {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        K.discoveryPort,
        reuseAddress: true,
      );
    }
    _socket!.broadcastEnabled = true;
    _socket!.listen(_onEvent, onError: (e) => debugPrint('discovery: $e'));
    running = true;

    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final cutoff = DateTime.now().subtract(candidateTtl);
      final before = candidates.length;
      candidates.removeWhere(
          (_, c) => c.discoveredAt == null || c.discoveredAt!.isBefore(cutoff));
      if (candidates.length != before) notifyListeners();
    });

    // Announce ourselves once at startup so passive listeners see us.
    scan();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) return;
    Datagram? d;
    try {
      d = _socket!.receive();
    } catch (_) {}
    if (d == null) return;
    final text = utf8.decode(d.data, allowMalformed: true);
    if (text.startsWith('AIOS_PING')) {
      _handlePing(d);
    } else if (text.startsWith('AIOS_PONG ')) {
      _handlePong(text.substring('AIOS_PONG '.length), d.address.address);
    }
  }

  void _handlePing(Datagram d) {
    try {
      final reply = 'AIOS_PONG ${jsonEncode(_info())}';
      _socket?.send(utf8.encode(reply), d.address, d.port);
    } catch (_) {}
  }

  void _handlePong(String json, String address) {
    try {
      final info = jsonDecode(json) as Map<String, dynamic>;
      final id = info['id'] as String? ?? '';
      if (id.isEmpty || id == _deviceId) return;
      final port = info['port'] as int? ?? K.defaultPort;
      candidates[id] = DeviceCandidate(
        id: id,
        name: info['name'] as String? ?? 'Unknown',
        platform: platformFromString(info['platform'] as String?),
        address: address,
        port: port,
        source: 'local',
        discoveredAt: DateTime.now(),
      );
      notifyListeners();
    } catch (_) {}
  }

  Map<String, dynamic> _info() => {
        'id': _deviceId,
        'name': _name,
        'platform': platformToString(_platform),
        'port': _port,
        'v': K.protocolVersion,
      };

  /// Broadcasts a ping twice, 400 ms apart.
  void scan() {
    if (!running || _socket == null) return;
    final ping = utf8.encode('AIOS_PING');
    for (var i = 0; i < 2; i++) {
      Future<void>.delayed(Duration(milliseconds: 400 * i), () {
        try {
          _socket?.send(
              ping, InternetAddress('255.255.255.255'), K.discoveryPort);
        } catch (_) {}
      });
    }
  }

  Future<void> stop() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    running = false;
    candidates.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
