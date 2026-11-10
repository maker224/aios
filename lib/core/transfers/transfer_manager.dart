import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aios/core/activity.dart';
import 'package:aios/core/constants.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/net/connection_manager.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Sends and receives files/photos between paired devices.
///
/// Flow (sender -> receiver):
///   file_offer -> file_offer_ack -> file_chunk* -> file_ack* ->
///   file_complete -> file_done
///
/// Chunks are streamed sequentially (send next chunk after ack) for simple,
/// reliable flow control on both LAN and relay connections.
class TransferManager extends ChangeNotifier {
  TransferManager(this.manager, this.settings, this.activity);

  final ConnectionManager manager;
  final SettingsController settings;
  final ActivityLog activity;

  final Map<String, TransferItem> items = {};
  final Map<String, _ReceiveState> _receiving = {};
  final Map<String, Completer<Map<String, dynamic>>> _waiters = {};

  Directory get _tmpDir {
    final d = Directory('${AppStore.dataDir.path}${Platform.pathSeparator}tmp');
    d.createSync(recursive: true);
    return d;
  }

  void attach() {
    manager.on(K.msgFileOffer, _onOffer);
    manager.on(K.msgFileOfferAck, _onOfferAck);
    manager.on(K.msgFileChunk, _onChunk);
    manager.on(K.msgFileAck, _onChunkAck);
    manager.on(K.msgFileComplete, _onComplete);
    manager.on(K.msgFileDone, _onDone);
  }

  List<TransferItem> get active =>
      items.values.where((t) => t.status != TransferStatus.done).toList();

  // ---------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------

  Future<void> sendFiles(
    String peerId,
    List<File> files, {
    String category = 'file',
  }) async {
    for (final file in files) {
      await _sendOne(peerId, file, category);
      if (!manager.reachable(peerId)) break;
    }
  }

  Future<void> _sendOne(String peerId, File file, String category) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final peerName = manager.peerStore.byId(peerId)?.name ?? peerId;
    final size = await file.length();
    final name = _baseName(file.path);

    final item = TransferItem(
      id: id,
      peerId: peerId,
      peerName: peerName,
      name: name,
      size: size,
      direction: TransferDirection.send,
      category: category,
    );
    items[id] = item;
    notifyListeners();

    try {
      item.status = TransferStatus.hashing;
      notifyListeners();
      final sha = await sha256OfFile(file.path);

      item.status = TransferStatus.offering;
      notifyListeners();
      final ok = await manager.send(peerId, K.msgFileOffer, {
        'tid': id,
        'name': name,
        'size': size,
        'sha': sha,
        'cat': category,
      });
      if (!ok) throw 'peer unreachable';
      final ack = await _waitFor(id,
          K.msgFileOfferAck, const Duration(seconds: 20));
      if (ack['accept'] != true) {
        throw ack['reason'] as String? ?? 'declined';
      }

      item.status = TransferStatus.sending;
      notifyListeners();
      final raf = await file.open();
      const chunkSize = K.chunkSize;
      var seq = 0;
      while (true) {
        final bytes = await raf.read(chunkSize);
        if (bytes.isEmpty) break;
        final last = bytes.length < chunkSize;
        final sent = await manager.send(peerId, K.msgFileChunk, {
          'tid': id,
          'seq': seq,
          'd': base64Encode(bytes),
          'l': last,
        });
        if (!sent) throw 'connection lost';
        final ack = await _waitFor(
            id, '${K.msgFileAck}:$seq', const Duration(seconds: 60));
        if (ack['ok'] != true) throw 'chunk not acknowledged';
        item.bytesDone += bytes.length;
        if (seq % 8 == 0) notifyListeners();
        seq++;
        if (last) break;
      }
      await raf.close();

      item.status = TransferStatus.verifying;
      notifyListeners();
      await manager.send(peerId, K.msgFileComplete, {
        'tid': id,
        'sha': sha,
      });
      final done = await _waitFor(
          id, K.msgFileDone, const Duration(seconds: 120));
      if (done['ok'] != true) {
        throw done['error'] as String? ?? 'receiver rejected the file';
      }
      item.status = TransferStatus.done;
      item.bytesDone = size;
      notifyListeners();
      activity.add('📤', 'Sent $name to $peerName', formatSize(size));
    } catch (e) {
      item.status = TransferStatus.failed;
      item.error = '$e';
      notifyListeners();
      activity.add('⚠️', 'Failed to send $name to $peerName', '$e');
      _failWaiters(id, '$e');
    }
  }

  Future<Map<String, dynamic>> _waitFor(
      String tid, String event, Duration timeout) async {
    final key = '$event|$tid';
    final c = Completer<Map<String, dynamic>>();
    _waiters[key] = c;
    try {
      return await c.future.timeout(timeout, onTimeout: () {
        _waiters.remove(key);
        throw TimeoutException('timed out');
      });
    } catch (e) {
      _waiters.remove(key);
      rethrow;
    }
  }

  void _failWaiters(String tid, String reason) {
    for (final entry in _waiters.entries.toList()) {
      if (entry.key.endsWith('|$tid')) {
        if (!entry.value.isCompleted) entry.value.complete({'ok': false});
        _waiters.remove(entry.key);
      }
    }
  }

  void _completeWaiter(String tid, String event, Map<String, dynamic> value) {
    final key = '$event|$tid';
    final c = _waiters.remove(key);
    if (c != null && !c.isCompleted) c.complete(value);
  }

  // ---------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------

  Future<void> _onOffer(Map<String, dynamic> payload, String from) async {
    final tid = payload['tid'] as String? ?? '';
    if (tid.isEmpty) return;
    final peerName = manager.peerStore.byId(from)?.name ?? from;

    if (!settings.syncFiles) {
      await manager.send(from, K.msgFileOfferAck, {
        'tid': tid,
        'accept': false,
        'reason': 'receiver disabled file sync',
      });
      return;
    }

    if (!settings.receiveFiles) {
      await manager.send(from, K.msgFileOfferAck,
          {'tid': tid, 'accept': false, 'reason': 'receiver is not accepting files'});
      return;
    }

    final item = TransferItem(
      id: tid,
      peerId: from,
      peerName: peerName,
      name: payload['name'] as String? ?? 'file',
      size: payload['size'] as int? ?? 0,
      direction: TransferDirection.receive,
      category: payload['cat'] as String? ?? 'file',
    )..status = TransferStatus.receiving;
    items[tid] = item;
    _receiving[tid] = _ReceiveState(
      item: item,
      peerId: from,
      sink: File('${_tmpDir.path}${Platform.pathSeparator}$tid.part')
          .openWrite(),
      expectedSha: payload['sha'] as String? ?? '',
    );
    notifyListeners();
    await manager.send(from, K.msgFileOfferAck, {'tid': tid, 'accept': true});
  }

  Future<void> _onChunk(Map<String, dynamic> payload, String from) async {
    final tid = payload['tid'] as String? ?? '';
    final state = _receiving[tid];
    if (state == null) return;
    try {
      final bytes = base64Decode(payload['d'] as String? ?? '');
      state.sink.add(bytes);
      state.item.bytesDone += bytes.length;
      final seq = payload['seq'] as int? ?? 0;
      if (seq % 8 == 0) notifyListeners();
      await manager.send(from, K.msgFileAck,
          {'tid': tid, 'seq': seq, 'ok': true});
      if (payload['l'] == true) {
        await state.sink.close();
        _receiving.remove(tid);
        // Verification happens when file_complete arrives.
      }
    } catch (e) {
      await _abortReceive(tid, '$e');
    }
  }

  Future<void> _onComplete(Map<String, dynamic> payload, String from) async {
    final tid = payload['tid'] as String? ?? '';
    final item = items[tid];
    if (item == null) return;
    try {
      // Close the receive sink if the sender never sent a `last` chunk
      // (empty file or size that is an exact multiple of the chunk size).
      final state = _receiving.remove(tid);
      if (state != null) {
        try {
          await state.sink.close();
        } catch (_) {}
      }
      item.status = TransferStatus.verifying;
      notifyListeners();
      final tmp = File('${_tmpDir.path}${Platform.pathSeparator}$tid.part');
      final sha = await sha256OfFile(tmp.path);
      if (sha != payload['sha']) {
        throw 'checksum mismatch';
      }
      final dest = _destinationPath(
          item.peerName, item.name, item.category);
      File(dest).parent.createSync(recursive: true);
      await tmp.rename(dest);
      item.status = TransferStatus.done;
      item.bytesDone = item.size;
      notifyListeners();
      activity.add('📥', 'Received ${item.name} from ${item.peerName}',
          formatSize(item.size));
      await manager.send(from, K.msgFileDone, {'tid': tid, 'ok': true});
    } catch (e) {
      await _abortReceive(tid, '$e');
      await manager.send(from,
          K.msgFileDone, {'tid': tid, 'ok': false, 'error': '$e'});
    }
  }

  Future<void> _abortReceive(String tid, String reason) async {
    final state = _receiving.remove(tid);
    try {
      await state?.sink.close();
    } catch (_) {}
    final item = items[tid];
    if (item != null && item.status != TransferStatus.done) {
      item.status = TransferStatus.failed;
      item.error = reason;
      notifyListeners();
    }
  }

  String _destinationPath(String fromName, String name, String category) {
    final dir = category == 'photo'
        ? 'Photos${Platform.pathSeparator}${_safe(fromName)}'
        : _safe(fromName);
    final base = Directory(
        '${AppStore.syncedDir.path}${Platform.pathSeparator}$dir');
    base.createSync(recursive: true);
    var candidate =
        '${base.path}${Platform.pathSeparator}${_safe(name)}';
    if (!File(candidate).existsSync()) return candidate;
    final dot = candidate.lastIndexOf('.');
    final stem = dot > 0 ? candidate.substring(0, dot) : candidate;
    final ext = dot > 0 ? candidate.substring(dot) : '';
    var i = 1;
    while (File('$stem ($i)$ext').existsSync()) {
      i++;
    }
    return '$stem ($i)$ext';
  }

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

  static String _baseName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? 'file' : parts.last;
  }

  // ---------------------------------------------------------------------
  // Sender-side notifications
  // ---------------------------------------------------------------------

  void _onOfferAck(Map<String, dynamic> payload, String from) {
    final tid = payload['tid'] as String? ?? '';
    _completeWaiter(tid, K.msgFileOfferAck, payload);
  }

  void _onChunkAck(Map<String, dynamic> payload, String from) {
    final tid = payload['tid'] as String? ?? '';
    final seq = payload['seq'] as int? ?? -1;
    _completeWaiter(tid, '${K.msgFileAck}:$seq', payload);
  }

  void _onDone(Map<String, dynamic> payload, String from) {
    final tid = payload['tid'] as String? ?? '';
    _completeWaiter(tid, K.msgFileDone, payload);
  }

  // ---------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------

  Future<void> cancel(String tid) async {
    final item = items[tid];
    if (item == null) return;
    if (item.direction == TransferDirection.send) {
      _failWaiters(tid, 'cancelled');
    } else {
      await _abortReceive(tid, 'cancelled');
    }
    item.status = TransferStatus.failed;
    item.error = 'cancelled';
    notifyListeners();
  }
}

class _ReceiveState {
  _ReceiveState({
    required this.item,
    required this.peerId,
    required this.sink,
    required this.expectedSha,
  });

  final TransferItem item;
  final String peerId;
  final IOSink sink;
  final String expectedSha;
}

Future<String> sha256OfFile(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
