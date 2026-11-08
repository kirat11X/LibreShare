// SSDP Discovery & XML device parser for Increment 5b UPnP IGD.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ip_classify.dart';

final class SsdpDevice {
  const SsdpDevice({
    required this.location,
    required this.st,
    required this.usn,
    this.server,
    this.controlUrl,
    this.serviceType,
  });

  final Uri location;
  final String st;
  final String usn;
  final String? server;
  final Uri? controlUrl;
  final String? serviceType;

  @override
  String toString() => 'SsdpDevice($location, service: $serviceType)';
}

class SsdpClient {
  SsdpClient({this.allowLoopback = false});

  final bool allowLoopback;

  static const String ssdpMulticastIpv4 = '239.255.255.250';
  static const int ssdpPort = 1900;
  static const int maxXmlBytes = 64 * 1024; // 64 KiB cap per D4

  /// Discovers UPnP IGD devices via SSDP M-SEARCH.
  /// If [unicastTarget] is specified, sends M-SEARCH directly to that address/port.
  Future<List<SsdpDevice>> discover({
    String? unicastHost,
    int? unicastPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? socket;
    final devices = <SsdpDevice>[];
    final seenLocations = <String>{};

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      const mSearch =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n'
          '\r\n';

      final targetHost = unicastHost ?? ssdpMulticastIpv4;
      final targetPort = unicastPort ?? ssdpPort;
      final targetAddress = (await InternetAddress.lookup(targetHost)).first;

      socket.send(utf8.encode(mSearch), targetAddress, targetPort);

      final completer = Completer<void>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null) {
            final text = utf8.decode(dg.data, allowMalformed: true);
            final device = _parseSsdpResponse(text);
            if (device != null &&
                seenLocations.add(device.location.toString())) {
              devices.add(device);
            }
          }
        }
      });

      await Future.any([Future<void>.delayed(timeout), completer.future]);

      await sub.cancel();
    } catch (_) {
      // Best effort discovery
    } finally {
      socket?.close();
    }

    // Resolve control URLs for discovered devices with security hardening
    final resolved = <SsdpDevice>[];
    for (final dev in devices) {
      final enriched = await resolveDeviceDescription(dev.location);
      if (enriched != null) {
        resolved.add(enriched);
      }
    }
    return resolved;
  }

  /// Parses SSDP M-SEARCH response headers.
  SsdpDevice? _parseSsdpResponse(String response) {
    final lines = response.split(RegExp(r'\r?\n'));
    if (lines.isEmpty || !lines[0].toUpperCase().contains('200 OK')) {
      return null;
    }

    String? locationStr;
    String? st;
    String? usn;
    String? server;

    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final key = line.substring(0, colon).trim().toUpperCase();
      final val = line.substring(colon + 1).trim();

      if (key == 'LOCATION') locationStr = val;
      if (key == 'ST') st = val;
      if (key == 'USN') usn = val;
      if (key == 'SERVER') server = val;
    }

    if (locationStr == null || st == null || usn == null) return null;
    final uri = Uri.tryParse(locationStr);
    if (uri == null) return null;

    return SsdpDevice(location: uri, st: st, usn: usn, server: server);
  }

  /// Downloads and parses the device description XML from [location] with D4 security gates.
  Future<SsdpDevice?> resolveDeviceDescription(Uri location) async {
    // Gate 1: Scheme must be HTTP
    if (location.scheme != 'http') return null;

    // Gate 2: Host must be private / link-local / loopback (if allowed)
    final host = location.host;
    final classification = IpClassifier.classify(host);
    if (classification.category == IpCategory.invalid) {
      // Domain names must be resolved or validated
      try {
        final addrs = await InternetAddress.lookup(host);
        if (addrs.isEmpty) return null;
        final addrClass = IpClassifier.classify(addrs.first.address);
        if (!_isAllowedHost(addrClass)) return null;
      } catch (_) {
        return null;
      }
    } else {
      if (!_isAllowedHost(classification)) return null;
    }

    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..autoUncompress = true;

      final request = await client.getUrl(location);
      request.followRedirects = false; // Never follow redirects per D4

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;

      // Gate 3: XML <= 64 KiB
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > maxXmlBytes) {
          // Reject oversize XML per D4
          return null;
        }
      }

      final xml = utf8.decode(bytes, allowMalformed: true);

      // Gate 4: No DTD per D4
      if (xml.contains('<!DOCTYPE') || xml.contains('<!ENTITY')) {
        return null;
      }

      // Extract service WANIPConnection or WANPPPConnection
      final controlPath = _extractServiceControlUrl(xml);
      if (controlPath == null) return null;

      final controlUri = location.resolve(controlPath);

      // Ensure control URL stays on the exact same origin
      if (controlUri.host != location.host ||
          controlUri.port != location.port) {
        return null;
      }

      return SsdpDevice(
        location: location,
        st: 'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
        usn: location.toString(),
        controlUrl: controlUri,
        serviceType: 'urn:schemas-upnp-org:service:WANIPConnection:1',
      );
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  bool _isAllowedHost(IpClassification c) {
    if (c.category == IpCategory.loopback) return allowLoopback;
    return c.category == IpCategory.privateIpv4 ||
        c.category == IpCategory.linkLocal;
  }

  static String? _extractServiceControlUrl(String xml) {
    // Look for WANIPConnection or WANPPPConnection
    var serviceIndex = xml.indexOf(
      'urn:schemas-upnp-org:service:WANIPConnection:1',
    );
    if (serviceIndex == -1) {
      serviceIndex = xml.indexOf(
        'urn:schemas-upnp-org:service:WANPPPConnection:1',
      );
    }
    if (serviceIndex == -1) return null;

    final afterService = xml.substring(serviceIndex);
    final ctrlStart = afterService.indexOf('<controlURL>');
    final ctrlEnd = afterService.indexOf('</controlURL>');
    if (ctrlStart != -1 && ctrlEnd != -1 && ctrlEnd > ctrlStart) {
      return afterService.substring(ctrlStart + 12, ctrlEnd).trim();
    }
    return null;
  }
}
