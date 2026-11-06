import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:libreshare_core/libreshare_core.dart'
    show IdentityLostException;

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';

/// Width from which the navigation moves from a bottom bar to a side rail
/// (Material "expanded" window class starts at 840).
const double kRailBreakpoint = 840;

/// Adaptive frame around Home and Settings: a [NavigationRail] on wide
/// (desktop) windows, a [NavigationBar] on narrow ones. Also the engine gate:
/// a spinner while the engine starts, an error page with Retry if it cannot.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    if (engine.hasError && !engine.isLoading) {
      return _StartFailed(
        identityLost: engine.error is IdentityLostException,
        onRetry: () => ref.invalidate(engineProvider),
      );
    }
    if (!engine.hasValue) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: tr('shell.starting'),
            child: const CircularProgressIndicator(key: Key('engine-loading')),
          ),
        ),
      );
    }

    final destinations = <({IconData icon, IconData selected, String label})>[
      (
        icon: Icons.radar_outlined,
        selected: Icons.radar,
        label: tr('nav.nearby'),
      ),
      (
        icon: Icons.settings_outlined,
        selected: Icons.settings,
        label: tr('nav.settings'),
      ),
    ];
    void select(int i) =>
        shell.goBranch(i, initialLocation: i == shell.currentIndex);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kRailBreakpoint;
        final loading = engine.isLoading;
        final body = Column(
          children: [
            if (loading)
              const LinearProgressIndicator(key: Key('engine-restarting')),
            Expanded(child: shell),
          ],
        );
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  key: const Key('nav-rail'),
                  selectedIndex: shell.currentIndex,
                  onDestinationSelected: select,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            key: const Key('nav-bar'),
            selectedIndex: shell.currentIndex,
            onDestinationSelected: select,
            destinations: [
              for (final d in destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StartFailed extends StatelessWidget {
  const _StartFailed({required this.onRetry, this.identityLost = false});

  final bool identityLost;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 56,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                tr(identityLost ? 'shell.failedIdentity' : 'shell.failed'),
                key: const Key('engine-failed'),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: Text(tr('common.retry'))),
            ],
          ),
        ),
      ),
    );
  }
}
