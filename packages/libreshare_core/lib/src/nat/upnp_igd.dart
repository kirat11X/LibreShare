// UPnP IGD SOAP client for Increment 5b port mapping.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'port_mapping.dart';

class UpnpIgdClient {
  UpnpIgdClient({
    required this.controlUrl,
    this.serviceType = 'urn:schemas-upnp-org:service:WANIPConnection:1',
  });

  final Uri controlUrl;
  final String serviceType;

  /// Retrieves the external public IP address from the IGD gateway.
  Future<String?> getExternalIpAddress({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final body =
        '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetExternalIPAddress xmlns:u="$serviceType"/>
  </s:Body>
</s:Envelope>''';

    final resp = await _sendSoap('GetExternalIPAddress', body, timeout);
    if (resp == null) return null;
    return _extractTag(resp, 'NewExternalIPAddress');
  }

  /// Adds a port mapping on the IGD gateway.
  /// If 718 (ConflictInMappingEntry) occurs, tries incrementing externalPort up to 5 times.
  /// If 725 (OnlyPermanentLeasesSupported) occurs, retries with lease = 0.
  Future<PortMapping?> addPortMapping({
    required int internalPort,
    int? externalPort,
    String? internalClient,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
    String description = 'LibreShare',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final clientIp = internalClient ?? '192.168.1.100'; // Fallback
    var targetExtPort = externalPort ?? internalPort;
    var targetLease = lease.inSeconds;

    for (var attempt = 0; attempt < 5; attempt++) {
      final body =
          '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:AddPortMapping xmlns:u="$serviceType">
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>$targetExtPort</NewExternalPort>
      <NewProtocol>${protocol.wireValue}</NewProtocol>
      <NewInternalPort>$internalPort</NewInternalPort>
      <NewInternalClient>$clientIp</NewInternalClient>
      <NewEnabled>1</NewEnabled>
      <NewPortMappingDescription>$description</NewPortMappingDescription>
      <NewLeaseDuration>$targetLease</NewLeaseDuration>
    </u:AddPortMapping>
  </s:Body>
</s:Envelope>''';

      final resp = await _sendSoap('AddPortMapping', body, timeout);
      if (resp != null) {
        if (resp.contains('AddPortMappingResponse')) {
          final extIp =
              await getExternalIpAddress(timeout: timeout) ?? '0.0.0.0';
          return PortMapping(
            internalPort: internalPort,
            externalPort: targetExtPort,
            externalIp: extIp,
            protocol: protocol,
            leaseDuration: Duration(seconds: targetLease),
            createdAt: DateTime.now(),
            description: description,
          );
        }

        // Check SOAP fault errors
        final errCodeStr = _extractTag(resp, 'errorCode');
        final errCode = int.tryParse(errCodeStr ?? '');

        if (errCode == 718) {
          // Conflict: try next port
          targetExtPort++;
          continue;
        } else if (errCode == 725 && targetLease > 0) {
          // Only permanent leases supported: retry with 0
          targetLease = 0;
          continue;
        }
      }
      return null;
    }
    return null;
  }

  /// Deletes a port mapping from the gateway.
  Future<bool> deletePortMapping({
    required int externalPort,
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final body =
        '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:DeletePortMapping xmlns:u="$serviceType">
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>$externalPort</NewExternalPort>
      <NewProtocol>${protocol.wireValue}</NewProtocol>
    </u:DeletePortMapping>
  </s:Body>
</s:Envelope>''';

    final resp = await _sendSoap('DeletePortMapping', body, timeout);
    return resp != null && resp.contains('DeletePortMappingResponse');
  }

  Future<String?> _sendSoap(
    String action,
    String xmlBody,
    Duration timeout,
  ) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final req = await client.postUrl(controlUrl).timeout(timeout);
      req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      req.headers.add('SOAPACTION', '"$serviceType#$action"');
      req.write(xmlBody);

      final resp = await req.close().timeout(timeout);
      final bytes = await resp.fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk),
      );
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  static String? _extractTag(String xml, String tag) {
    final start = xml.indexOf('<$tag>');
    final end = xml.indexOf('</$tag>');
    if (start != -1 && end != -1 && end > start) {
      return xml.substring(start + tag.length + 2, end).trim();
    }
    return null;
  }
}
