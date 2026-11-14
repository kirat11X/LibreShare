import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/add_device_screen.dart';
import '../screens/app_shell.dart';
import '../screens/choose_device_screen.dart';
import '../screens/history_screen.dart';
import '../screens/home_screen.dart';
import '../screens/my_qr_screen.dart';
import '../screens/scan_qr_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/transfer_screen.dart';
import '../screens/web_portal_screen.dart';
import 'navigation_provider.dart';

/// Where the app starts (tests override it to open a screen directly).
final initialLocationProvider = Provider<String>((ref) => '/');

/// Routes: Home and Settings live in the adaptive shell (bottom bar or rail);
/// everything else is a full-screen page over it.
final routerProvider = Provider<GoRouter>((ref) {
  final rootKey = ref.watch(rootNavigatorKeyProvider);
  final router = GoRouter(
    navigatorKey: rootKey,
    initialLocation: ref.read(initialLocationProvider),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/send',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const ChooseDeviceScreen(),
      ),
      GoRoute(
        path: '/add',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const AddDeviceScreen(),
      ),
      GoRoute(
        path: '/scan',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const ScanQrScreen(),
      ),
      GoRoute(
        path: '/my-qr',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const MyQrScreen(),
      ),
      GoRoute(
        path: '/history',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const HistoryScreen(),
      ),
      GoRoute(
        path: '/web-portal',
        parentNavigatorKey: rootKey,
        builder: (context, state) => const WebPortalScreen(),
      ),
      GoRoute(
        path: '/transfer/:key',
        parentNavigatorKey: rootKey,
        builder: (context, state) =>
            TransferScreen(transferKey: state.pathParameters['key']!),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
