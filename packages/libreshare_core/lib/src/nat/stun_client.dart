// RFC 5389 STUN Client for Increment 5b reflexive address discovery.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

final class StunResult {
  const StunResult({
    required this.externalIp,
    required this.externalPort,
    required this.serverHost,
    required this.serverPort,
  });

  final String externalIp;
  final int externalPort;
  final String serverHost;
  final int serverPort;

  @override
  String toString() =>
      'StunResult($externalIp:$externalPort via $serverHost:$serverPort)';
}

class StunClient {
  StunClient({Random? random}) : _random = random ?? Random.secure();

  static const int magicCookie = 0x2112A442;
  static const int bindingRequest = 0x0001;
  static const int bindingResponse = 0x0101;
  static const int attrMappedAddress = 0x0001;
  static const int attrXorMappedAddress = 0x0020;

  final Random _random;

  /// Queries the STUN server at [serverHost]:[serverPort] to discover the public reflexive IP.
  /// If [injectedSocket] is provided, uses it instead of binding a new UDP socket.
  Future<StunResult?> getReflexiveAddress({
    required String serverHost,
    int serverPort = 19302,
    Duration timeout = const Duration(seconds: 3),
    RawDatagramSocket? injectedSocket,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket =
          injectedSocket ??
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      final transactionId = Uint8List(12);
      for (var i = 0; i < 12; i++) {
        transactionId[i] = _random.nextInt(256);
      }

      final request = _buildBindingRequest(transactionId);
      final destAddress = (await InternetAddress.lookup(serverHost)).first;

      socket.send(request, destAddress, serverPort);

      final completer = Completer<StunResult?>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            final result = _parseResponse(
              datagram.data,
              transactionId,
              serverHost,
              serverPort,
            );
            if (result != null && !completer.isCompleted) {
              completer.complete(result);
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
      if (injectedSocket == null) {
        socket?.close();
      }
    }
  }

  /// Builds a 20-byte STUN Binding Request packet.
  static Uint8List _buildBindingRequest(Uint8List transactionId) {
    final buffer = ByteData(20);
    buffer.setUint16(0, bindingRequest); // Type
    buffer.setUint16(2, 0); // Message length (0 attributes)
    buffer.setUint32(4, magicCookie); // Magic Cookie

    final bytes = buffer.buffer.asUint8List();
    for (var i = 0; i < 12; i++) {
      bytes[8 + i] = transactionId[i];
    }
    return bytes;
  }

  /// Parses a STUN response packet and extracts the reflexive address.
  static StunResult? _parseResponse(
    Uint8List data,
    Uint8List expectedTxId,
    String serverHost,
    int serverPort,
  ) {
    if (data.length < 20) return null;

    final view = ByteData.sublistView(data);
    final msgType = view.getUint16(0);
    final msgLen = view.getUint16(2);
    final cookie = view.getUint32(4);

    if (msgType != bindingResponse) return null;
    if (cookie != magicCookie) return null;

    // Verify transaction ID
    for (var i = 0; i < 12; i++) {
      if (data[8 + i] != expectedTxId[i]) return null;
    }

    if (data.length < 20 + msgLen) return null;

    // Parse attributes
    var offset = 20;
    final end = 20 + msgLen;

    String? xorIp;
    int? xorPort;
    String? plainIp;
    int? plainPort;

    while (offset + 4 <= end) {
      final attrType = view.getUint16(offset);
      final attrLen = view.getUint16(offset + 2);
      offset += 4;

      if (offset + attrLen > end) break;

      if (attrType == attrXorMappedAddress && attrLen >= 8) {
        final family = data[offset + 1];
        final rawPort = view.getUint16(offset + 2);
        final port = rawPort ^ (magicCookie >> 16);

        if (family == 0x01 && attrLen >= 8) {
          // IPv4
          final rawIp = view.getUint32(offset + 4);
          final ipVal = rawIp ^ magicCookie;
          final ipStr =
              '${(ipVal >> 24) & 0xFF}.${(ipVal >> 16) & 0xFF}.${(ipVal >> 8) & 0xFF}.${ipVal & 0xFF}';
          xorIp = ipStr;
          xorPort = port;
        } else if (family == 0x02 && attrLen >= 20) {
          // IPv6
          final xorKey = Uint8List(16);
          final cookieView = ByteData(4)..setUint32(0, magicCookie);
          xorKey.setRange(0, 4, cookieView.buffer.asUint8List());
          xorKey.setRange(4, 16, expectedTxId);

          final ipBytes = Uint8List(16);
          for (var i = 0; i < 16; i++) {
            ipBytes[i] = data[offset + 4 + i] ^ xorKey[i];
          }
          final words = <int>[];
          for (var i = 0; i < 8; i++) {
            words.add((ipBytes[i * 2] << 8) | ipBytes[i * 2 + 1]);
          }
          xorIp = words.map((w) => w.toRadixString(16)).join(':');
          xorPort = port;
        }
      } else if (attrType == attrMappedAddress && attrLen >= 8) {
        final family = data[offset + 1];
        final port = view.getUint16(offset + 2);

        if (family == 0x01 && attrLen >= 8) {
          final b0 = data[offset + 4];
          final b1 = data[offset + 5];
          final b2 = data[offset + 6];
          final b3 = data[offset + 7];
          plainIp = '$b0.$b1.$b2.$b3';
          plainPort = port;
        }
      }

      // Attributes are padded to 4-byte boundaries
      offset += (attrLen + 3) & ~3;
    }

    final ip = xorIp ?? plainIp;
    final port = xorPort ?? plainPort;

    if (ip == null || port == null) return null;

    return StunResult(
      externalIp: ip,
      externalPort: port,
      serverHost: serverHost,
      serverPort: serverPort,
    );
  }
}
