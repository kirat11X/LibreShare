// Default reachability probe implementation for Increment 5b.

import 'dart:io';

import 'reachability_probe.dart';

class ReachabilityProbeImpl implements ReachabilityProbe {
  const ReachabilityProbeImpl();

  @override
  Future<bool> probe({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
