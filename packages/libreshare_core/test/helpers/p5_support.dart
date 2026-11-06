// Small shared builders for the P5 client/sender tests.
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';

/// A fresh identity (key + self-signed certificate). [now] backdates or postdates the certificate
/// (the validity window is `now - 24 h` .. `now + 3650 d`).
KeyIdentity newIdentity(String deviceId, {DateTime? now}) =>
    KeyIdentity.fromGenerated(generateIdentity(deviceId: deviceId, now: now));

/// Secure profile configuration around [identity].
SecurityConfig secureConfig(
  IdentityProvider identity, {
  bool allowInsecurePeers = false,
}) => SecurityConfig.tls(
  identity: identity,
  trust: InMemoryTrustStore(),
  allowInsecurePeers: allowInsecurePeers,
);

/// Secure-profile [ApiClient] to a loopback peer. [pin] null = first contact.
ApiClient secureClient(
  int port,
  SecurityConfig security, {
  String? pin,
  Duration requestTimeout = const Duration(seconds: 10),
}) => ApiClient(
  host: '127.0.0.1',
  port: port,
  security: security,
  expectedFingerprint: pin,
  requestTimeout: requestTimeout,
  connectTimeout: const Duration(seconds: 3),
);

/// Lets a late packet or a late callback show up (<= 200 ms, loopback only).
Future<void> settle([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// 64 consecutive hex characters: a full fingerprint or hash.
final RegExp fullHex = RegExp(r'[0-9A-Fa-f]{64}');

/// A one-file `POST /sessions` body whose file name is [sentinel], so a test can look for those
/// bytes on the wire.
SessionRequest sampleRequest(
  DeviceInfo sender, {
  String sentinel = 'SENTINEL-FILE-NAME.bin',
  String? sasCommit,
}) => SessionRequest(
  sender: sender,
  sasCommit: sasCommit,
  files: [FileItem(fileId: 'f1', fileName: sentinel, size: 3, chunkCount: 1)],
  totalSize: 3,
);
