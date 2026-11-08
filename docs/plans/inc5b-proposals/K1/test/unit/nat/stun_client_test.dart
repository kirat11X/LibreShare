import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/stun_client.dart';

void main() {
  group('StunClient Unit Tests', () {
    test('Hermetic STUN binding round-trip via local mock server', () async {
      // Setup mock STUN responder on localhost
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final serverPort = server.port;

      server.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = server.receive();
          if (dg != null && dg.data.length >= 20) {
            // Build response
            final txId = dg.data.sublist(8, 20);
            const xorIp = '203.0.113.88';
            const xorPort = 45678;

            final resp = _buildXorResponse(txId, xorIp, xorPort);
            server.send(resp, dg.address, dg.port);
          }
        }
      });

      final client = StunClient();
      final result = await client.getReflexiveAddress(
        serverHost: '127.0.0.1',
        serverPort: serverPort,
        timeout: const Duration(seconds: 2),
      );

      server.close();

      expect(result, isNotNull);
      expect(result!.externalIp, '203.0.113.88');
      expect(result.externalPort, 45678);
      expect(result.serverHost, '127.0.0.1');
      expect(result.serverPort, serverPort);
    });

    test('Timeout when STUN server does not respond', () async {
      final dummySocket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final dummyPort = dummySocket.port;
      // Socket binds but sends nothing back

      final client = StunClient();
      final result = await client.getReflexiveAddress(
        serverHost: '127.0.0.1',
        serverPort: dummyPort,
        timeout: const Duration(milliseconds: 200),
      );

      dummySocket.close();
      expect(result, isNull);
    });
  });
}

Uint8List _buildXorResponse(Uint8List txId, String ipStr, int port) {
  final ipParts = ipStr.split('.').map(int.parse).toList();
  const magicCookie = StunClient.magicCookie;

  final ipVal =
      (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3];
  final xorIpVal = ipVal ^ magicCookie;
  final xorPortVal = port ^ (magicCookie >> 16);

  // 20 bytes header + 12 bytes XOR-MAPPED-ADDRESS (attr header 4 bytes + 8 bytes value)
  final buffer = ByteData(32);
  buffer.setUint16(0, StunClient.bindingResponse); // 0x0101
  buffer.setUint16(2, 12); // Length of attributes
  buffer.setUint32(4, magicCookie);

  final bytes = buffer.buffer.asUint8List();
  for (var i = 0; i < 12; i++) {
    bytes[8 + i] = txId[i];
  }

  // Attribute XOR-MAPPED-ADDRESS
  buffer.setUint16(20, StunClient.attrXorMappedAddress); // 0x0020
  buffer.setUint16(22, 8); // length
  bytes[24] = 0x00; // reserved
  bytes[25] = 0x01; // IPv4
  buffer.setUint16(26, xorPortVal);
  buffer.setUint32(28, xorIpVal);

  return bytes;
}
