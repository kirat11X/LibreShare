import 'dart:ffi';
import 'dart:io';

/// Holds a TCP port in bound state WITHOUT listening, so it causes
/// `EADDRINUSE` to any other bind attempt, but upon [close] it is
/// released IMMEDIATELY by the kernel without entering the TCP_LISTEN
/// hold period.
class PortBlocker {
  PortBlocker._(this._fd, this.port, this.address);

  final int _fd;
  final int port;
  final String address;

  static final DynamicLibrary _lib = Platform.isWindows
      ? DynamicLibrary.open('ws2_32.dll')
      : DynamicLibrary.process();

  static final int Function(int, int, int) _socket = _lib
      .lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');

  static final int Function(int, Pointer<Void>, int) _bind = _lib
      .lookupFunction<Int32 Function(Int32, Pointer<Void>, Uint32), int Function(int, Pointer<Void>, int)>('bind');

  static final int Function(int) _close = Platform.isWindows
      ? _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('closesocket')
      : _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  static final _malloc = _lib.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
  static final _free = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

  static PortBlocker bind(int port, {String address = '127.0.0.1'}) {
    final fd = _socket(2 /* AF_INET */, 1 /* SOCK_STREAM */, 0);
    if (fd < 0) throw SocketException('Failed to create native socket for PortBlocker');

    final p = _malloc(16).cast<Uint8>();
    try {
      p[0] = 2; // AF_INET (low byte)
      p[1] = 0; // AF_INET (high byte)
      p[2] = (port >> 8) & 0xFF; // port (big-endian)
      p[3] = port & 0xFF;
      final parts = address.split('.').map(int.parse).toList();
      p[4] = parts[0];
      p[5] = parts[1];
      p[6] = parts[2];
      p[7] = parts[3];
      for (var i = 8; i < 16; i++) {
        p[i] = 0;
      }

      final res = _bind(fd, p.cast(), 16);
      if (res != 0) {
        _close(fd);
        throw SocketException('PortBlocker failed to bind $address:$port');
      }
      return PortBlocker._(fd, port, address);
    } finally {
      _free(p.cast());
    }
  }

  Future<void> close() async {
    _close(_fd);
  }

  static int? findFreeRun(int count, {String address = '127.0.0.1'}) {
    for (var attempt = 1; attempt <= 100; attempt++) {
      final base = 35000 + (attempt * 17) % 25000;
      final blockers = <PortBlocker>[];
      var ok = true;
      for (var i = 0; i < count; i++) {
        try {
          blockers.add(PortBlocker.bind(base + i, address: address));
        } catch (_) {
          ok = false;
          break;
        }
      }
      for (final b in blockers) {
        b.close();
      }
      if (ok) return base;
    }
    return null;
  }
}
