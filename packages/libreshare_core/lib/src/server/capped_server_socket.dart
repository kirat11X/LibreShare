import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// How long a TLS handshake may take before the socket is destroyed and its slot freed.
const Duration kDefaultHandshakeTimeout = Duration(seconds: 10);

/// A [ServerSocket] that limits open TCP connections (total and per remote address) at socket
/// level, so half-sent request heads and unfinished TLS handshakes count too. `dart:io`'s
/// `HttpServer` only sees a connection after the request head is parsed, which is too late for
/// slow-loris protection. Hand it to `HttpServer.listenOn`.
///
/// A connection is counted from accept until it is closed. Over a limit the new connection is
/// destroyed at once; nothing already open is touched. With [securityContext] each accepted
/// socket is upgraded to TLS here (the slot is held during the handshake).
class CappedServerSocket extends StreamView<Socket> implements ServerSocket {
  CappedServerSocket._(
    this._raw,
    this._maxTotal,
    this._maxPerIp,
    this._context,
    this._requestClientCertificate,
    this._handshakeTimeout,
    StreamController<Socket> out,
  ) : _out = out,
      super(out.stream) {
    _out.onCancel = () => _sub?.cancel();
    _sub = _raw.listen(_onAccept, onError: _out.addError, onDone: _out.close);
  }

  /// Binds [address]:[port]. Throws [SocketException] like [ServerSocket.bind].
  static Future<CappedServerSocket> bind(
    InternetAddress address,
    int port, {
    required int maxConnections,
    required int maxConnectionsPerIp,
    SecurityContext? securityContext,
    bool requestClientCertificate = false,
    Duration handshakeTimeout = kDefaultHandshakeTimeout,
  }) async {
    final raw = await ServerSocket.bind(address, port);
    return CappedServerSocket._(
      raw,
      maxConnections,
      maxConnectionsPerIp,
      securityContext,
      requestClientCertificate,
      handshakeTimeout,
      StreamController<Socket>(sync: true),
    );
  }

  final ServerSocket _raw;
  final int _maxTotal;
  final int _maxPerIp;
  final SecurityContext? _context;
  final bool _requestClientCertificate;
  final Duration _handshakeTimeout;
  final Set<Socket> _pending = <Socket>{};
  final StreamController<Socket> _out;
  StreamSubscription<Socket>? _sub;
  final Set<_TrackedSocket> _open = <_TrackedSocket>{};
  final Map<String, int> _perIp = <String, int>{};
  bool _closed = false;

  /// Open (counted) connections right now.
  int get openConnections => _open.length + _handshaking;
  int _handshaking = 0;

  @override
  int get port => _raw.port;

  @override
  InternetAddress get address => _raw.address;

  void _onAccept(Socket socket) {
    final String ip;
    try {
      ip = socket.remoteAddress.address;
    } on Object {
      socket.destroy();
      return;
    }
    final total = _open.length + _handshaking;
    if (total >= _maxTotal || (_perIp[ip] ?? 0) >= _maxPerIp) {
      socket.destroy();
      return;
    }
    _perIp[ip] = (_perIp[ip] ?? 0) + 1;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      final n = (_perIp[ip] ?? 1) - 1;
      if (n <= 0) {
        _perIp.remove(ip);
      } else {
        _perIp[ip] = n;
      }
    }

    final ctx = _context;
    if (ctx == null) {
      late final _TrackedSocket tracked;
      tracked = _TrackedSocket(socket, () {
        _open.remove(tracked);
        release();
      });
      _open.add(tracked);
      _emit(tracked);
      return;
    }
    _handshaking++;
    _pending.add(socket);
    var finished = false;
    void fail() {
      if (finished) return;
      finished = true;
      _handshaking--;
      _pending.remove(socket);
      socket.destroy();
      release();
    }

    // Phase 1 (the plain socket can still be destroyed): the client must deliver a whole first
    // TLS record within the timeout. Phase 2: secureServer takes the fd over and cannot be
    // aborted any more, so the slot stays counted until it settles.
    _readFirstRecord(socket, _handshakeTimeout).then<void>((record) {
      if (finished) return;
      if (record == null) {
        fail();
        return;
      }
      SecureSocket.secureServer(
        socket,
        ctx,
        bufferedData: record,
        requestClientCertificate: _requestClientCertificate,
      ).then<void>((secure) {
        if (finished) {
          secure.destroy();
          return;
        }
        finished = true;
        _handshaking--;
        _pending.remove(socket);
        if (_closed) {
          secure.destroy();
          release();
          return;
        }
        late final _TrackedSecureSocket tracked;
        tracked = _TrackedSecureSocket(secure, () {
          _open.remove(tracked);
          release();
        });
        _open.add(tracked);
        _emit(tracked);
      }, onError: (Object _) => fail());
    });
  }

  void _emit(Socket s) {
    if (_closed || _out.isClosed) {
      s.destroy();
      return;
    }
    _out.add(s);
  }

  /// Stops accepting. Open connections stay open (an in-flight response can still finish).
  @override
  Future<ServerSocket> close() async {
    _closed = true;
    await _sub?.cancel();
    await _raw.close();
    if (!_out.isClosed) await _out.close();
    return this;
  }

  /// Destroys every open connection, including those `HttpServer` has not seen yet.
  void destroyAll() {
    for (final s in _open.toList()) {
      s.destroy();
    }
    // Sockets still in the TLS handshake: destroying fails the handshake, which frees the slot.
    for (final s in _pending.toList()) {
      s.destroy();
    }
  }
}

/// Wraps a [Socket] and calls [_onClosed] once when it ends. `Socket.done` is not reliable for
/// this (it can stay pending after the peer closed or after `destroy`), so the end is taken from
/// `destroy` and `close` (not from the read side: a half-closed peer is still being served).
class _TrackedSocket extends StreamView<Uint8List> implements Socket {
  _TrackedSocket(this._inner, this._onClosed)
    : super(
        _inner.transform(
          StreamTransformer<Uint8List, Uint8List>.fromHandlers(
            // No release here: a peer that half-closes (FIN) after its request is still being
            // served. The slot is freed only by destroy/close of the socket itself.
            handleError: (e, st, sink) => sink.addError(e, st),
            handleDone: (sink) => sink.close(),
          ),
        ),
      );

  final Socket _inner;
  final void Function() _onClosed;
  bool _ended = false;

  void _end() {
    if (_ended) return;
    _ended = true;
    _onClosed();
  }

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> close() {
    final f = _inner.close();
    f.whenComplete(_end);
    return f;
  }

  @override
  Future<void> get done => _inner.done;
  @override
  void destroy() {
    _inner.destroy();
    _end();
  }

  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  int get port => _inner.port;
  @override
  InternetAddress get address => _inner.address;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}

/// [_TrackedSocket] for an accepted TLS socket (keeps `is SecureSocket` true for `HttpServer`).
class _TrackedSecureSocket extends _TrackedSocket implements SecureSocket {
  _TrackedSecureSocket(SecureSocket super.inner, super.onClosed);

  SecureSocket get _secure => _inner as SecureSocket;

  @override
  X509Certificate? get peerCertificate => _secure.peerCertificate;
  @override
  String? get selectedProtocol => _secure.selectedProtocol;
  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) =>
      // ignore: deprecated_member_use
      _secure.renegotiate(
        useSessionCache: useSessionCache,
        requestClientCertificate: requestClientCertificate,
        requireClientCertificate: requireClientCertificate,
      );
}

/// Reads from [s] until one whole TLS record is buffered (at most 16.6 KB). Null on timeout, close,
/// error or a first byte that is not a TLS handshake record. The subscription is left paused.
Future<Uint8List?> _readFirstRecord(Socket s, Duration timeout) {
  final done = Completer<Uint8List?>();
  final buf = BytesBuilder(copy: false);
  final timer = Timer(timeout, () {
    if (!done.isCompleted) done.complete(null);
  });
  final sub = s.listen(
    (d) {
      buf.add(d);
      final b = buf.toBytes();
      if (b[0] != 0x16) {
        if (!done.isCompleted) done.complete(null);
        return;
      }
      if (b.length >= 5) {
        final len = (b[3] << 8) | b[4];
        // The first record must carry ONE whole ClientHello (type 1, 3-byte length = record
        // length - 4). A record that only starts a longer handshake message would keep
        // secureServer waiting for more bytes, which cannot be aborted.
        if (len > 16640 || len < 4) {
          if (!done.isCompleted) done.complete(null);
        } else if (b.length >= 9 &&
            (b[5] != 0x01 || ((b[6] << 16) | (b[7] << 8) | b[8]) != len - 4)) {
          if (!done.isCompleted) done.complete(null);
        } else if (b.length >= 5 + len && !done.isCompleted) {
          done.complete(b);
        }
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete(null);
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  return done.future.whenComplete(() {
    timer.cancel();
    sub.pause();
  });
}
