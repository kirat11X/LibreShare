import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n_strings.dart';
import 'providers/router_provider.dart';
import 'providers/shell_provider.dart';
import 'widgets/app_theme.dart';
import 'widgets/incoming_host.dart';

/// The app: Material 3 light/dark themes, the router, the consent dialog host
/// and the tray/window bridge.
class LibreShareApp extends ConsumerStatefulWidget {
  const LibreShareApp({super.key});

  @override
  ConsumerState<LibreShareApp> createState() => _LibreShareAppState();
}

class _LibreShareAppState extends ConsumerState<LibreShareApp> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(shellBridgeProvider).start());
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: tr('app.title'),
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          IncomingHost(child: child ?? const SizedBox.shrink()),
    );
  }
}
