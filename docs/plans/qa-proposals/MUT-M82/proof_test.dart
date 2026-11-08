// Proof for mutant M82: IGD host given as a name must resolve to a permitted (private) address
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
  test('hostname resolving to loopback is refused when loopback is not allowed', () async {
    final srv = await serve((r) async {
      r.response.write(validXml());
      await r.response.close();
    });
    addTearDown(() => srv.close(force: true));
    final strict = SsdpClient(allowLoopback: false);
    final lax = SsdpClient(allowLoopback: true);
    final u = Uri.parse('http://localhost:${srv.port}/d');
    expect(await lax.resolveDeviceDescription(u), isNotNull, reason: 'positive control');
    expect(await strict.resolveDeviceDescription(u), isNull);
  });
}
