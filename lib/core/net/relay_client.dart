import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aios/core/constants.dart';
import 'package:aios/core/crypto/keys.dart';
import 'package:aios/core/models.dart';
import 'package:flutter/foundation.dart';

/// A device visible through the relay (same sync group).
class RelayPeer {
  const RelayPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
  });

  final String id;
  final String name;
  final PeerPlatform platform;
  final Uint8List publicKey;
}

/// Client for the cloud relay server.
///
/// The relay is a dumb forwarder: it routes encrypted envelopes between
/// devices that share the same group id and announces presence. All payloads
/// are end-to-end encrypted with the per-pair keys, so the relay cannot read
/// anything.
class RelayClient extends ChangeNotifier {
  String _url = '';
  String _groupId = '';
  String _deviceId = '';
  String _name = '';
  PeerPlatform _platform = PeerPlatform.unknown;
  String? _publicKeyB64;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _stopped = false;

  bool connected = false;
  bool get configured => _url.isNotEmpty && _groupId.isNotEmpty;
  String? lastError;

  /// Peers currently online in our group.
  final Map<String, RelayPeer> peers = {};

  /// Called for every routed envelope: `(fromDeviceId, envelope)`.
  void Function(String from, Map<String, dynamic> envelope)? onEnvelope;

  Future<void> configure({
    required String url,
    required String groupId,
    required String deviceId,
    required String name,
    required PeerPlatform platform,
  }) async {
    final changed = url != _url || groupId != _groupId || deviceId != _deviceId;
    _url = url;
    _groupId = groupId;
    _deviceId = deviceId;
    _name = name;
    _platform = platform;
    try {
      _publicKeyB64 = base64Encode(await CryptoKeys.myPublicKey());
    } catch (_) {}
    if (changed || !connected) {
      await disconnect();
      if (configured) await connect();
    }
  }

  Future<void> connect() async {
    if (!configured || _socket != null) return;
    _stopped = false;
    _reconnectTimer?.cancel();
    lastError = null;
    try {
      final socket = await WebSocket.connect(_url)
          .timeout(const Duration(seconds: 12));
      _socket = socket;
      socket.listen(_onData,
          onDone: _onDone, onError: (e) => _onError('$e'));
      socket.add(jsonEncode({
        'op': K.relayOpRegister,
        'g': _groupId,
        'id': _deviceId,
        'name': _name,
        'platform': platformToString(_platform),
        'pub': _publicKeyB64,
      }));
      _pingTimer?.cancel();
      _pingTimer =
          Timer.periodic(const Duration(seconds: 25), (_) => _ping());
      connected = true;
      notifyListeners();
      debugPrint('relay: connected to $_url');
    } catch (e) {
      _socket = null;
      _onError('$e');
    }
  }

  void _ping() {
    try {
      _socket?.add(jsonEncode({'op': K.relayOpPing}));
    } catch (_) {}
  }

  void _onData(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['op']) {
        case K.relayOpRegistered:
        case K.relayOpPresence:
          _onPresence((msg['peers'] as List?) ?? const []);
          break;
        case K.relayOpRoute:
          final from = msg['from'] as String? ?? '';
          final envelope = (msg['e'] as Map?)?.cast<String, dynamic>() ?? {};
          onEnvelope?.call(from, envelope);
          break;
        case K.relayOpPong:
          break;
      }
    } catch (_) {}
  }

  void _onPresence(List<dynamic> list) {
    peers.clear();
    for (final item in list) {
      if (item is! Map) continue;
      final id = item['id'] as String? ?? '';
      if (id.isEmpty || id == _deviceId) continue;
      Uint8List? pub;
      final pubB64 = item['pub'] as String?;
      if (pubB64 != null) {
        try {
          pub = base64Decode(pubB64);
        } catch (_) {}
      }
      peers[id] = RelayPeer(
        id: id,
        name: item['name'] as String? ?? 'Unknown',
        platform: platformFromString(item['platform'] as String?),
        publicKey: pub ?? Uint8List(0),
      );
    }
    notifyListeners();
  }

  void sendRoute(String to, Map<String, dynamic> envelope) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode({'op': K.relayOpRoute, 'to': to, 'e': envelope}));
    } catch (_) {}
  }

  bool hasPeer(String id) => peers.containsKey(id);

  void _onDone() {
    if (_socket == null) return;
    _socket = null;
    if (connected) {
      connected = false;
      peers.clear();
      notifyListeners();
    }
    _scheduleReconnect();
  }

  void _onError(String e) {
    lastError = e;
    if (_socket != null) {
      _socket = null;
      if (connected) {
        connected = false;
        peers.clear();
        notifyListeners();
      }
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped || !configured) return;
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(const Duration(seconds: 5), () => connect());
  }

  Future<void> disconnect() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    if (connected) {
      connected = false;
      peers.clear();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
