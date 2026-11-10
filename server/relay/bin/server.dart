import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// AIoS relay server (zero dependencies — pure dart:io).
///
/// A dumb forwarder:
/// * Devices register with a group id and a device id.
/// * Devices in the same group see each other (presence).
/// * Devices route JSON envelopes to each other.
///
/// The relay never sees plaintext data: all envelopes are end-to-end
/// encrypted with per-pair keys negotiated during device pairing.
///
/// Protocol (JSON over WebSocket at /ws):
///   -> {op: register, g, id, name, platform, pub}
///   <- {op: registered}
///   <- {op: presence, peers: [{id, name, platform, pub}]}
///   -> {op: route, to, e: envelope}   <- {op: route, from, e: envelope}
///   -> {op: ping}                     <- {op: pong}
class _Conn {
  _Conn({
    required this.group,
    required this.id,
    required this.name,
    required this.platform,
    required this.pub,
    required this.socket,
  });

  final String group;
  final String id;
  final String name;
  final String platform;
  final String? pub;
  final WebSocket socket;
  DateTime lastPing = DateTime.now();

  /// Envelopes routed through this connection.
  int routed = 0;
}

final Map<String, Map<String, _Conn>> _groups = {};
final DateTime _startedAt = DateTime.now();
int _totalRouted = 0;
int _totalRegistered = 0;

Future<void> main() async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('AIoS relay listening on port $port (ws://0.0.0.0:$port/ws)');

  server.listen((HttpRequest request) async {
    switch (request.uri.path) {
      case '/health':
        request.response.headers.contentType = ContentType.json;
        request.response
            .write(jsonEncode({'status': 'ok', 'groups': _groups.length}));
        await request.response.close();
        return;
      case '/api/state':
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_apiState()));
        await request.response.close();
        return;
      case '/dashboard':
        request.response.headers.contentType = ContentType.html;
        request.response.write(_dashboardHtml());
        await request.response.close();
        return;
      case '/':
        request.response.write(
            'AIoS relay v1\nWebSocket endpoint: /ws\nDashboard: /dashboard\n'
            'Groups connected: ${_groups.length}');
        await request.response.close();
        return;
      case '/ws':
        WebSocket socket;
        try {
          socket = await WebSocketTransformer.upgrade(request);
        } catch (_) {
          return;
        }
        _handleConnection(socket);
        return;
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  });

  // Heartbeat sweep: drop clients that stopped pinging.
  Timer.periodic(const Duration(seconds: 30), (_) {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 90));
    final toRemove = <String, List<String>>{};
    for (final entry in _groups.entries) {
      for (final c in entry.value.entries) {
        if (c.value.lastPing.isBefore(cutoff)) {
          toRemove.putIfAbsent(entry.key, () => []).add(c.key);
        }
      }
    }
    for (final entry in toRemove.entries) {
      final group = _groups[entry.key];
      if (group == null) continue;
      for (final id in entry.value) {
        final c = group.remove(id);
        try {
          c?.socket.close();
        } catch (_) {}
      }
      if (group.isEmpty) _groups.remove(entry.key);
      _broadcastPresence(entry.key);
    }
  });
}

void _handleConnection(WebSocket socket) {
  _Conn? conn;
  void leave() {
    if (conn == null) return;
    final group = _groups[conn!.group];
    if (group == null) return;
    if (group[conn!.id] == conn) {
      group.remove(conn!.id);
      if (group.isEmpty) _groups.remove(conn!.group);
      _broadcastPresence(conn!.group);
    }
  }

  socket.listen(
    (raw) {
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(raw as String) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      switch (msg['op']) {
        case 'register':
          final g = msg['g'] as String? ?? '';
          final id = msg['id'] as String? ?? '';
          if (g.isEmpty || id.isEmpty) return;
          final c = _Conn(
            group: g,
            id: id,
            name: msg['name'] as String? ?? 'Unknown',
            platform: msg['platform'] as String? ?? '',
            pub: msg['pub'] as String?,
            socket: socket,
          );
          final group = _groups.putIfAbsent(g, () => {});
          final old = group[id];
          if (old != null) {
            try {
              old.socket.close();
            } catch (_) {}
          }
          group[id] = c;
          conn = c;
          _totalRegistered++;
          try {
            socket.add(jsonEncode({'op': 'registered'}));
          } catch (_) {}
          _broadcastPresence(g);
          break;

        case 'route':
          if (conn == null) return;
          final to = msg['to'] as String? ?? '';
          final target = _groups[conn!.group]?[to];
          if (target == null) return;
          try {
            target.socket.add(jsonEncode({
              'op': 'route',
              'from': conn!.id,
              'e': msg['e'],
            }));
            conn!.routed++;
            target.routed++;
            _totalRouted++;
          } catch (_) {}
          break;

        case 'ping':
          if (conn != null) conn!.lastPing = DateTime.now();
          try {
            socket.add(jsonEncode({'op': 'pong'}));
          } catch (_) {}
          break;
      }
    },
    onDone: leave,
    onError: (_) => leave(),
    cancelOnError: true,
  );
}

void _broadcastPresence(String groupId) {
  final group = _groups[groupId];
  if (group == null) return;
  final peers = [
    for (final c in group.values)
      {
        'id': c.id,
        'name': c.name,
        'platform': c.platform,
        'pub': c.pub,
      }
  ];
  final payload = jsonEncode({'op': 'presence', 'peers': peers});
  for (final c in group.values) {
    try {
      c.socket.add(payload);
    } catch (_) {}
  }
}

Map<String, dynamic> _apiState() {
  final now = DateTime.now();
  return {
    'status': 'ok',
    'uptimeSeconds': now.difference(_startedAt).inSeconds,
    'groups': _groups.length,
    'connections':
        _groups.values.fold<int>(0, (sum, g) => sum + g.length),
    'messagesRouted': _totalRouted,
    'registrations': _totalRegistered,
    'groupList': [
      for (final entry in _groups.entries)
        {
          'groupId': entry.key,
          'devices': [
            for (final c in entry.value.values)
              {
                'id': c.id,
                'name': c.name,
                'platform': c.platform,
                'online': now.difference(c.lastPing).inSeconds < 90,
                'lastSeenSecondsAgo': now.difference(c.lastPing).inSeconds,
                'routed': c.routed,
              }
          ],
        }
    ],
  };
}

String _dashboardHtml() => r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIoS Relay</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 20px;
    background: #0f1117; color: #e6e8ee;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: #8b91a3; font-size: 13px; margin-bottom: 24px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 28px; }
  .card { background: #171a23; border: 1px solid #262b38; border-radius: 12px; padding: 14px 16px; }
  .card .num { font-size: 26px; font-weight: 700; }
  .card .lbl { color: #8b91a3; font-size: 12px; margin-top: 2px; }
  .group { background: #171a23; border: 1px solid #262b38; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
  .group h2 { font-size: 15px; margin: 0 0 12px; word-break: break-all; }
  .group h2 .cnt { color: #8b91a3; font-weight: 400; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; color: #8b91a3; font-weight: 500; padding: 6px 8px; border-bottom: 1px solid #262b38; }
  td { padding: 8px; border-bottom: 1px solid #1d2130; }
  tr:last-child td { border-bottom: none; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
  .on { background: #34d399; } .off { background: #6b7280; }
  .platform { color: #8b91a3; }
  .empty { color: #8b91a3; text-align: center; padding: 40px 0; }
  .foot { color: #565c6e; font-size: 11px; text-align: center; margin-top: 24px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>AIoS Relay</h1>
  <div class="sub">Live status — updates every 2 seconds</div>
  <div class="cards">
    <div class="card"><div class="num" id="uptime">–</div><div class="lbl">Uptime</div></div>
    <div class="card"><div class="num" id="groups">–</div><div class="lbl">Sync groups</div></div>
    <div class="card"><div class="num" id="conns">–</div><div class="lbl">Connected devices</div></div>
    <div class="card"><div class="num" id="msgs">–</div><div class="lbl">Envelopes routed</div></div>
  </div>
  <div id="groupsArea"><div class="empty">Loading…</div></div>
  <div class="foot">All payloads are end-to-end encrypted — the relay forwards ciphertext only.</div>
</div>
<script>
function fmtUptime(s) {
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
  if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
  return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h";
}
function fmtAgo(s) {
  if (s < 5) return "now";
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  return Math.floor(s / 3600) + "h ago";
}
const PLATFORM = { ios: "iPhone/iPad", macos: "Mac", android: "Android", windows: "Windows" };
async function refresh() {
  try {
    const r = await fetch("/api/state");
    const s = await r.json();
    document.getElementById("uptime").textContent = fmtUptime(s.uptimeSeconds);
    document.getElementById("groups").textContent = s.groups;
    document.getElementById("conns").textContent = s.connections;
    document.getElementById("msgs").textContent = s.messagesRouted;
    const area = document.getElementById("groupsArea");
    if (!s.groupList.length) {
      area.innerHTML = '<div class="empty">No devices connected yet.<br>Point the AIoS app at this relay to see them here.</div>';
      return;
    }
    area.innerHTML = s.groupList.map(g => {
      const rows = g.devices.map(d => {
        const dot = d.online ? '<span class="dot on"></span>' : '<span class="dot off"></span>';
        return '<tr><td>' + dot + esc(d.name) + '</td><td class="platform">' + (PLATFORM[d.platform] || d.platform || "–") + '</td>' +
               '<td class="platform">' + esc(d.id.slice(0, 8)) + '</td><td>' + fmtAgo(d.lastSeenSecondsAgo) + '</td><td>' + d.routed + '</td></tr>';
      }).join("");
      return '<div class="group"><h2>Group <span class="cnt">(' + g.devices.length + ' devices)</span> ' + esc(g.groupId) + '</h2>' +
             '<table><tr><th>Device</th><th>Platform</th><th>ID</th><th>Last seen</th><th>Routed</th></tr>' + rows + '</table></div>';
    }).join("");
  } catch (e) { document.getElementById("groupsArea").innerHTML = '<div class="empty">Relay unreachable</div>'; }
}
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>
''';
