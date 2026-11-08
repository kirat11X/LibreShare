// Fake NAT-PMP & PCP server for Increment 5b UDP port mapping tests.

import 'dart:io';
import 'dart:typed_data';

class FakePcpServer {
  FakePcpServer({
    this.externalIp = '203.0.113.1',
    this.resultCode = 0,
    this.conflictPort,
  });

  final String externalIp;
  int resultCode;
  int? conflictPort;

  RawDatagramSocket? _socket;
  final List<Map<String, dynamic>> _activeMappings = [];

  List<Map<String, dynamic>> get activeMappings =>
      List.unmodifiable(_activeMappings);
  int get port => _socket?.port ?? 0;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket!.listen(_handleDatagram);
  }

  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }

  void _handleDatagram(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final dg = _socket?.receive();
      if (dg == null || dg.data.isEmpty) return;

      final version = dg.data[0];
      if (version == 0) {
        _handleNatPmp(dg);
      } else if (version == 2) {
        _handlePcp(dg);
      }
    }
  }

  void _handleNatPmp(Datagram dg) {
    final data = dg.data;
    if (data.length < 2) return;

    final op = data[1];
    final respOp = op | 0x80;

    if (op == 0) {
      // External IP request
      final resp = ByteData(12);
      resp.setUint8(0, 0); // Version 0
      resp.setUint8(1, respOp);
      resp.setUint16(2, resultCode); // Result code
      resp.setUint32(4, 1000); // Epoch

      // 4 bytes IPv4
      final parts = externalIp.split('.').map(int.parse).toList();
      resp.setUint8(8, parts[0]);
      resp.setUint8(9, parts[1]);
      resp.setUint8(10, parts[2]);
      resp.setUint8(11, parts[3]);

      _socket?.send(resp.buffer.asUint8List(), dg.address, dg.port);
    } else if (op == 1 || op == 2) {
      // Port map (1 = UDP, 2 = TCP)
      if (data.length < 12) return;
      final view = ByteData.sublistView(data);
      final intPort = view.getUint16(4);
      final extPortReq = view.getUint16(6);
      final lifetime = view.getUint32(8);

      var assignedExt = extPortReq == 0 ? intPort : extPortReq;
      if (conflictPort != null && assignedExt == conflictPort) {
        assignedExt = assignedExt + 1;
      }

      if (lifetime == 0) {
        _activeMappings.removeWhere(
          (m) =>
              m['internalPort'] == intPort &&
              m['protocol'] == (op == 2 ? 'TCP' : 'UDP'),
        );
      } else {
        _activeMappings.add({
          'internalPort': intPort,
          'externalPort': assignedExt,
          'protocol': op == 2 ? 'TCP' : 'UDP',
          'lifetime': lifetime,
        });
      }

      final resp = ByteData(16);
      resp.setUint8(0, 0); // Version 0
      resp.setUint8(1, respOp);
      resp.setUint16(2, resultCode);
      resp.setUint32(4, 1000); // Epoch
      resp.setUint16(8, intPort);
      resp.setUint16(10, assignedExt);
      resp.setUint32(12, lifetime);

      _socket?.send(resp.buffer.asUint8List(), dg.address, dg.port);
    }
  }

  void _handlePcp(Datagram dg) {
    // Basic PCP RFC 6887 response
    final data = dg.data;
    if (data.length < 24) return;

    final opcode = data[1];
    final resp = Uint8List.fromList(data);
    resp[1] = opcode | 0x80; // Response bit
    resp[3] = resultCode; // Result code

    _socket?.send(resp, dg.address, dg.port);
  }
}
