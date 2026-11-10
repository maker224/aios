import 'package:aios/core/constants.dart';
import 'package:aios/core/models.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:aios/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final manager = ref.watch(connectionManagerProvider);
    final peers = ref.watch(peerStoreProvider);
    final activity = ref.watch(activityProvider);
    final transfers = ref.watch(transferManagerProvider);
    final engine = ref.watch(syncEngineProvider);
    final theme = Theme.of(context);

    final pairedCount = peers.all.length;
    final onlineCount =
        peers.all.where((p) => peers.statusOf(p.id).online).length;
    final activeTransfers = transfers.items.values
        .where((t) =>
            t.status != TransferStatus.done &&
            t.status != TransferStatus.failed)
        .length;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(settings.deviceName,
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text('${K.appName} · v${K.appVersion}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),

          // Status cards
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(
                icon: Icons.devices,
                label: 'Paired devices',
                value: pairedCount.toString(),
              ),
              _StatCard(
                icon: Icons.wifi,
                label: 'Online',
                value: onlineCount.toString(),
              ),
              _StatCard(
                icon: Icons.cloud_outlined,
                label: 'Relay',
                value: manager.relayConnected ? 'Connected' : 'Off',
                color:
                    manager.relayConnected ? Colors.green : Colors.orange,
              ),
              _StatCard(
                icon: Icons.swap_vert,
                label: 'Transfers',
                value: activeTransfers.toString(),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Quick actions
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _syncNow(context, ref),
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
              OutlinedButton.icon(
                onPressed: () => manager.discovery.scan(),
                icon: const Icon(Icons.radar),
                label: const Text('Scan network'),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Feature overview
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Synced data', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                _FeatureLine(
                  icon: Icons.folder_copy_outlined,
                  label: 'Files & photos',
                  detail: settings.syncFiles ? 'On' : 'Off',
                  enabled: settings.syncFiles,
                ),
                _FeatureLine(
                  icon: Icons.contacts,
                  label: 'Contacts',
                  detail: '${engine.recordCount(DataType.contact)} records',
                  enabled: settings.syncContacts,
                ),
                _FeatureLine(
                  icon: Icons.calendar_month,
                  label: 'Calendar',
                  detail: '${engine.recordCount(DataType.calendar)} events',
                  enabled: settings.syncCalendars,
                ),
                _FeatureLine(
                  icon: Icons.content_copy,
                  label: 'Clipboard',
                  detail: settings.clipboardSync ? 'Auto-sync on' : 'Off',
                  enabled: settings.clipboardSync,
                ),
                _FeatureLine(
                  icon: Icons.sticky_note_2_outlined,
                  label: 'Notes',
                  detail: '${engine.recordCount(DataType.note)} notes',
                  enabled: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Recent activity
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Recent activity',
                      style: theme.textTheme.titleMedium),
                ),
                if (activity.entries.isEmpty)
                  const EmptyState(
                      icon: Icons.history, text: 'Nothing yet. Pair a device to get started.')
                else
                  for (final e in activity.entries.take(12))
                    ListTile(
                      dense: true,
                      leading: Text(e.icon,
                          style: const TextStyle(fontSize: 20)),
                      title: Text(e.title),
                      subtitle: e.subtitle == null
                          ? null
                          : Text(e.subtitle!,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(formatAgo(e.ts),
                          style: theme.textTheme.bodySmall),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final settings = ref.read(settingsProvider);
    final engine = ref.read(syncEngineProvider);
    final manager = ref.read(connectionManagerProvider);
    final contacts = ref.read(contactSyncProvider);
    final calendars = ref.read(calendarSyncProvider);

    manager.discovery.scan();
    engine.flushAll();
    if (settings.syncContacts) await contacts.syncNow();
    if (settings.syncCalendars) await calendars.syncNow();
    messenger.showSnackBar(const SnackBar(
        content: Text('Sync started — changes will flow to online devices.'),
        duration: Duration(seconds: 2)));
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 150,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                color: color ?? theme.colorScheme.primary, size: 20),
            const SizedBox(height: 8),
            Text(value,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine({
    required this.icon,
    required this.label,
    required this.detail,
    required this.enabled,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(detail, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
