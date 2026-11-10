import 'package:aios/core/models.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:aios/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

class DataScreen extends ConsumerWidget {
  const DataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SafeArea(
      child: DefaultTabController(
        length: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Text('Sync Data',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Contacts'),
                Tab(text: 'Calendar'),
                Tab(text: 'Clipboard'),
                Tab(text: 'Notes'),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: [
                  _ContactsTab(),
                  _CalendarTab(),
                  _ClipboardTab(),
                  _NotesTab(),
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
// Contacts
// ---------------------------------------------------------------------------

class _ContactsTab extends ConsumerWidget {
  const _ContactsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final service = ref.watch(contactSyncProvider);

    if (!service.available) {
      return const EmptyState(
        icon: Icons.contacts_outlined,
        text: 'Contact sync is not available on this platform yet.\n'
            'Supported: Android, iOS, macOS.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ToggleRow(
                icon: Icons.contacts,
                title: 'Sync contacts with paired devices',
                value: settings.syncContacts,
                onChanged: (v) => settings.syncContacts = v,
              ),
              const Divider(),
              _StatLine(
                  label: 'Synced records',
                  value: '${service.syncedCount}'),
              _StatLine(
                label: 'Last sync',
                value: service.lastSync == null
                    ? 'Never'
                    : formatAgo(service.lastSync!),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (!service.permissionGranted)
                    FilledButton.icon(
                      onPressed: () async {
                        final ok = await service.ensurePermission();
                        if (ok) await service.syncNow();
                      },
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Grant permission'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () => service.syncNow(),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Contacts you edit on this device are detected on the next sync and '
          'merged onto your other devices. Changes from other devices are '
          'written to the platform contact book.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

class _CalendarTab extends ConsumerWidget {
  const _CalendarTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final service = ref.watch(calendarSyncProvider);

    if (!service.available) {
      return const EmptyState(
        icon: Icons.calendar_month_outlined,
        text: 'Calendar sync is not available on this platform yet.\n'
            'Supported: Android, iOS.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ToggleRow(
                icon: Icons.calendar_month,
                title: 'Sync calendar events',
                subtitle: 'Uses a dedicated "AIoS Synced" calendar.',
                value: settings.syncCalendars,
                onChanged: (v) => settings.syncCalendars = v,
              ),
              const Divider(),
              _StatLine(
                  label: 'Synced events', value: '${service.syncedCount}'),
              _StatLine(
                label: 'Last sync',
                value: service.lastSync == null
                    ? 'Never'
                    : formatAgo(service.lastSync!),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (!service.permissionGranted)
                    FilledButton.icon(
                      onPressed: () async {
                        final ok = await service.ensurePermission();
                        if (ok) await service.syncNow();
                      },
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Grant permission'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () => service.syncNow(),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Events in the "AIoS Synced" calendar are exchanged between paired '
          'devices. Events in other calendars are left untouched.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

class _ClipboardTab extends ConsumerWidget {
  const _ClipboardTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final clipboard = ref.watch(clipboardProvider);
    final peers = ref.watch(peerStoreProvider);
    final history = clipboard.history.take(100).toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppCard(
          child: Column(
            children: [
              ToggleRow(
                icon: Icons.content_copy,
                title: 'Share my clipboard',
                subtitle: 'New clipboard text is sent to paired devices.',
                value: settings.clipboardSync,
                onChanged: (v) => settings.clipboardSync = v,
              ),
              ToggleRow(
                icon: Icons.content_paste,
                title: 'Apply received clipboard',
                subtitle: 'Incoming clipboard text replaces mine.',
                value: settings.applyClipboard,
                onChanged: (v) => settings.applyClipboard = v,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('History', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (history.isEmpty)
          const EmptyState(
              icon: Icons.content_copy,
              text: 'Nothing shared yet.\nCopy something on this device.')
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final r in history)
                  ListTile(
                    dense: true,
                    title: Text(
                      r.data['text'] as String? ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                        '${nameOf(r.deviceId, peers)} · ${formatAgo(r.updatedAt)}'),
                    trailing: IconButton(
                      tooltip: 'Copy again',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () async {
                        await ref
                            .read(clipboardProvider)
                            .copyToClipboard(r.data['text'] as String? ?? '');
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')));
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Notes
// ---------------------------------------------------------------------------

class _NotesTab extends ConsumerWidget {
  const _NotesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final engine = ref.watch(syncEngineProvider);
    final settings = ref.watch(settingsProvider);
    final notes = engine.recordsOf(DataType.note);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    'Quick notes shared with all paired devices.',
                    style: theme.textTheme.bodySmall),
              ),
              IconButton.filled(
                tooltip: 'New note',
                icon: const Icon(Icons.add),
                onPressed: () => _editNote(context, ref),
              ),
            ],
          ),
        ),
        if (!settings.syncNotes)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: AppCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Notes stay on this device only. Enable "Notes" '
                      'in Options to share them.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: notes.isEmpty
              ? const EmptyState(
                  icon: Icons.sticky_note_2_outlined,
                  text: 'No notes yet. Add one — it will appear on\nyour other devices.')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: [
                    for (final n in notes)
                      AppCard(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    n.data['title'] as String? ?? 'Note',
                                    style: theme.textTheme.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 18),
                                  onPressed: () =>
                                      _editNote(context, ref, record: n),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18),
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Delete note?'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel')),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await ref
                                          .read(syncEngineProvider)
                                          .deleteLocal(
                                              DataType.note, n.id);
                                    }
                                  },
                                ),
                              ],
                            ),
                            Text(n.data['text'] as String? ?? ''),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _editNote(BuildContext context, WidgetRef ref,
      {SyncRecord? record}) async {
    final engine = ref.read(syncEngineProvider);
    final titleCtrl =
        TextEditingController(text: record?.data['title'] as String? ?? '');
    final bodyCtrl =
        TextEditingController(text: record?.data['text'] as String? ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(record == null ? 'New note' : 'Edit note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bodyCtrl,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Text'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save != true) return;
    final data = {
      'title': titleCtrl.text.trim().isEmpty
          ? 'Untitled'
          : titleCtrl.text.trim(),
      'text': bodyCtrl.text,
    };
    if (record == null) {
      await engine.putLocal(DataType.note, const Uuid().v4(), data);
    } else {
      await engine.updateLocal(DataType.note, record.id, (_) => data);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

class _StatLine extends StatelessWidget {
  const _StatLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          Text(value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
