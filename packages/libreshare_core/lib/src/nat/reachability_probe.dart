// Reachability probe interface for Increment 5b direct path validation.

abstract interface class ReachabilityProbe {
  /// Probes whether [host] and [port] are reachable from external perspectives.
  Future<bool> probe({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  });
}
