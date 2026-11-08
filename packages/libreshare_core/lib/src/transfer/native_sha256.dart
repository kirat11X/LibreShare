/// Native SHA-256 behind the [Sha256Provider] seam (speed wave S2).
///
/// Linux and macOS use the system libcrypto (EVP_*), Windows uses bcrypt
/// (CNG). Each library is loaded only after a load-time known-answer test
/// (NIST vectors, one-shot and incremental) passes; any failure returns null
/// and the pure-Dart provider stays active. Nothing here throws to callers.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'hashing.dart';

/// Native calls never get more than this many bytes at once.
const int _kSliceMax = 1024 * 1024;

const String _kAbcHex =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const String _kMillionAHex =
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';

/// Environment kill switch: `LS_NO_NATIVE_SHA=1` keeps pure Dart.
const String _kKillSwitchEnv = 'LS_NO_NATIVE_SHA';

/// Native SHA-256 provider. Obtain one through [tryLoadNativeSha256].
class NativeSha256Provider implements IncrementalSha256Provider {
  NativeSha256Provider._(this.libraryName, this._backend);

  /// The candidate name (or absolute path) the library was opened from.
  final String libraryName;
  final _NativeBackend _backend;

  @override
  Sha256Incremental startIncremental() => _NativeIncremental(_backend.open());

  @override
  String hashBytes(List<int> bytes) {
    final inc = startIncremental();
    try {
      inc.add(bytes);
      return inc.finishHex();
    } finally {
      inc.dispose();
    }
  }

  @override
  Future<String> hashStream(Stream<List<int>> input) async {
    final inc = startIncremental();
    try {
      await for (final part in input) {
        inc.add(part);
      }
      return inc.finishHex();
    } finally {
      inc.dispose();
    }
  }
}

/// Library candidates for [os], in the order they are tried. Windows only
/// uses the absolute bcrypt path below `%SystemRoot%\System32`; a missing or
/// relative SystemRoot yields no candidates. Android and iOS: none (the pool
/// path comes in wave S1).
List<String> nativeSha256Candidates({
  required String os,
  Map<String, String>? env,
}) {
  switch (os) {
    case 'linux':
      return const ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so'];
    case 'macos':
      return const ['/usr/lib/libcrypto.dylib'];
    case 'windows':
      final root = env?['SystemRoot'] ?? env?['SYSTEMROOT'];
      if (root == null || !_isSafeWindowsRoot(root)) return const [];
      final base = root.replaceAll(RegExp(r'\\+$'), '');
      return ['$base\\System32\\bcrypt.dll'];
    default:
      return const [];
  }
}

bool _isSafeWindowsRoot(String root) =>
    RegExp(r'^[A-Za-z]:\\[^/]*$').hasMatch(root) && !root.contains('..');

/// Loads the first candidate whose known-answer test passes. Never throws.
///
/// [candidates] defaults to [nativeSha256Candidates] for this host.
/// [tamperDigestForTest] is applied to every digest the library returns
/// before the known-answer test compares it (tests only).
NativeSha256Provider? tryLoadNativeSha256({
  List<String>? candidates,
  String Function(String hex)? tamperDigestForTest,
}) {
  try {
    final list =
        candidates ??
        nativeSha256Candidates(
          os: Platform.operatingSystem,
          env: Platform.environment,
        );
    for (final name in list) {
      final p = _tryCandidate(name, tamperDigestForTest);
      if (p != null) return p;
    }
    return null;
  } on Object {
    return null;
  }
}

/// The provider the process should use: native when it loads and is not
/// disabled, pure Dart otherwise. Loaded at most once per isolate. Does not
/// touch [activeSha256Provider]. Never throws.
IncrementalSha256Provider resolveBestSha256Provider({bool allowNative = true}) {
  try {
    if (!allowNative || Platform.environment[_kKillSwitchEnv] == '1') {
      return const PureDartSha256Provider();
    }
    if (!_nativeTried) {
      _nativeTried = true;
      _nativeCache = tryLoadNativeSha256();
    }
    return _nativeCache ?? const PureDartSha256Provider();
  } on Object {
    return const PureDartSha256Provider();
  }
}

/// Sets [activeSha256Provider] to the best provider and returns it.
/// Idempotent. `allowNative: false` selects pure Dart.
IncrementalSha256Provider installBestSha256Provider({bool allowNative = true}) {
  final p = resolveBestSha256Provider(allowNative: allowNative);
  activeSha256Provider = p;
  return p;
}

IncrementalSha256Provider? _nativeCache;
bool _nativeTried = false;

NativeSha256Provider? _tryCandidate(
  String name,
  String Function(String hex)? tamper,
) {
  if (name.isEmpty) return null;
  try {
    final lib = DynamicLibrary.open(name);
    final backend = Platform.isWindows ? _BcryptBackend(lib) : _EvpBackend(lib);
    final provider = NativeSha256Provider._(name, backend);
    return _knownAnswer(provider, tamper) ? provider : null;
  } on Object {
    return null;
  }
}

/// NIST vectors through one-shot and incremental paths, compared with the
/// constants above (and the empty digest from hashing.dart).
bool _knownAnswer(NativeSha256Provider p, String Function(String hex)? tamper) {
  String t(String h) => tamper == null ? h : tamper(h);
  final abc = utf8.encode('abc');
  final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
  final digests = <String>[
    t(p.hashBytes(const <int>[])),
    t(p.hashBytes(abc)),
    t(p.hashBytes(million)),
    t(
      _incrementalHex(p, [
        Uint8List.fromList([0x61]),
        Uint8List.fromList([0x62, 0x63]),
      ]),
    ),
    t(
      _incrementalHex(p, [
        for (var i = 0; i < million.length; i += 65536)
          Uint8List.sublistView(million, i, min(i + 65536, million.length)),
      ]),
    ),
    t(_incrementalHex(p, const [])),
  ];
  const expected = [
    kSha256Empty,
    _kAbcHex,
    _kMillionAHex,
    _kAbcHex,
    _kMillionAHex,
    kSha256Empty,
  ];
  for (var i = 0; i < expected.length; i++) {
    if (digests[i] != expected[i]) return false;
  }
  return true;
}

String _incrementalHex(NativeSha256Provider p, List<List<int>> pieces) {
  final inc = p.startIncremental();
  try {
    for (final piece in pieces) {
      inc.add(piece);
    }
    return inc.finishHex();
  } finally {
    inc.dispose();
  }
}

// ----------------------------------------------------------------- memory

typedef _MallocC = Pointer<Void> Function(IntPtr size);
typedef _MallocD = Pointer<Void> Function(int size);
typedef _FreeC = Void Function(Pointer<Void> p);
typedef _FreeD = void Function(Pointer<Void> p);

/// libc malloc/free (msvcrt on Windows). Native staging memory only.
class _Mem {
  _Mem._();

  static final DynamicLibrary _lib = Platform.isWindows
      ? DynamicLibrary.open('msvcrt.dll')
      : DynamicLibrary.process();
  static final _MallocD malloc = _lib.lookupFunction<_MallocC, _MallocD>(
    'malloc',
  );
  static final _FreeD free = _lib.lookupFunction<_FreeC, _FreeD>('free');
}

// ---------------------------------------------------------------- backends

abstract interface class _NativeDigest {
  /// Feeds [n] bytes at [p]. False on failure.
  bool update(Pointer<Uint8> p, int n);

  /// The 32 digest bytes. Called once.
  Uint8List finish();

  /// Frees the native context. Called once.
  void close();
}

abstract interface class _NativeBackend {
  /// Opens a fresh digest context. Throws on failure.
  _NativeDigest open();
}

typedef _EvpNewCtxC = Pointer<Void> Function();
typedef _EvpNewCtxD = Pointer<Void> Function();
typedef _EvpSha256C = Pointer<Void> Function();
typedef _EvpSha256D = Pointer<Void> Function();
typedef _EvpInitC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpInitD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _EvpUpdateC = Int32 Function(Pointer<Void>, Pointer<Void>, IntPtr);
typedef _EvpUpdateD = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _EvpFinalC = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _EvpFinalD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _EvpFreeCtxC = Void Function(Pointer<Void>);
typedef _EvpFreeCtxD = void Function(Pointer<Void>);

/// OpenSSL / LibreSSL EVP digest API (libcrypto 1.1 and 3.x).
class _EvpBackend implements _NativeBackend {
  _EvpBackend(DynamicLibrary lib)
    : _newCtx = lib.lookupFunction<_EvpNewCtxC, _EvpNewCtxD>('EVP_MD_CTX_new'),
      _sha256 = lib.lookupFunction<_EvpSha256C, _EvpSha256D>('EVP_sha256'),
      _init = lib.lookupFunction<_EvpInitC, _EvpInitD>('EVP_DigestInit_ex'),
      _update = lib.lookupFunction<_EvpUpdateC, _EvpUpdateD>(
        'EVP_DigestUpdate',
      ),
      _final = lib.lookupFunction<_EvpFinalC, _EvpFinalD>('EVP_DigestFinal_ex'),
      _freeCtx = lib.lookupFunction<_EvpFreeCtxC, _EvpFreeCtxD>(
        'EVP_MD_CTX_free',
      );

  final _EvpNewCtxD _newCtx;
  final _EvpSha256D _sha256;
  final _EvpInitD _init;
  final _EvpUpdateD _update;
  final _EvpFinalD _final;
  final _EvpFreeCtxD _freeCtx;

  @override
  _NativeDigest open() {
    final ctx = _newCtx();
    if (ctx == nullptr) throw StateError('EVP_MD_CTX_new failed');
    if (_init(ctx, _sha256(), nullptr) != 1) {
      _freeCtx(ctx);
      throw StateError('EVP_DigestInit_ex failed');
    }
    return _EvpDigest(this, ctx);
  }
}

class _EvpDigest implements _NativeDigest {
  _EvpDigest(this._b, this._ctx);

  final _EvpBackend _b;
  final Pointer<Void> _ctx;
  bool _closed = false;

  @override
  bool update(Pointer<Uint8> p, int n) => _b._update(_ctx, p.cast(), n) == 1;

  @override
  Uint8List finish() {
    // 64 bytes for the digest (EVP_MAX_MD_SIZE) then one uint32 length.
    final out = _Mem.malloc(68).cast<Uint8>();
    if (out == nullptr) throw StateError('out of memory');
    try {
      final lenPtr = Pointer<Uint32>.fromAddress(out.address + 64);
      if (_b._final(_ctx, out, lenPtr) != 1) {
        throw StateError('EVP_DigestFinal_ex failed');
      }
      if (lenPtr.value != 32) {
        throw StateError('unexpected SHA-256 length ${lenPtr.value}');
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      _Mem.free(out.cast());
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _b._freeCtx(_ctx);
  }
}

typedef _BcOpenC = Int32 Function(
  Pointer<Pointer<Void>>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  Uint32,
);
typedef _BcOpenD = int Function(
  Pointer<Pointer<Void>>,
  Pointer<Uint16>,
  Pointer<Uint16>,
  int,
);
typedef _BcCreateC = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _BcCreateD = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _BcDataC = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _BcDataD = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _BcDestroyC = Int32 Function(Pointer<Void>);
typedef _BcDestroyD = int Function(Pointer<Void>);
typedef _BcCloseC = Int32 Function(Pointer<Void>, Uint32);
typedef _BcCloseD = int Function(Pointer<Void>, int);

/// Windows CNG (bcrypt.dll). Each context owns its own algorithm handle.
class _BcryptBackend implements _NativeBackend {
  _BcryptBackend(DynamicLibrary lib)
    : _openAlg = lib.lookupFunction<_BcOpenC, _BcOpenD>(
        'BCryptOpenAlgorithmProvider',
      ),
      _createHash = lib.lookupFunction<_BcCreateC, _BcCreateD>(
        'BCryptCreateHash',
      ),
      _hashData = lib.lookupFunction<_BcDataC, _BcDataD>('BCryptHashData'),
      _finishHash = lib.lookupFunction<_BcDataC, _BcDataD>('BCryptFinishHash'),
      _destroyHash = lib.lookupFunction<_BcDestroyC, _BcDestroyD>(
        'BCryptDestroyHash',
      ),
      _closeAlg = lib.lookupFunction<_BcCloseC, _BcCloseD>(
        'BCryptCloseAlgorithmProvider',
      );

  final _BcOpenD _openAlg;
  final _BcCreateD _createHash;
  final _BcDataD _hashData;
  final _BcDataD _finishHash;
  final _BcDestroyD _destroyHash;
  final _BcCloseD _closeAlg;

  @override
  _NativeDigest open() {
    // Two handle slots: [0] algorithm, [1] hash. NTSTATUS 0 means success.
    final slots = _Mem.malloc(16).cast<Pointer<Void>>();
    final name = _Mem.malloc(16).cast<Uint16>();
    if (slots == nullptr || name == nullptr) {
      if (slots != nullptr) _Mem.free(slots.cast());
      if (name != nullptr) _Mem.free(name.cast());
      throw StateError('out of memory');
    }
    try {
      const algName = 'SHA256';
      for (var i = 0; i < algName.length; i++) {
        name[i] = algName.codeUnitAt(i);
      }
      name[algName.length] = 0;
      slots[0] = nullptr;
      slots[1] = nullptr;
      if (_openAlg(slots, name, nullptr, 0) != 0) {
        throw StateError('BCryptOpenAlgorithmProvider failed');
      }
      final alg = slots[0];
      if (_createHash(alg, (slots + 1), nullptr, 0, nullptr, 0, 0) != 0) {
        _closeAlg(alg, 0);
        throw StateError('BCryptCreateHash failed');
      }
      return _BcryptDigest(this, alg, slots[1]);
    } finally {
      _Mem.free(name.cast());
      _Mem.free(slots.cast());
    }
  }
}

class _BcryptDigest implements _NativeDigest {
  _BcryptDigest(this._b, this._alg, this._hash);

  final _BcryptBackend _b;
  final Pointer<Void> _alg;
  final Pointer<Void> _hash;
  bool _closed = false;

  @override
  bool update(Pointer<Uint8> p, int n) => _b._hashData(_hash, p, n, 0) == 0;

  @override
  Uint8List finish() {
    final out = _Mem.malloc(32).cast<Uint8>();
    if (out == nullptr) throw StateError('out of memory');
    try {
      if (_b._finishHash(_hash, out, 32, 0) != 0) {
        throw StateError('BCryptFinishHash failed');
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      _Mem.free(out.cast());
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _b._destroyHash(_hash);
    _b._closeAlg(_alg, 0);
  }
}

// ------------------------------------------------------------- incremental

class _NativeIncremental implements Sha256Incremental {
  _NativeIncremental(this._digest);

  final _NativeDigest _digest;
  bool _finished = false;
  bool _disposed = false;

  @override
  void add(List<int> data) {
    if (_disposed) throw StateError('SHA-256 context already disposed');
    if (_finished) throw StateError('add after finishHex');
    final total = data.length;
    var off = 0;
    while (off < total) {
      final n = min(total - off, _kSliceMax);
      final buf = _Mem.malloc(n).cast<Uint8>();
      if (buf == nullptr) throw StateError('out of memory');
      try {
        _copyIn(data, off, buf, n);
        if (!_digest.update(buf, n)) {
          throw StateError('native SHA-256 update failed');
        }
      } finally {
        _Mem.free(buf.cast());
      }
      off += n;
    }
  }

  @override
  String finishHex() {
    if (_disposed) throw StateError('SHA-256 context already disposed');
    if (_finished) throw StateError('finishHex called twice');
    _finished = true;
    return _hexOf(_digest.finish());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _digest.close();
  }
}

/// Copies `src[off, off + n)` into native memory at [dst].
void _copyIn(List<int> src, int off, Pointer<Uint8> dst, int n) {
  final view = dst.asTypedList(n);
  if (src is Uint8List) {
    // setRange indexes the view's own bytes: offsetInBytes is honoured.
    view.setRange(0, n, src, off);
  } else {
    for (var i = 0; i < n; i++) {
      view[i] = src[off + i];
    }
  }
}

const String _hexDigits = '0123456789abcdef';

String _hexOf(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(_hexDigits[(b >> 4) & 0xf])
      ..write(_hexDigits[b & 0xf]);
  }
  return out.toString();
}
