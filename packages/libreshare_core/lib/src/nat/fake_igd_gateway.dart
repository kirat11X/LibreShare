// Test fake UPnP IGD router for Increment 5b.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeIgdGateway {
  FakeIgdGateway({
    this.externalIp = '203.0.113.1',
    this.conflictPort,
    this.permanentOnly = false,
    this.failAll = false,
    this.oversizeXml = false,
    this.includeDtd = false,
    this.delay = Duration.zero,
  });

  final String externalIp;
  int? conflictPort;
  bool permanentOnly;
  bool failAll;
  bool oversizeXml;
  bool includeDtd;
  Duration delay;

  HttpServer? _server;
  final List<Map<String, dynamic>> _activeMappings = [];

  List<Map<String, dynamic>> get activeMappings =>
      List.unmodifiable(_activeMappings);
  int get port => _server?.port ?? 0;
  Uri get locationUri => Uri.parse('http://127.0.0.1:$port/rootDesc.xml');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    final path = request.uri.path;
    if (request.method == 'GET' && path == '/rootDesc.xml') {
      _serveDeviceDesc(request);
    } else if (request.method == 'POST' && path == '/control/WANIPConnection') {
      await _handleSoapControl(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  void _serveDeviceDesc(HttpRequest request) {
    request.response.headers.contentType = ContentType(
      'text',
      'xml',
      charset: 'utf-8',
    );

    if (oversizeXml) {
      final bigPadding = '<!-- ${'A' * (70 * 1024)} -->\n';
      request.response.write(
        '$bigPadding<root><device><friendlyName>Oversize</friendlyName></device></root>',
      );
      request.response.close();
      return;
    }

    if (includeDtd) {
      request.response.write(
        '<?xml version="1.0"?>\n<!DOCTYPE root [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>\n<root>&xxe;</root>',
      );
      request.response.close();
      return;
    }

    final xml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
    <friendlyName>Fake IGD Gateway</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
        <controlURL>/control/WANIPConnection</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
    request.response.write(xml);
    request.response.close();
  }

  Future<void> _handleSoapControl(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final soapAction = request.headers.value('SOAPACTION') ?? '';

    request.response.headers.contentType = ContentType(
      'text',
      'xml',
      charset: 'utf-8',
    );

    if (failAll) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(_soapFault(501, 'ActionFailed'));
      await request.response.close();
      return;
    }

    if (soapAction.contains('GetExternalIPAddress') ||
        body.contains('GetExternalIPAddress')) {
      final resp =
          '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
      <NewExternalIPAddress>$externalIp</NewExternalIPAddress>
    </u:GetExternalIPAddressResponse>
  </s:Body>
</s:Envelope>''';
      request.response.statusCode = HttpStatus.ok;
      request.response.write(resp);
      await request.response.close();
      return;
    }

    if (soapAction.contains('AddPortMapping') ||
        body.contains('AddPortMapping')) {
      final extPort = _extractTag(body, 'NewExternalPort');
      final intPort = _extractTag(body, 'NewInternalPort');
      final protocol = _extractTag(body, 'NewProtocol');
      final leaseStr = _extractTag(body, 'NewLeaseDuration') ?? '0';
      final desc =
          _extractTag(body, 'NewPortMappingDescription') ?? 'LibreShare';

      final extPortInt = int.tryParse(extPort ?? '') ?? 0;
      final leaseInt = int.tryParse(leaseStr) ?? 0;

      if (conflictPort != null && extPortInt == conflictPort) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(_soapFault(718, 'ConflictInMappingEntry'));
        await request.response.close();
        return;
      }

      if (permanentOnly && leaseInt > 0) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(_soapFault(725, 'OnlyPermanentLeasesSupported'));
        await request.response.close();
        return;
      }

      _activeMappings.add({
        'externalPort': extPortInt,
        'internalPort': int.tryParse(intPort ?? '') ?? 0,
        'protocol': protocol,
        'leaseDuration': leaseInt,
        'description': desc,
      });

      final resp = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:AddPortMappingResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"/>
  </s:Body>
</s:Envelope>''';
      request.response.statusCode = HttpStatus.ok;
      request.response.write(resp);
      await request.response.close();
      return;
    }

    if (soapAction.contains('DeletePortMapping') ||
        body.contains('DeletePortMapping')) {
      final extPort =
          int.tryParse(_extractTag(body, 'NewExternalPort') ?? '') ?? 0;
      final protocol = _extractTag(body, 'NewProtocol');

      _activeMappings.removeWhere(
        (m) => m['externalPort'] == extPort && m['protocol'] == protocol,
      );

      final resp = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:DeletePortMappingResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"/>
  </s:Body>
</s:Envelope>''';
      request.response.statusCode = HttpStatus.ok;
      request.response.write(resp);
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.internalServerError;
    request.response.write(_soapFault(606, 'ActionNotDefined'));
    await request.response.close();
  }

  static String? _extractTag(String xml, String tag) {
    final start = xml.indexOf('<$tag>');
    final end = xml.indexOf('</$tag>');
    if (start != -1 && end != -1 && end > start) {
      return xml.substring(start + tag.length + 2, end).trim();
    }
    return null;
  }

  static String _soapFault(int code, String description) =>
      '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>$code</errorCode>
          <errorDescription>$description</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>''';
}
