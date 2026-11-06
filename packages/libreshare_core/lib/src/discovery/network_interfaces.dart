/// Local interface enumeration behind an interface (for tests and Android).
library;

import 'dart:io';

import '../model/device.dart';

class LocalInterface {
  const LocalInterface({
    required this.name,
    required this.address,
    required this.kind,
  });
  final String name;
  final InternetAddress address; // IPv4 unless includeIpv6
  final String kind; // 'wifi' | 'ethernet' | 'unknown'
  DeviceAddress toDeviceAddress() =>
      DeviceAddress(address.address, iface: kind);
}

abstract interface class NetworkInterfaceProvider {
  Future<List<LocalInterface>> list();
}

class SystemNetworkInterfaceProvider implements NetworkInterfaceProvider {
  const SystemNetworkInterfaceProvider({this.includeLoopback = false});
  final bool includeLoopback;

  static String kindOf(String name) {
    final n = name.toLowerCase();
    if (n.startsWith('wl') ||
        n.contains('wi-fi') ||
        n.contains('wifi') ||
        n.contains('wlan')) {
      return 'wifi';
    }
    if (n.startsWith('en') || n.startsWith('eth') || n.contains('ethernet')) {
      return 'ethernet';
    }
    return 'unknown';
  }

  @override
  Future<List<LocalInterface>> list() async {
    final out = <LocalInterface>[];
    final ifaces = await NetworkInterface.list(
      includeLoopback: includeLoopback,
      type: InternetAddressType.IPv4,
    );
    for (final i in ifaces) {
      for (final a in i.addresses) {
        out.add(LocalInterface(name: i.name, address: a, kind: kindOf(i.name)));
      }
    }
    return out;
  }
}
