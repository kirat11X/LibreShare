import 'dart:async';
import 'dart:typed_data';

/// Maximum reassembled application message cap over GATT (2 KiB).
const int kMaxGattMessageSize = 2048;

/// Default BLE legacy MTU (23 bytes).
const int kDefaultGattMtu = 23;

/// Inactivity timeout for GATT frame reassembly (5 seconds).
const Duration kGattReassemblyTimeout = Duration(seconds: 5);

/// Fragments an application message into GATT characteristic frame payloads.
List<Uint8List> fragmentMessage(
  List<int> message, {
  int mtu = kDefaultGattMtu,
}) {
  if (message.length > kMaxGattMessageSize) {
    throw ArgumentError.value(
      message.length,
      'message',
      'Message exceeds maximum GATT message size of $kMaxGattMessageSize bytes',
    );
  }
  // ATT write header is 3 bytes, frame header is 1 byte
  final maxPayload = mtu - 3 - 1;
  if (maxPayload < 1) {
    throw ArgumentError.value(mtu, 'mtu', 'MTU must be at least 5 bytes');
  }

  if (message.isEmpty) {
    // Single empty frame (first and last)
    final frame = Uint8List(1);
    frame[0] = (1 << 7) | (1 << 6); // isFirst | isLast | seq=0
    return [frame];
  }

  final frames = <Uint8List>[];
  var offset = 0;
  var seq = 0;

  while (offset < message.length) {
    final remaining = message.length - offset;
    final chunkSize = remaining > maxPayload ? maxPayload : remaining;
    final isFirst = offset == 0;
    final isLast = offset + chunkSize >= message.length;

    var header = seq & 0x3F;
    if (isFirst) header |= (1 << 7);
    if (isLast) header |= (1 << 6);

    final frame = Uint8List(1 + chunkSize);
    frame[0] = header;
    frame.setRange(1, 1 + chunkSize, message, offset);
    frames.add(frame);

    offset += chunkSize;
    seq = (seq + 1) % 64;
  }

  return frames;
}

/// Reassembles GATT frames into whole application messages.
class GattFrameReassembler {
  GattFrameReassembler({
    this.maxMessageSize = kMaxGattMessageSize,
    this.timeout = kGattReassemblyTimeout,
  });

  final int maxMessageSize;
  final Duration timeout;

  final BytesBuilder _buffer = BytesBuilder();
  int _expectedSeq = 0;
  bool _inProgress = false;
  Timer? _timeoutTimer;

  bool get inProgress => _inProgress;

  /// Ingests a raw GATT frame. Returns the reassembled message if this frame completed it,
  /// or null if more frames are expected.
  Uint8List? processFrame(List<int> frameBytes) {
    if (frameBytes.isEmpty) {
      throw const FormatException('Empty GATT frame received');
    }

    final header = frameBytes[0];
    final isFirst = (header & (1 << 7)) != 0;
    final isLast = (header & (1 << 6)) != 0;
    final seq = header & 0x3F;

    if (isFirst) {
      _buffer.clear();
      _expectedSeq = seq;
      _inProgress = true;
    } else if (!_inProgress) {
      throw const FormatException(
        'Received continuation frame without preceding first frame',
      );
    } else if (seq != _expectedSeq) {
      reset();
      throw FormatException(
        'GATT frame sequence gap: expected $_expectedSeq, got $seq',
      );
    }

    _armTimeout();

    final payload = frameBytes.sublist(1);
    if (_buffer.length + payload.length > maxMessageSize) {
      reset();
      throw FormatException(
        'GATT reassembly buffer exceeded cap of $maxMessageSize bytes',
      );
    }

    _buffer.add(payload);
    _expectedSeq = (_expectedSeq + 1) % 64;

    if (isLast) {
      final complete = _buffer.takeBytes();
      reset();
      return complete;
    }

    return null;
  }

  void _armTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, reset);
  }

  /// Clears in-progress state and cancels timers.
  void reset() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _buffer.clear();
    _inProgress = false;
    _expectedSeq = 0;
  }

  void dispose() {
    reset();
  }
}
