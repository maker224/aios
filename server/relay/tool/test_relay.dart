// Manual end-to-end test for the AIoS relay. Run: dart run test_manual.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args.first
      : 'ws://localhost:8081/ws';
  print('Testing relay at $url');
  final a = await WebSocket.connect(url);
  final b = await WebSocket.connect(url);

  final aMsgs = <Map<String, dynamic>>[];
  final bMsgs = <Map<String, dynamic>>[];
  a.listen((raw) => aMsgs.add(jsonDecode(raw as String)));
  b.listen((raw) => bMsgs.add(jsonDecode(raw as String)));

  a.add(jsonEncode({
    'op': 'register',
    'g': 'test-group',
    'id': 'device-A',
    'name': 'iPhone',
    'platform': 'ios',
    'pub': 'pubA',
  }));
  b.add(jsonEncode({
    'op': 'register',
    'g': 'test-group',
    'id': 'device-B',
    'name': 'Windows PC',
    'platform': 'windows',
    'pub': 'pubB',
  }));

  Future<void> waitFor(List<Map<String, dynamic>> sink, int count) async {
    for (var i = 0; i < 50 && sink.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  await waitFor(aMsgs, 3); // registered + presence(1) + presence(2)
  await waitFor(bMsgs, 2); // registered + presence(2)

  a.add(jsonEncode({'op': 'route', 'to': 'device-B', 'e': {'t': 'ping'}}));
  await waitFor(bMsgs, 3);

  var ok = true;
  final presence = aMsgs.where((m) => m['op'] == 'presence').last;
  final peers = (presence['peers'] as List).map((p) => p['id']).toList()
    ..sort();
  if ('${peers}' != '[device-A, device-B]') {
    ok = false;
    print('FAIL presence: $presence');
  }
  final routed = bMsgs.where((m) => m['op'] == 'route').toList();
  if (routed.isEmpty || routed.first['from'] != 'device-A') {
    ok = false;
    print('FAIL route: $routed');
  }

  print(ok ? 'ALL TESTS PASSED' : 'TESTS FAILED');
  await a.close();
  await b.close();
  exit(ok ? 0 : 1);
}
