import 'dart:async';

import 'package:aios/core/constants.dart';
import 'package:aios/core/net/connection_manager.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/screens/data_screen.dart';
import 'package:aios/ui/screens/dashboard_screen.dart';
import 'package:aios/ui/screens/devices_screen.dart';
import 'package:aios/ui/screens/files_screen.dart';
import 'package:aios/ui/screens/settings_screen.dart';
import 'package:aios/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _pairingDialogOpen = false;
  final Map<int, Widget> _built = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start network stack after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(connectionManagerProvider).start();
      // Instantiate the clipboard watcher right away (it registers an
      // apply handler and starts polling).
      ref.read(clipboardProvider);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResume());
    }
  }

  Future<void> _onResume() async {
    final settings = ref.read(settingsProvider);
    final manager = ref.read(connectionManagerProvider);
    final engine = ref.read(syncEngineProvider);
    final contacts = ref.read(contactSyncProvider);
    final calendars = ref.read(calendarSyncProvider);
    final photos = ref.read(photoSyncProvider);
    final clipboard = ref.read(clipboardProvider);

    manager.discovery.scan();
    engine.flushAll();
    unawaited(clipboard.tick());
    unawaited(photos.autoCheck());
    if (settings.syncContacts) unawaited(contacts.syncNow());
    if (settings.syncCalendars) unawaited(calendars.syncNow());
  }

  void _showPairingDialog() {
    if (!mounted) return;
    _pairingDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PairingDialog(),
    ).whenComplete(() => _pairingDialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    // Show the pairing dialog whenever a pairing handshake starts.
    ref.listen<ConnectionManager>(connectionManagerProvider, (prev, next) {
      final pairing = next.activePairing ?? next.lastPairing;
      if (pairing != null &&
          pairing.result == 'pending' &&
          !_pairingDialogOpen) {
        _showPairingDialog();
      }
    });

    final wide = MediaQuery.sizeOf(context).width >= 960;
    const pages = [
      DashboardScreen(),
      DevicesScreen(),
      FilesScreen(),
      DataScreen(),
      SettingsScreen(),
    ];

    return Scaffold(
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: Text('Home')),
                NavigationRailDestination(
                    icon: Icon(Icons.devices_outlined),
                    selectedIcon: Icon(Icons.devices),
                    label: Text('Devices')),
                NavigationRailDestination(
                    icon: Icon(Icons.folder_copy_outlined),
                    selectedIcon: Icon(Icons.folder_copy),
                    label: Text('Files')),
                NavigationRailDestination(
                    icon: Icon(Icons.sync_outlined),
                    selectedIcon: Icon(Icons.sync),
                    label: Text('Sync Data')),
                NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('Options')),
              ],
            ),
          Expanded(
            // Lazy-build pages so unused tabs (e.g. the photo library)
            // don't request permissions until they are opened.
            child: _built.putIfAbsent(_index, () => pages[_index]),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Home'),
                NavigationDestination(
                    icon: Icon(Icons.devices_outlined),
                    selectedIcon: Icon(Icons.devices),
                    label: 'Devices'),
                NavigationDestination(
                    icon: Icon(Icons.folder_copy_outlined),
                    selectedIcon: Icon(Icons.folder_copy),
                    label: 'Files'),
                NavigationDestination(
                    icon: Icon(Icons.sync_outlined),
                    selectedIcon: Icon(Icons.sync),
                    label: 'Data'),
                NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Options'),
              ],
            ),
    );
  }
}

/// Modal dialog for the pairing handshake. Rebuilds from the manager state.
class PairingDialog extends ConsumerWidget {
  const PairingDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(connectionManagerProvider);
    final active = manager.activePairing;
    final last = manager.lastPairing;
    final pairing = active ?? last;
    if (pairing == null) return const SizedBox.shrink();

    final finished = active == null;
    final theme = Theme.of(context);

    if (finished) {
      final paired = pairing.result == 'paired';
      return AlertDialog(
        icon: Icon(
          paired ? Icons.check_circle : Icons.cancel,
          color: paired ? Colors.green : theme.colorScheme.error,
          size: 40,
        ),
        title: Text(paired
            ? 'Paired with ${pairing.peerName}'
            : 'Pairing cancelled'),
        content: Text(paired
            ? 'Your devices can now sync with each other.'
            : 'The pairing code was not confirmed.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    }

    final confirmText = pairing.mineInitiated
        ? 'I see this code on the other device'
        : 'Accept pairing';

    return AlertDialog(
      icon: const Icon(Icons.phonelink_lock, size: 40),
      title: Text('Pair with ${pairing.peerName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlatformIcon(pairing.platform),
          const SizedBox(height: 12),
          const Text('Verify this code matches on both devices:'),
          const SizedBox(height: 12),
          SelectableText(
            pairing.code,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 16),
          if (pairing.localAccepted)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('Waiting for the other device…'),
              ],
            )
          else
            Text(
              pairing.mineInitiated
                  ? 'Confirm the same code appears on ${pairing.peerName}.'
                  : '${pairing.peerName} wants to pair with this device.',
              textAlign: TextAlign.center,
            ),
        ],
      ),
      actions: [
        if (!pairing.localAccepted)
          TextButton(
            onPressed: () =>
                ref.read(connectionManagerProvider).confirmPairing(
                      pairing.peerId,
                      false,
                    ),
            child: const Text('Cancel'),
          ),
        if (pairing.localAccepted)
          TextButton(
            onPressed: () =>
                ref.read(connectionManagerProvider).confirmPairing(
                      pairing.peerId,
                      false,
                    ),
            child: const Text('Abort'),
          )
        else
          FilledButton(
            onPressed: () =>
                ref.read(connectionManagerProvider).confirmPairing(
                      pairing.peerId,
                      true,
                    ),
            child: Text(confirmText),
          ),
      ],
    );
  }
}

// Convenience export of the app name for headers.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          K.appName,
          style: theme.textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (subtitle != null)
          Text(subtitle!, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
