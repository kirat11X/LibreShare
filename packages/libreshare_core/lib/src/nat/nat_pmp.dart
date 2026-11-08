// NAT-PMP (RFC 6886) client for Increment 5b.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'port_mapping.dart';

class NatPmpClient {
  const NatPmpClient();

  static const int defaultPort = 5351;

  /// Retrieves the external IP address from the NAT-PMP gateway.
  Future<String?> getExternalIpAddress({
    required String gatewayIp,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final destAddr = (await InternetAddress.lookup(gatewayIp)).first;

      // Opcode 0: Request external IP (2 bytes: 0x00, 0x00)
      final req = Uint8List(2);
      req[0] = 0;
      req[1] = 0;

      socket.send(req, destAddr, port);

      final completer = Completer<String?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null && dg.data.length >= 12) {
            final data = dg.data;
            if (data[0] == 0 && data[1] == 128) {
              // Version 0, Response to Op 0
              final resCode = (data[2] << 8) | data[3];
              if (resCode == 0) {
                final ip = '${data[8]}.${data[9]}.${data[10]}.${data[11]}';
                if (!completer.isCompleted) completer.complete(ip);
              }
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

  /// Adds a port mapping via NAT-PMP.
  Future<PortMapping?> addPortMapping({
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

      // Op 1 = UDP, Op 2 = TCP
      final op = protocol == PortMappingProtocol.tcp ? 2 : 1;
      final req = ByteData(12);
      req.setUint8(0, 0); // version 0
      req.setUint8(1, op);
      req.setUint16(2, 0); // reserved
      req.setUint16(4, internalPort);
      req.setUint16(6, externalPort ?? internalPort);
      req.setUint32(8, lease.inSeconds);

      socket.send(req.buffer.asUint8List(), destAddr, port);

      final completer = Completer<PortMapping?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null && dg.data.length >= 16) {
            final data = dg.data;
            final view = ByteData.sublistView(data);
            if (data[0] == 0 && data[1] == (op | 128)) {
              final resCode = view.getUint16(2);
              if (resCode == 0) {
                final assignedExt = view.getUint16(10);
                final assignedLifetime = view.getUint32(12);
                final mapping = PortMapping(
                  internalPort: internalPort,
                  externalPort: assignedExt,
                  externalIp: gatewayIp,
                  protocol: protocol,
                  leaseDuration: Duration(seconds: assignedLifetime),
                  createdAt: DateTime.now(),
                );
                if (!completer.isCompleted) completer.complete(mapping);
              }
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

  /// Deletes a port mapping via NAT-PMP (request with lifetime 0).
  Future<bool> deletePortMapping({
    required String gatewayIp,
    required int internalPort,
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final res = await addPortMapping(
      gatewayIp: gatewayIp,
      internalPort: internalPort,
      externalPort: 0,
      lease: Duration.zero,
      protocol: protocol,
      port: port,
      timeout: timeout,
    );
    return res != null;
  }
}
