// Port Control Protocol (PCP, RFC 6887) client for Increment 5b.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'port_mapping.dart';

class PcpClient {
  const PcpClient();

  static const int defaultPort = 5351;
  static const int pcpVersion = 2;
  static const int opcodeMap = 1;

  /// Requests a port mapping via PCP MAP opcode.
  Future<PortMapping?> requestMapping({
    required String gatewayIp,
    required int internalPort,
    int? externalPort,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final destAddr = (await InternetAddress.lookup(gatewayIp)).first;

      // 24-byte base header + 36-byte MAP opcode data = 60 bytes
      final req = ByteData(60);
      req.setUint8(0, pcpVersion);
      req.setUint8(1, opcodeMap);
      req.setUint16(2, 0); // reserved
      req.setUint32(4, lease.inSeconds);

      // Client IP (16 bytes IPv4-mapped IPv6)
      req.setUint8(20, 0xFF);
      req.setUint8(21, 0xFF);
      req.setUint8(22, 127);
      req.setUint8(23, 1);

      // Mapping nonce (12 bytes)
      req.setUint32(24, 0x12345678);

      // Protocol (6 = TCP, 17 = UDP)
      final protoNum = protocol == PortMappingProtocol.tcp ? 6 : 17;
      req.setUint8(36, protoNum);

      // Internal & external port
      req.setUint16(40, internalPort);
      req.setUint16(42, externalPort ?? internalPort);

      socket.send(req.buffer.asUint8List(), destAddr, port);

      final completer = Completer<PortMapping?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null && dg.data.length >= 24) {
            final view = ByteData.sublistView(dg.data);
            final ver = view.getUint8(0);
            final rOp = view.getUint8(1);
            final resCode = view.getUint8(3);

            if (ver == pcpVersion &&
                rOp == (opcodeMap | 0x80) &&
                resCode == 0) {
              final assignedExt = dg.data.length >= 44
                  ? view.getUint16(42)
                  : (externalPort ?? internalPort);
              final mapping = PortMapping(
                internalPort: internalPort,
                externalPort: assignedExt,
                externalIp: gatewayIp,
                protocol: protocol,
                leaseDuration: lease,
                createdAt: DateTime.now(),
              );
              if (!completer.isCompleted) completer.complete(mapping);
            }
          }
        }
      });

      final result = await completer.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }
}
