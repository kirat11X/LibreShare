// Proof for mutant M81: IGD control URL host must equal the description host
// The repo's hostile-gateway fixtures serve XML WITHOUT a WANIPConnection service, so their
// oversize/DTD/etc. tests pass even with the guard removed. Here the hostile document is
// otherwise a VALID gateway description, so only the guard can reject it.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/src/nat/ssdp.dart';
import 'package:test/test.dart';

String validXml({String control = '/control/WANIPConnection', String prefix = ''}) => '''${prefix}<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>$control</controlURL>
</service></serviceList></device></root>''';

Future<HttpServer> serve(FutureOr<void> Function(HttpRequest) h) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((r) async { await h(r); });
  return s;
}

void main() {
  test('absolute controlURL on another port (same host) is rejected', () async {
    final srv = await serve((r) async {
      final other = r.uri.path == '/xo' ? 'http://127.0.0.1:1/ctl' : '/control/WANIPConnection';
      r.response.write(validXml(control: other));
      await r.response.close();
    });
    addTearDown(() => srv.close(force: true));
    final c = SsdpClient(allowLoopback: true);
    final base = 'http://127.0.0.1:${srv.port}';
    expect(await c.resolveDeviceDescription(Uri.parse('$base/ok')), isNotNull, reason: 'positive control');
    expect(await c.resolveDeviceDescription(Uri.parse('$base/xo')), isNull);
  });
}
