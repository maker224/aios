import 'package:aios/core/constants.dart';
import 'package:aios/core/models.dart';
import 'package:aios/core/storage/app_store.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:aios/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final activity = ref.watch(activityProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Options',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),

          // What to sync
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What to sync', style: theme.textTheme.titleMedium),
                ToggleRow(
                  icon: Icons.folder_copy_outlined,
                  title: 'Files & photos',
                  subtitle: 'Send and receive files and photos.',
                  value: settings.syncFiles,
                  onChanged: (v) => settings.syncFiles = v,
                ),
                ToggleRow(
                  icon: Icons.contacts_outlined,
                  title: 'Contacts',
                  subtitle:
                      'Two-way contact sync (Android, iOS, macOS).',
                  value: settings.syncContacts,
                  onChanged: (v) => settings.syncContacts = v,
                ),
                ToggleRow(
                  icon: Icons.calendar_month_outlined,
                  title: 'Calendar events',
                  subtitle:
                      'Sync the "AIoS Synced" calendar (Android, iOS).',
                  value: settings.syncCalendars,
                  onChanged: (v) => settings.syncCalendars = v,
                ),
                ToggleRow(
                  icon: Icons.content_copy_outlined,
                  title: 'Clipboard',
                  subtitle: 'Auto-share copied text with your devices.',
                  value: settings.clipboardSync,
                  onChanged: (v) => settings.clipboardSync = v,
                ),
                ToggleRow(
                  icon: Icons.sticky_note_2_outlined,
                  title: 'Notes',
                  subtitle: 'Quick notes shared across devices.',
                  value: settings.syncNotes,
                  onChanged: (v) => settings.syncNotes = v,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // How devices connect
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How devices connect',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Wi-Fi only'),
                      icon: Icon(Icons.wifi),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Wi-Fi + Relay'),
                      icon: Icon(Icons.cloud_outlined),
                    ),
                  ],
                  selected: {settings.useRelay},
                  onSelectionChanged: (s) => settings.useRelay = s.first,
                ),
                const SizedBox(height: 16),
                if (settings.useRelay) ...[
                  _SettingsTextField(
                    label: 'Sync group id',
                    initial: settings.groupId,
                    helper: 'Devices with the same group id can see each '
                        'other through the relay. Keep it private.',
                    onSaved: (v) => settings.groupId = v,
                  ),
                  const SizedBox(height: 12),
                  _SettingsTextField(
                    label: 'Relay URL (WebSocket)',
                    initial: settings.relayUrl,
                    helper: 'Point this at your relay deployment '
                        '(server/relay), e.g. wss://relay.example.com/ws.',
                    onSaved: (v) => settings.relayUrl = v,
                  ),
                  const SizedBox(height: 12),
                ],
                _SettingsTextField(
                  label: 'Local sync port',
                  initial: '${settings.port}',
                  keyboardType: TextInputType.number,
                  helper: 'Port for direct device-to-device sync on your '
                      'Wi-Fi network.',
                  onSaved: (v) =>
                      settings.port = int.tryParse(v) ?? K.defaultPort,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // This device
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This device', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                _SettingsTextField(
                  label: 'Device name',
                  initial: settings.deviceName,
                  onSaved: (v) => settings.deviceName = v,
                ),
                const SizedBox(height: 12),
                _ReadOnlyRow(
                  label: 'Platform',
                  value: platformLabel(currentPlatform()),
                ),
                _ReadOnlyRow(
                  label: 'Device id',
                  value: settings.deviceId,
                  copyable: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Privacy
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Privacy', style: theme.textTheme.titleMedium),
                ToggleRow(
                  title: 'Accept incoming files',
                  subtitle:
                      'Paired devices can send files/photos to this device.',
                  value: settings.receiveFiles,
                  onChanged: (v) => settings.receiveFiles = v,
                ),
                Text(
                  'All traffic is end-to-end encrypted with keys derived '
                  'during pairing. The relay only forwards encrypted data.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Storage
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Storage', style: theme.textTheme.titleMedium),
                _ReadOnlyRow(
                  label: 'App data folder',
                  value: AppStore.dataDir.path,
                  copyable: true,
                ),
                _ReadOnlyRow(
                  label: 'Received files',
                  value: AppStore.syncedDir.path,
                  copyable: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // About
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About', style: theme.textTheme.titleMedium),
                _ReadOnlyRow(
                    label: 'Version', value: 'v${K.appVersion}'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Clear activity log?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel')),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) activity.clear();
                  },
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear activity log'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SettingsTextField extends StatelessWidget {
  const _SettingsTextField({
    required this.label,
    required this.initial,
    required this.onSaved,
    this.helper,
    this.keyboardType,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onSaved;
  final String? helper;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(text: initial);
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        suffixIcon: IconButton(
          tooltip: 'Save',
          icon: const Icon(Icons.check),
          onPressed: () => onSaved(controller.text.trim()),
        ),
      ),
      onSubmitted: (v) => onSaved(v.trim()),
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
          if (copyable)
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')));
              },
            ),
        ],
      ),
    );
  }
}
