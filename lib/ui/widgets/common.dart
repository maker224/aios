import 'package:aios/core/models.dart';
import 'package:aios/util/format.dart';
import 'package:flutter/material.dart';

/// Rounded surface card used across all screens.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

/// A settings-style row with a switch.
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: icon == null ? null : Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class PlatformIcon extends StatelessWidget {
  const PlatformIcon(this.platform, {super.key, this.size = 24});

  final PeerPlatform platform;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (platform) {
      PeerPlatform.android => (Icons.phone_android, Colors.green),
      PeerPlatform.ios => (Icons.phone_iphone, Colors.blueGrey),
      PeerPlatform.macos => (Icons.laptop_mac, Colors.indigo),
      PeerPlatform.windows => (Icons.laptop_windows, Colors.blue),
      PeerPlatform.unknown => (Icons.devices, scheme.outline),
    };
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withValues(alpha: 0.12),
      child: Icon(icon, size: size * 0.6, color: color),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.online, this.size = 10});

  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? Colors.green : Colors.grey,
      ),
    );
  }
}

String statusText(PeerStatus status) {
  if (!status.online) {
    return status.lastSeen == null
        ? 'Offline'
        : 'Last seen ${formatAgo(status.lastSeen!)}';
  }
  return status.via == PeerLinkType.local
      ? 'Online · local network'
      : 'Online · relay';
}

/// Modal dialog to pick one paired, online peer.
Future<String?> showPeerPicker(
  BuildContext context, {
  required List<Peer> peers,
  required bool Function(Peer) online,
  String? title,
}) {
  final onlinePeers = peers.where(online).toList();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? 'Send to device'),
      content: SizedBox(
        width: 320,
        child: onlinePeers.isEmpty
            ? const EmptyState(
                icon: Icons.wifi_off, text: 'No online paired devices.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final p in onlinePeers)
                    ListTile(
                      leading: PlatformIcon(p.platform),
                      title: Text(p.name),
                      subtitle: Text(platformLabel(p.platform)),
                      onTap: () => Navigator.pop(ctx, p.id),
                    ),
                ],
              ),
      ),
    ),
  );
}
