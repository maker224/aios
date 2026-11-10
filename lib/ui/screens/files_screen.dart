import 'dart:io';

import 'package:aios/core/models.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:aios/util/format.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

class FilesScreen extends ConsumerWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Text('Files & Photos',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const TabBar(
              tabs: [
                Tab(text: 'Files'),
                Tab(text: 'Photos'),
                Tab(text: 'Transfers'),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: [
                  _FilesTab(),
                  _PhotosTab(),
                  _TransfersTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

class _ReceivedFile {
  _ReceivedFile(this.path, this.from, this.size, this.modified);
  final String path;
  final String from;
  final int size;
  final DateTime modified;
}

class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab();

  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  List<_ReceivedFile> _files = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final out = <_ReceivedFile>[];
    void walk(Directory dir, String from) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final stat = entity.statSync();
          out.add(
              _ReceivedFile(entity.path, from, stat.size, stat.modified));
        } else if (entity is Directory) {
          walk(entity, entity.uri.pathSegments.last);
        }
      }
    }

    walk(AppStore.syncedDir, '');
    out.sort((a, b) => b.modified.compareTo(a.modified));
    setState(() => _files = out);
  }

  Future<void> _sendFiles() async {
    final peers = ref.read(peerStoreProvider);
    final manager = ref.read(connectionManagerProvider);
    final transfers = ref.read(transferManagerProvider);
    final peerId = await showPeerPicker(
      context,
      peers: peers.all,
      online: (p) => manager.reachable(p.id),
    );
    if (peerId == null || !mounted) return;
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, type: FileType.any);
    if (result == null) return;
    final files = [
      for (final f in result.files)
        if (f.path != null) File(f.path!),
    ];
    if (files.isEmpty) return;
    await transfers.sendFiles(peerId, files, category: 'file');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = AppStore.syncedDir.path;
    final settings = ref.watch(settingsProvider);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (settings.syncFiles)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _sendFiles,
                icon: const Icon(Icons.send),
                label: const Text('Send files'),
              ),
              OutlinedButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          )
        else
          AppCard(
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'File sync is turned off. Enable "Files & photos" '
                    'in Options to send and receive files.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        AppCard(
          child: Row(
            children: [
              const Icon(Icons.folder_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  folder,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Copy path',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: folder));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Folder path copied')));
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
            'Files received from other devices land in this folder, organized by device.',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        if (_files.isEmpty)
          const EmptyState(
              icon: Icons.inbox_outlined,
              text: 'No received files yet.\nSend a file from a paired device.')
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final f in _files)
                  ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(
                        f.path.split(RegExp(r'[/\\]')).last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${f.from.isEmpty ? 'received' : 'from ${f.from}'} · ${formatBytes(f.size)} · ${formatAgo(f.modified)}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Photos
// ---------------------------------------------------------------------------

class _PhotosTab extends ConsumerStatefulWidget {
  const _PhotosTab();

  @override
  ConsumerState<_PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends ConsumerState<_PhotosTab> {
  List<AssetEntity> _assets = [];
  final Set<String> _selected = {};
  bool _libraryAvailable = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final service = ref.read(photoSyncProvider);
    final ok = await service.ensurePermission();
    if (!ok) {
      if (mounted) setState(() => _libraryAvailable = false);
      return;
    }
    final assets = await service.recentAssets(count: 80);
    if (mounted) {
      setState(() {
        _libraryAvailable = assets.isNotEmpty;
        _assets = assets;
      });
    }
  }

  Future<void> _sendSelected() async {
    final peers = ref.read(peerStoreProvider);
    final manager = ref.read(connectionManagerProvider);
    final service = ref.read(photoSyncProvider);
    final peerId = await showPeerPicker(
      context,
      peers: peers.all,
      online: (p) => manager.reachable(p.id),
      title: 'Send photos to device',
    );
    if (peerId == null) return;
    setState(() => _sending = true);
    final chosen = _assets
        .where((a) => _selected.contains(a.id))
        .toList();
    try {
      await service.sendAssets(peerId, chosen);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Sending ${chosen.length} photo(s)…')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickFromDisk() async {
    final peers = ref.read(peerStoreProvider);
    final manager = ref.read(connectionManagerProvider);
    final transfers = ref.read(transferManagerProvider);
    final peerId = await showPeerPicker(
      context,
      peers: peers.all,
      online: (p) => manager.reachable(p.id),
      title: 'Send photos to device',
    );
    if (peerId == null) return;
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, type: FileType.image);
    if (result == null) return;
    final files = [
      for (final f in result.files)
        if (f.path != null) File(f.path!),
    ];
    if (files.isEmpty) return;
    await transfers.sendFiles(peerId, files, category: 'photo');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final peers = ref.watch(peerStoreProvider);

    if (!settings.syncFiles) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          AppCard(
            child: EmptyState(
              icon: Icons.folder_off_outlined,
              text: 'File & photo sync is turned off.\n'
                  'Enable "Files & photos" in Options.',
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_libraryAvailable) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  _selected.isEmpty
                      ? 'Tap photos to select them'
                      : '${_selected.length} selected',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: _selected.isEmpty || _sending
                    ? null
                    : _sendSelected,
                icon: const Icon(Icons.send),
                label: const Text('Send selected'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: _assets.length,
            itemBuilder: (ctx, i) {
              final asset = _assets[i];
              final isSelected = _selected.contains(asset.id);
              return GestureDetector(
                onTap: () => setState(() {
                  if (isSelected) {
                    _selected.remove(asset.id);
                  } else {
                    _selected.add(asset.id);
                  }
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: asset.thumbnailDataWithSize(
                          const ThumbnailSize(200, 200),
                          quality: 70),
                      builder: (ctx, snap) => snap.hasData
                          ? Image.memory(snap.data!, fit: BoxFit.cover)
                          : const ColoredBox(color: Colors.black12),
                    ),
                    if (isSelected)
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: theme.colorScheme.primary, width: 3),
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Icon(Icons.check_circle,
                              color: theme.colorScheme.primary),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
        OutlinedButton.icon(
          onPressed: _pickFromDisk,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(_libraryAvailable
              ? 'Pick photos from disk instead'
              : 'Pick photos from disk'),
        ),
        const SizedBox(height: 20),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Auto-send new photos', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                  'When the app is open, photos taken since the last check are sent automatically.',
                  style: theme.textTheme.bodySmall),
              ToggleRow(
                title: 'Enable auto-send',
                value: settings.photoAutoSync,
                onChanged: (v) => settings.photoAutoSync = v,
              ),
              if (peers.all.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Send to:', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in peers.all)
                      FilterChip(
                        avatar: PlatformIcon(p.platform, size: 18),
                        label: Text(p.name),
                        selected:
                            settings.photoAutoPeers.contains(p.id),
                        onSelected: (_) =>
                            settings.togglePhotoPeer(p.id),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

class _TransfersTab extends ConsumerWidget {
  const _TransfersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final transfers = ref.watch(transferManagerProvider);
    final items = transfers.items.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    if (items.isEmpty) {
      return const EmptyState(
          icon: Icons.swap_vert, text: 'No transfers yet.');
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final t in items)
                ListTile(
                  leading: Icon(
                    t.direction == TransferDirection.send
                        ? Icons.upload_outlined
                        : Icons.download_outlined,
                  ),
                  title: Text(t.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${t.direction == TransferDirection.send ? 'to' : 'from'} ${t.peerName} · ${formatBytes(t.size)} · ${_statusLabel(t.status)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (t.status == TransferStatus.sending ||
                          t.status == TransferStatus.receiving)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LinearProgressIndicator(
                            value: t.size == 0
                                ? null
                                : (t.bytesDone / t.size).clamp(0.0, 1.0),
                          ),
                        ),
                      if (t.error != null)
                        Text(t.error!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                  trailing: _isActive(t.status)
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => transfers.cancel(t.id),
                        )
                      : Icon(
                          t.status == TransferStatus.done
                              ? Icons.check_circle
                              : Icons.error_outline,
                          color: t.status == TransferStatus.done
                              ? Colors.green
                              : theme.colorScheme.error,
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  bool _isActive(TransferStatus s) =>
      s == TransferStatus.hashing ||
      s == TransferStatus.offering ||
      s == TransferStatus.sending ||
      s == TransferStatus.receiving ||
      s == TransferStatus.verifying;

  String _statusLabel(TransferStatus s) => switch (s) {
        TransferStatus.hashing => 'Hashing…',
        TransferStatus.offering => 'Offering…',
        TransferStatus.sending => 'Sending…',
        TransferStatus.receiving => 'Receiving…',
        TransferStatus.verifying => 'Verifying…',
        TransferStatus.done => 'Done',
        TransferStatus.failed => 'Failed',
      };
}
