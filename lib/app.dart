import 'package:aios/core/constants.dart';
import 'package:aios/state/providers.dart';
import 'package:aios/ui/onboarding.dart';
import 'package:aios/ui/shell.dart';
import 'package:aios/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AIoSApp extends StatelessWidget {
  const AIoSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: K.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const RootRouter(),
    );
  }
}

/// Shows onboarding on first launch, the main shell afterwards.
class RootRouter extends ConsumerWidget {
  const RootRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = ref.watch(settingsProvider.select((s) => s.onboardingDone));
    return done ? const AppShell() : const OnboardingScreen();
  }
}
