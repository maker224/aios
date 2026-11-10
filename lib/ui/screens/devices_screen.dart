import 'package:aios/core/models.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:aios/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(connectionManagerProvider);
    final peers = ref.watch(peerStoreProvider);
    final discovery = ref.watch(discoveryProvider);
    final theme = Theme.of(context);

    final paired = peers.all;
    final nearby = discovery.candidates.values
        .where((c) => peers.byId(c.id) == null)
        .toList();
    final relayPeers = manager.relay.peers.values
        .where((rp) => peers.byId(rp.id) == null)
        .toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Devices',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Pair your devices once; after that they sync automatically.',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),

          Row(
            children: [
              FilledButton.icon(
                onPressed: () => manager.discovery.scan(),
                icon: const Icon(Icons.radar),
                label: const Text('Scan network'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => _manualConnect(context, ref),
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('Connect manually'),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Paired devices
          Text('Paired devices', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (paired.isEmpty)
            const AppCard(
              child: EmptyState(
                icon: Icons.link_off,
                text: 'No paired devices yet.\nUse "Scan network" to find devices nearby.',
              ),
            )
          else
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final p in paired)
                    _PairedTile(peer: p, status: peers.statusOf(p.id)),
                ],
              ),
            ),
          const SizedBox(height: 20),

          // Nearby
          Text('Nearby (same Wi-Fi)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (nearby.isEmpty)
            const AppCard(
              child: EmptyState(
                icon: Icons.wifi_find,
                text: 'No unpaired devices found nearby.',
              ),
            )
          else
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final c in nearby)
                    ListTile(
                      leading: PlatformIcon(c.platform),
                      title: Text(c.name),
                      subtitle: Text('${c.address}:${c.port}'),
                      trailing: FilledButton(
                        onPressed: () => manager.connectLocal(
                            c.address, c.port),
                        child: const Text('Pair'),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),

          // Relay group
          Text('Sync group (relay)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            manager.relayConnected
                ? 'Connected to relay · group "${ref.watch(settingsProvider).groupId}"'
                : 'Relay offline. Devices in your sync group will appear here when the relay is reachable.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (relayPeers.isEmpty)
            AppCard(
              child: EmptyState(
                icon: Icons.cloud_off,
                text: manager.relayConnected
                    ? 'No other unpaired devices in your sync group.'
                    : 'Set a relay URL in Settings to sync across the internet.',
              ),
            )
          else
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final rp in relayPeers)
                    ListTile(
                      leading: PlatformIcon(rp.platform),
                      title: Text(rp.name),
                      subtitle: const Text('Online via relay'),
                      trailing: FilledButton(
                        onPressed: () => manager.pairWithRelay(rp.id),
                        child: const Text('Pair'),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _manualConnect(BuildContext context, WidgetRef ref) async {
    final manager = ref.read(connectionManagerProvider);
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '47631');
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect to device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(
                  labelText: 'IP address', hintText: '192.168.1.42'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, hostCtrl.text.trim()),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (host == null || host.isEmpty) return;
    final port = int.tryParse(portCtrl.text) ?? 47631;
    final ok = await manager.connectLocal(host, port);
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Connected to $host — confirm the pairing code on both devices.')));
    }
  }
}

class _PairedTile extends ConsumerWidget {
  const _PairedTile({required this.peer, required this.status});

  final Peer peer;
  final PeerStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      leading: PlatformIcon(peer.platform),
      title: Row(
        children: [
          Flexible(child: Text(peer.name)),
          const SizedBox(width: 8),
          StatusDot(online: status.online),
        ],
      ),
      subtitle: Text(
          '${platformLabel(peer.platform)} · ${statusText(status)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.online)
            IconButton(
              tooltip: 'Sync now',
              icon: const Icon(Icons.sync),
              onPressed: () =>
                  ref.read(syncEngineProvider).beginSync(peer.id),
            ),
          IconButton(
            tooltip: 'Unpair',
            icon: Icon(Icons.delete_outline,
                color: theme.colorScheme.error),
            onPressed: () => _confirmUnpair(context, ref, peer),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUnpair(
      BuildContext context, WidgetRef ref, Peer peer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unpair ${peer.name}?'),
        content: const Text(
            'This device will no longer be able to sync with you.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(connectionManagerProvider).unpair(peer.id);
    }
  }
}
