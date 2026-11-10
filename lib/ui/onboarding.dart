import 'package:aios/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// First-run wizard: the user chooses what to sync and how devices connect.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _relayCtrl;
  late final TextEditingController _groupCtrl;

  late bool _syncFiles;
  late bool _syncContacts;
  late bool _syncCalendars;
  late bool _syncClipboard;
  late bool _syncNotes;
  late bool _useRelay;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _nameCtrl = TextEditingController(text: s.deviceName);
    _relayCtrl = TextEditingController(text: s.relayUrl);
    _groupCtrl = TextEditingController(text: s.groupId);
    _syncFiles = s.syncFiles;
    _syncContacts = s.syncContacts;
    _syncCalendars = s.syncCalendars;
    _syncClipboard = s.clipboardSync;
    _syncNotes = s.syncNotes;
    _useRelay = s.useRelay;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameCtrl.dispose();
    _relayCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  void _finish() {
    final s = ref.read(settingsProvider);
    s.deviceName = _nameCtrl.text;
    s.syncFiles = _syncFiles;
    s.syncContacts = _syncContacts;
    s.syncCalendars = _syncCalendars;
    s.clipboardSync = _syncClipboard;
    s.syncNotes = _syncNotes;
    s.useRelay = _useRelay;
    s.relayUrl = _relayCtrl.text;
    s.groupId = _groupCtrl.text;
    s.onboardingDone = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Row(
                    children: [
                      for (var i = 0; i < 2; i++)
                        Container(
                          width: i == _page ? 32 : 8,
                          height: 4,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: i <= _page
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [
                      _buildSyncPage(theme),
                      _buildConnectPage(theme),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    children: [
                      if (_page > 0)
                        TextButton(
                          onPressed: () => _pageController.previousPage(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut),
                          child: const Text('Back'),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _page == 0
                            ? () => _pageController.nextPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut)
                            : _finish,
                        icon: Icon(_page == 0
                            ? Icons.arrow_forward
                            : Icons.check),
                        label: Text(_page == 0 ? 'Next' : 'Get started'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSyncPage(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        Icon(Icons.sync_alt, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('Welcome to AIoS',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Sync your stuff between iPhone, Mac, Android and Windows — '
          'encrypted, private, no account needed.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Name this device',
            hintText: 'e.g. My iPhone',
            helperText: 'This is how this device appears to your others.',
          ),
        ),
        const SizedBox(height: 24),
        Text('What do you want to sync?', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _OptionCheck(
          icon: Icons.folder_copy_outlined,
          title: 'Files & photos',
          subtitle: 'Send files and photos between devices.',
          value: _syncFiles,
          onChanged: (v) => setState(() => _syncFiles = v),
        ),
        _OptionCheck(
          icon: Icons.contacts_outlined,
          title: 'Contacts',
          subtitle: 'Keep contact books in sync (Android, iOS, macOS).',
          value: _syncContacts,
          onChanged: (v) => setState(() => _syncContacts = v),
        ),
        _OptionCheck(
          icon: Icons.calendar_month_outlined,
          title: 'Calendar events',
          subtitle: 'Sync the "AIoS Synced" calendar (Android, iOS).',
          value: _syncCalendars,
          onChanged: (v) => setState(() => _syncCalendars = v),
        ),
        _OptionCheck(
          icon: Icons.content_copy_outlined,
          title: 'Clipboard',
          subtitle: 'Share copied text with your other devices.',
          value: _syncClipboard,
          onChanged: (v) => setState(() => _syncClipboard = v),
        ),
        _OptionCheck(
          icon: Icons.sticky_note_2_outlined,
          title: 'Notes',
          subtitle: 'Quick notes shared across devices.',
          value: _syncNotes,
          onChanged: (v) => setState(() => _syncNotes = v),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildConnectPage(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        Icon(Icons.hub_outlined, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('How should devices connect?',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Devices on the same Wi-Fi always sync directly, device-to-device. '
          'Optionally add a relay so they can also sync from anywhere.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        RadioListTile<bool>(
          value: false,
          groupValue: _useRelay,
          onChanged: (v) => setState(() => _useRelay = v ?? false),
          title: const Text('Wi-Fi only'),
          subtitle: const Text(
              'Devices sync when on the same network. Most private option.'),
          secondary: const Icon(Icons.wifi),
        ),
        RadioListTile<bool>(
          value: true,
          groupValue: _useRelay,
          onChanged: (v) => setState(() => _useRelay = v ?? false),
          title: const Text('Wi-Fi + relay'),
          subtitle: const Text(
              'Also sync over the internet via your relay server. '
              'Still end-to-end encrypted.'),
          secondary: const Icon(Icons.cloud_outlined),
        ),
        if (_useRelay) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _groupCtrl,
            decoration: const InputDecoration(
              labelText: 'Sync group id',
              helperText:
                  'Use the same id on all your devices. Keep it private.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _relayCtrl,
            decoration: const InputDecoration(
              labelText: 'Relay URL (WebSocket)',
              helperText: 'e.g. wss://your-relay.example.com/ws',
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'When two devices first meet, both show a 6-digit pairing code. '
          'Confirm it matches and your data stays encrypted between you — '
          'even the relay only ever forwards ciphertext.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _OptionCheck extends StatelessWidget {
  const _OptionCheck({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
    );
  }
}
