import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// A single WebSocket link to one device (incoming or outgoing).
///
/// Before pairing the session carries plaintext `hello` / `pairing_*`
/// messages only. After pairing, [key] is set and every outgoing message
/// must be built with that key (see `Messages.buildMessage`).
class LocalSession {
  LocalSession(this.socket, this.remoteAddress);

  final WebSocket socket;
  final String remoteAddress;

  /// Device id once identified (via hello).
  String? peerId;

  /// Shared AES key after pairing.
  SecretKey? key;

  bool sentHello = false;

  /// True when we opened the socket, false when it was accepted.
  bool isInitiator = false;

  /// True while the remote has paired with us (session switched to
  /// encrypted mode).
  bool encrypted = false;

  void sendMessage(Map<String, dynamic> message) {
    socket.add(jsonEncode(message));
  }

  void sendRaw(String raw) => socket.add(raw);

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }
}
