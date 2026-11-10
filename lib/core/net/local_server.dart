import 'dart:io';

import 'package:aios/core/net/session.dart';
import 'package:flutter/foundation.dart';

/// Local WebSocket server: accepts encrypted sync connections from other
/// devices on the same network.
class LocalServer {
  HttpServer? _server;
  int port = 0;
  bool get running => _server != null;

  /// Called for every new incoming connection.
  void Function(LocalSession session)? onConnection;

  Future<void> start(
    int port, {
    required void Function(LocalSession session) onConnection,
  }) async {
    this.port = port;
    this.onConnection = onConnection;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException catch (e) {
      // Port busy: try an ephemeral port so local sync still works when
      // another instance of the app is already running on this machine.
      debugPrint('local server: port $port busy ($e), trying ephemeral');
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      this.port = _server!.port;
    }
    _server!.listen(_onRequest);
    debugPrint('local server listening on port ${this.port}');
  }

  Future<void> _onRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final address =
          request.connectionInfo?.remoteAddress.address ?? 'unknown';
      final session = LocalSession(socket, address);
      onConnection?.call(session);
    } catch (e) {
      debugPrint('local server: upgrade failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }
}
