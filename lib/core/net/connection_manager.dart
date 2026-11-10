import 'dart:convert';
import 'dart:io';

import 'package:aios/core/activity.dart';
import 'package:aios/core/constants.dart';
import 'package:aios/core/crypto/keys.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/net/discovery.dart';
import 'package:aios/core/net/local_server.dart';
import 'package:aios/core/net/messages.dart';
import 'package:aios/core/net/relay_client.dart';
import 'package:aios/core/net/session.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Trusted peer storage (Hive) + live online status.
class PeerStore extends ChangeNotifier {
  final List<Peer> _peers = [];
  final Map<String, PeerStatus> _status = {};
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<Peer> get all => List.unmodifiable(_peers);

  void load() {
    for (final value in AppStore.peers.values) {
      _peers.add(Peer.fromJson((value as Map).cast<dynamic, dynamic>()));
    }
    _notify();
  }

  Peer? byId(String id) {
    for (final p in _peers) {
      if (p.id == id) return p;
    }
    return null;
  }

  PeerStatus statusOf(String id) =>
      _status[id] ?? const PeerStatus(online: false);

  SecretKey? sharedKey(String id) {
    final raw = AppStore.peers.get(id) as Map?;
    final key = raw?['key'] as List?;
    if (key == null) return null;
    return CryptoKeys.storedSecret(key.cast<int>());
  }

  Future<void> save(Peer peer, SecretKey secret) async {
    final existing = byId(peer.id);
    if (existing != null) _peers.remove(existing);
    _peers.add(peer);
    final map = peer.toJson();
    map['key'] = await secret.extractBytes();
    final prev = AppStore.peers.get(peer.id) as Map?;
    map['lastSeen'] = prev?['lastSeen'] ?? DateTime.now().millisecondsSinceEpoch;
    await AppStore.peers.put(peer.id, map);
    _notify();
  }

  Future<void> remove(String id) async {
    _peers.removeWhere((p) => p.id == id);
    _status.remove(id);
    await AppStore.peers.delete(id);
    await AppStore.outbox.delete(id);
    _notify();
  }

  void markOnline(String id, PeerLinkType via) {
    _status[id] = PeerStatus(online: true, via: via);
    final raw = AppStore.peers.get(id) as Map?;
    if (raw != null) {
      raw['lastSeen'] = DateTime.now().millisecondsSinceEpoch;
      AppStore.peers.put(id, raw);
    }
    _notify();
  }

  void markOffline(String id) {
    _status[id] = PeerStatus(online: false, lastSeen: DateTime.now());
    _notify();
  }

  void refreshStatuses(bool Function(String id) local,
      bool Function(String id) relay) {
    for (final p in _peers) {
      if (local(p.id)) {
        markOnline(p.id, PeerLinkType.local);
      } else if (relay(p.id)) {
        markOnline(p.id, PeerLinkType.relay);
      } else if (_status[p.id]?.online ?? false) {
        markOffline(p.id);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// In-progress pairing handshake with one device.
class PairingSession {
  PairingSession({
    required this.peerId,
    required this.peerName,
    required this.platform,
    required this.publicKey,
    required this.secret,
    required this.code,
    required this.mineInitiated,
  });

  final String peerId;
  final String peerName;
  final PeerPlatform platform;
  final Uint8List publicKey;
  final SecretKey secret;
  final String code;
  final bool mineInitiated;

  /// Whether the local user already accepted/confirmed the code.
  bool localAccepted = false;

  /// 'pending' | 'paired' | 'rejected'
  String result = 'pending';
}

/// Owns discovery, the local server, the relay client, all live sessions,
/// pairing and message routing.
class ConnectionManager extends ChangeNotifier {
  ConnectionManager(this.settings, this.peerStore, this.activity);

  final SettingsController settings;
  final PeerStore peerStore;
  final ActivityLog activity;

  final DiscoveryService discovery = DiscoveryService();
  final LocalServer server = LocalServer();
  final RelayClient relay = RelayClient();

  final Map<String, LocalSession> _sessions = {};
  final List<LocalSession> _pending = [];
  final Map<String, PairingSession> pairings = {};

  /// The most recently finished pairing attempt (paired or rejected).
  PairingSession? lastPairing;

  /// Handler registry: type -> (payload, fromDeviceId).
  final Map<String, void Function(Map<String, dynamic> payload, String from)>
      handlers = {};

  /// Fired when an encrypted session with a paired peer becomes ready.
  void Function(String peerId)? onPeerReady;

  bool _started = false;
  bool _disposed = false;
  bool get started => _started;
  bool get relayConnected => relay.connected;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  PairingSession? get activePairing => pairings.values.isEmpty
      ? null
      : pairings.values.first;

  void on(String type, void Function(Map<String, dynamic>, String) fn) {
    handlers[type] = fn;
  }

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    settings.addListener(_onSettingsChanged);
    relay.addListener(_onRelayChanged);
    relay.onEnvelope = handleRelayEnvelope;
    await discovery.start(
      deviceId: settings.deviceId,
      name: settings.deviceName,
      platform: currentPlatform(),
      port: settings.port,
    );
    await server.start(settings.port, onConnection: _onIncoming);
    await _configureRelay();
    _notify();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    settings.removeListener(_onSettingsChanged);
    relay.removeListener(_onRelayChanged);
    for (final s in _sessions.values) {
      await s.close();
    }
    _sessions.clear();
    for (final s in _pending) {
      await s.close();
    }
    _pending.clear();
    await discovery.stop();
    await server.stop();
    await relay.disconnect();
    _notify();
  }

  void _onSettingsChanged() {
    if (!_started) return;
    _configureRelay();
    if (server.port != settings.port) {
      // Port changed: restart discovery + server.
      discovery.stop();
      server.stop().then((_) async {
        await discovery.start(
          deviceId: settings.deviceId,
          name: settings.deviceName,
          platform: currentPlatform(),
          port: settings.port,
        );
        await server.start(settings.port, onConnection: _onIncoming);
      });
    }
  }

  Future<void> _configureRelay() async {
    if (!settings.useRelay) {
      await relay.disconnect();
      return;
    }
    await relay.configure(
      url: settings.relayUrl,
      groupId: settings.groupId,
      deviceId: settings.deviceId,
      name: settings.deviceName,
      platform: currentPlatform(),
    );
  }

  void _onRelayChanged() {
    final before = <String, bool>{
      for (final p in peerStore.all) p.id: peerStore.statusOf(p.id).online,
    };
    peerStore.refreshStatuses(
      (id) => _sessions.containsKey(id),
      (id) => relay.hasPeer(id),
    );
    // Trigger sync for paired peers that just came online via the relay.
    for (final p in peerStore.all) {
      final wasOnline = before[p.id] ?? false;
      final nowOnline = peerStore.statusOf(p.id).online;
      if (!wasOnline &&
          nowOnline &&
          relay.hasPeer(p.id) &&
          !_sessions.containsKey(p.id)) {
        onPeerReady?.call(p.id);
      }
    }
    _notify();
  }

  // ---------------------------------------------------------------------
  // Outbound connections
  // ---------------------------------------------------------------------

  Future<Map<String, dynamic>> helloPayload() async {
    final pub = await CryptoKeys.myPublicKey();
    return {
      'id': settings.deviceId,
      'name': settings.deviceName,
      'platform': platformToString(currentPlatform()),
      'pub': base64Encode(pub),
      'v': K.protocolVersion,
    };
  }

  Future<bool> connectLocal(String host, int port) async {
    try {
      final ws = await WebSocket.connect('ws://$host:$port')
          .timeout(const Duration(seconds: 8));
      final s = LocalSession(ws, host)..isInitiator = true;
      _pending.add(s);
      ws.listen(
        (data) => _handleLocal(s, data as String? ?? ''),
        onDone: () => _onSessionClosed(s),
        onError: (Object _) => _onSessionClosed(s),
        cancelOnError: true,
      );
      s.sendMessage(await Messages.buildMessage(
          K.msgHello, settings.deviceId, await helloPayload()));
      s.sentHello = true;
      return true;
    } catch (e) {
      activity.add('⚠️', 'Could not connect to $host:$port', '$e');
      return false;
    }
  }

  /// Pairing request over the relay (peer already visible via presence).
  Future<void> pairWithRelay(String peerId) async {
    final rp = relay.peers[peerId];
    if (rp == null || pairings.containsKey(peerId)) return;
    await _beginPairing(
      peerId: peerId,
      name: rp.name,
      platform: rp.platform,
      pub: rp.publicKey,
      mine: true,
    );
    if (!pairings.containsKey(peerId)) return;
    await send(peerId, K.msgPairingInit, {
      'name': settings.deviceName,
      'platform': platformToString(currentPlatform()),
      'pub': base64Encode(await CryptoKeys.myPublicKey()),
    });
  }

  // ---------------------------------------------------------------------
  // Inbound handling
  // ---------------------------------------------------------------------

  void _onIncoming(LocalSession s) {
    s.socket.listen(
      (data) => _handleLocal(s, data as String? ?? ''),
      onDone: () => _onSessionClosed(s),
      onError: (Object _) => _onSessionClosed(s),
      cancelOnError: true,
    );
  }

  Future<void> _handleLocal(LocalSession s, String raw) async {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = json['t'] as String? ?? '';

    if (type == K.msgHello) {
      await _handleHello(s, json);
      return;
    }

    try {
      if (json.containsKey('e')) {
        if (s.key == null) return;
        final decoded = await Messages.decodeEnvelope(json, key: s.key);
        await _dispatch(decoded['t'] as String, decoded['f'] as String,
            decoded['p'] as Map<String, dynamic>);
      } else {
        final payload =
            (json['p'] as Map?)?.cast<String, dynamic>() ?? const {};
        final from = json['f'] as String? ?? '';
        if (type == K.msgPairingConfirm ||
            type == K.msgPairingReject ||
            type == K.msgError) {
          await _dispatch(type, from, payload);
        }
        // Other plaintext message types are rejected once paired.
      }
    } catch (e) {
      debugPrint('session: bad message from ${s.peerId}: $e');
    }
  }

  Future<void> _handleHello(LocalSession s, Map<String, dynamic> json) async {
    final from = json['f'] as String? ?? '';
    final payload = (json['p'] as Map?)?.cast<String, dynamic>() ?? {};
    if (from.isEmpty || from == settings.deviceId) {
      await s.close();
      return;
    }
    Uint8List pub;
    try {
      pub = base64Decode(payload['pub'] as String? ?? '');
    } catch (_) {
      await s.close();
      return;
    }

    s.peerId = from;
    _registerSession(s);

    final peer = peerStore.byId(from);
    if (peer != null) {
      if (!listEquals(peer.publicKey, pub)) {
        activity.add('🛡️', 'Rejected ${peer.name}: identity changed');
        await s.close();
        return;
      }
      s.key = peerStore.sharedKey(from);
      s.encrypted = true;
      if (!s.sentHello) {
        s.sendMessage(await Messages.buildMessage(
            K.msgHello, settings.deviceId, await helloPayload()));
        s.sentHello = true;
      }
      peerStore.markOnline(from, PeerLinkType.local);
      activity.add('🔌', '${peer.name} connected');
      _notify();
      onPeerReady?.call(from);
      return;
    }

    // Unknown device: start pairing.
    if (!s.sentHello) {
      s.sendMessage(await Messages.buildMessage(
          K.msgHello, settings.deviceId, await helloPayload()));
      s.sentHello = true;
    }
    await _beginPairing(
      peerId: from,
      name: payload['name'] as String? ?? 'Unknown',
      platform: platformFromString(payload['platform'] as String?),
      pub: pub,
      mine: s.isInitiator,
    );
  }

  void _registerSession(LocalSession s) {
    final id = s.peerId;
    if (id == null) return;
    final prev = _sessions[id];
    _sessions[id] = s;
    if (prev != null && prev != s) {
      prev.close();
    }
    _pending.remove(s);
  }

  Future<void> _onSessionClosed(LocalSession s) async {
    _pending.remove(s);
    final id = s.peerId;
    if (id != null && _sessions[id] == s) {
      _sessions.remove(id);
      if (!relay.hasPeer(id)) {
        peerStore.markOffline(id);
      } else {
        peerStore.markOnline(id, PeerLinkType.relay);
      }
      _notify();
    }
    await s.close();
  }

  /// Relay-routed envelopes.
  Future<void> handleRelayEnvelope(
      String from, Map<String, dynamic> envelope) async {
    final type = envelope['t'] as String? ?? '';
    try {
      if (envelope.containsKey('e')) {
        final peer = peerStore.byId(from);
        if (peer == null) return;
        final decoded = await Messages.decodeEnvelope(envelope,
            key: peerStore.sharedKey(from));
        await _dispatch(
            decoded['t'] as String, from, decoded['p'] as Map<String, dynamic>);
        return;
      }
      final payload =
          (envelope['p'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (type == K.msgPairingInit) {
        Uint8List pub;
        try {
          pub = base64Decode(payload['pub'] as String? ?? '');
        } catch (_) {
          return;
        }
        await _beginPairing(
          peerId: from,
          name: payload['name'] as String? ?? 'Unknown',
          platform: platformFromString(payload['platform'] as String?),
          pub: pub,
          mine: false,
        );
      } else if (type == K.msgPairingConfirm ||
          type == K.msgPairingReject) {
        await _dispatch(type, from, payload);
      }
    } catch (e) {
      debugPrint('relay: bad envelope from $from: $e');
    }
  }

  Future<void> _dispatch(
      String type, String from, Map<String, dynamic> payload) async {
    switch (type) {
      case K.msgPairingConfirm:
        await _onPairingConfirm(from, payload);
        return;
      case K.msgPairingReject:
        final p = pairings.remove(from);
        if (p != null) {
          p.result = 'rejected';
          lastPairing = p;
          activity.add('❌', 'Pairing declined by other device');
          _notify();
        }
        return;
      case K.msgError:
        activity.add('⚠️', 'Error from peer',
            payload['code'] as String? ?? 'unknown');
        return;
      default:
        handlers[type]?.call(payload, from);
    }
  }

  // ---------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------

  Future<void> _beginPairing({
    required String peerId,
    required String name,
    required PeerPlatform platform,
    required Uint8List pub,
    required bool mine,
  }) async {
    if (pairings.containsKey(peerId) || peerStore.byId(peerId) != null) return;
    try {
      final secret = await CryptoKeys.sharedSecretWith(pub);
      final code =
          await CryptoKeys.pairingCode(secret, settings.deviceId, peerId);
      pairings[peerId] = PairingSession(
        peerId: peerId,
        peerName: name,
        platform: platform,
        publicKey: pub,
        secret: secret,
        code: code,
        mineInitiated: mine,
      );
      activity.add('🤝', 'Pairing with $name',
          mine ? 'Confirm the code on both devices' : '$name wants to pair');
      _notify();
    } catch (e) {
      debugPrint('pairing: $e');
    }
  }

  Future<void> confirmPairing(String peerId, bool accept) async {
    final p = pairings[peerId];
    if (p == null) return;
    if (!accept) {
      pairings.remove(peerId);
      p.result = 'rejected';
      lastPairing = p;
      await send(peerId, K.msgPairingReject, {});
      _notify();
      return;
    }
    p.localAccepted = true;
    _notify();
    await send(peerId, K.msgPairingConfirm, {'code': p.code});
  }

  Future<void> _onPairingConfirm(
      String from, Map<String, dynamic> payload) async {
    final p = pairings[from];
    if (p == null) return;
    if (payload['code'] != p.code) {
      pairings.remove(from);
      p.result = 'rejected';
      lastPairing = p;
      activity.add('🛡️', 'Pairing failed: code mismatch');
      _notify();
      return;
    }
    await _finalizePairing(from);
  }

  Future<void> _finalizePairing(String peerId) async {
    final p = pairings.remove(peerId);
    if (p == null) return;
    p.result = 'paired';
    lastPairing = p;
    final peer = Peer(
      id: p.peerId,
      name: p.peerName,
      platform: p.platform,
      publicKey: p.publicKey,
      pairedAt: DateTime.now(),
    );
    await peerStore.save(peer, p.secret);
    final session = _sessions[peerId];
    if (session != null) {
      session.key = p.secret;
      session.encrypted = true;
    }
    if (session != null) {
      peerStore.markOnline(peerId, PeerLinkType.local);
    } else if (relay.hasPeer(peerId)) {
      peerStore.markOnline(peerId, PeerLinkType.relay);
    }
    activity.add('🔗', 'Paired with ${p.peerName}');
    _notify();
    onPeerReady?.call(peerId);
  }

  // ---------------------------------------------------------------------
  // Outbound messaging
  // ---------------------------------------------------------------------

  Future<bool> send(
      String peerId, String type, Map<String, dynamic> payload) async {
    final peer = peerStore.byId(peerId);
    final key = peer == null ? null : peerStore.sharedKey(peerId);
    final msg =
        await Messages.buildMessage(type, settings.deviceId, payload, key: key);
    final s = _sessions[peerId];
    if (s != null) {
      s.sendMessage(msg);
      return true;
    }
    if (relay.hasPeer(peerId)) {
      relay.sendRoute(peerId, msg);
      return true;
    }
    return false;
  }

  Future<void> broadcast(String type, Map<String, dynamic> payload) async {
    for (final p in peerStore.all) {
      await send(p.id, type, payload);
    }
  }

  bool reachable(String peerId) =>
      _sessions.containsKey(peerId) || relay.hasPeer(peerId);

  bool isLocallyConnected(String peerId) => _sessions.containsKey(peerId);

  Future<void> unpair(String peerId) async {
    final s = _sessions.remove(peerId);
    if (s != null) await s.close();
    pairings.remove(peerId);
    await peerStore.remove(peerId);
    activity.add('🔓', 'Unpaired device');
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
