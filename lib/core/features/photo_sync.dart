import 'dart:io';

import 'package:aios/core/net/connection_manager.dart';
import 'package:aios/core/transfers/transfer_manager.dart';
import 'package:aios/state/settings_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

/// Photo library access + sending photos to peers.
///
/// On mobile the platform photo library is used (photo_manager). On desktop,
/// photos can also be picked as regular files (see the Photos screen).
class PhotoSyncService extends ChangeNotifier {
  PhotoSyncService(this.transfers, this.settings, this.manager);

  final TransferManager transfers;
  final SettingsController settings;
  final ConnectionManager manager;

  bool _running = false;
  PermissionState? _permission;
  bool libraryBroken = false;

  Future<bool> ensurePermission() async {
    if (libraryBroken) return false;
    if (_permission?.hasAccess ?? false) return true;
    try {
      _permission = await PhotoManager.requestPermissionExtend();
      return _permission?.hasAccess ?? false;
    } catch (e) {
      debugPrint('photos: library unavailable: $e');
      libraryBroken = true;
      return false;
    }
  }

  /// Recent photos from the platform library (newest first).
  Future<List<AssetEntity>> recentAssets({int count = 60}) async {
    if (!await ensurePermission()) return const [];
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (paths.isEmpty) return const [];
      final page = await paths.first.getAssetListPaged(page: 0, size: count);
      return page.where((a) => a.type == AssetType.image).toList();
    } catch (e) {
      debugPrint('photos: list failed: $e');
      return const [];
    }
  }

  Future<void> sendAssets(String peerId, List<AssetEntity> assets) async {
    final files = <File>[];
    for (final a in assets) {
      final f = await a.file;
      if (f != null && f.existsSync()) files.add(f);
    }
    if (files.isEmpty) return;
    await transfers.sendFiles(peerId, files, category: 'photo');
  }

  /// Sends photos created since the last auto-sync checkpoint to the
  /// selected peers. Best-effort: only runs while the app is open.
  Future<void> autoCheck() async {
    if (_running || !settings.photoAutoSync || !settings.syncFiles) return;
    final peers = settings.photoAutoPeers;
    if (peers.isEmpty) return;
    _running = true;
    try {
      final assets = await recentAssets(count: 50);
      if (assets.isEmpty) return;
      final last = settings.lastSyncOf('photos');
      final lastDt = DateTime.fromMillisecondsSinceEpoch(last == 0
          ? DateTime.now()
              .subtract(const Duration(hours: 24))
              .millisecondsSinceEpoch
          : last);
      final fresh = assets.where((a) {
        return a.createDateTime.isAfter(lastDt);
      }).toList();
      if (fresh.isEmpty) {
        settings.setLastSync('photos', DateTime.now());
        return;
      }
      for (final peerId in peers) {
        if (!manager.reachable(peerId)) continue;
        await sendAssets(peerId, fresh.take(10).toList());
      }
      settings.setLastSync('photos', DateTime.now());
    } catch (e) {
      debugPrint('photos: auto sync failed: $e');
    } finally {
      _running = false;
    }
  }
}
