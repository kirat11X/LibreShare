/// `POST /api/v1/register` to a peer that just announced itself (spec §4.2
/// rule 2: "reply POST to /api/v1/register on the peer; if it fails in 2 s,
/// reply UDP unicast announce:false"). Provides the [PeerRegistrar] callback
/// used by the multicast listener.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../client/api_client.dart';
import '../client/peer_client.dart';
import '../model/device.dart';
import '../security/contracts.dart';
import 'device_discovery.dart';

class ApiPeerRegistrar {
  /// Pass the instance's [call] tear-off wherever a [PeerRegistrar] is wanted
  /// (`registrar: ApiPeerRegistrar(self: ...).call`).
  ///
  /// [self] is evaluated on every call so the registration always carries the
  /// current alias and addresses. [clientFactory] (tests) may return any
  /// [PeerClient]; it is called with the peer's address and announced port and
  /// the client it returns is always closed.
  ApiPeerRegistrar({
    required this._self,
    this.timeout = const Duration(seconds: 2),
    this.https = false,
    this._clientFactory,
    this.security = const SecurityConfig.plaintext(),
    this.onCertificate,
  });

  /// Secure profile: HTTPS only, server pinned to the fingerprint it announced
  /// (checked at the handshake, before any HTTP byte), `X-LS-Auth` on the
  /// request, and the answer's fingerprint must equal the pin. A peer that
  /// announced no fingerprint is never contacted. Never falls back to HTTP.
  final SecurityConfig security;

  /// Secure profile: receives the DER of the certificate of a peer that passed
  /// every check (so a later `bye` can be verified).
  final void Function(Uint8List certDer)? onCertificate;

  final DeviceInfo Function() _self;

  /// Overall budget for the call (connect + request + response).
  final Duration timeout;

  /// Use `https://` for the default client (Increment 3 with TLS).
  final bool https;
  final PeerClient Function(String host, int port)? _clientFactory;

  /// Registers us with [peer] at [address] on the peer's announced port.
  /// Returns true on a 2xx answer; false on anything else (4xx/5xx, refused,
  /// unreachable, timeout, malformed answer, bad address). Never throws and
  /// never leaves the client open. Nothing is logged: the peer's data is not
  /// ours to echo.
  Future<bool> call(DeviceInfo peer, String address) async {
    final port = peer.port;
    if (port < 1 || port > 65535 || InternetAddress.tryParse(address) == null) {
      return false;
    }
    PeerClient? client;
    try {
      if (security.isSecure) return await _callSecure(peer, address, port);
      client =
          _clientFactory?.call(address, port) ??
          ApiClient(
            host: address,
            port: port,
            https: https,
            connectTimeout: timeout,
            requestTimeout: timeout,
          );
      await client.register(_self()).timeout(timeout);
      return true;
    } on Object {
      return false;
    } finally {
      try {
        client?.close();
      } on Object {
        // closing must never turn into an error for the caller
      }
    }
  }

  Future<bool> _callSecure(DeviceInfo peer, String address, int port) async {
    final pin = peer.fingerprint.toUpperCase();
    if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(pin)) return false; // legacy peer
    final ApiClient client = ApiClient(
      host: address,
      port: port,
      https: true,
      security: security,
      expectedFingerprint: pin,
      connectTimeout: timeout,
      requestTimeout: timeout,
    );
    try {
      final answer = await client.register(_self()).timeout(timeout);
      if (answer.fingerprint.toUpperCase() != pin) return false;
      if (client.serverFingerprint != pin) return false;
      final der = client.serverCertificateDer;
      if (der != null) {
        try {
          onCertificate?.call(der);
        } on Object {
          // a faulty callback must not turn a success into a failure
        }
      }
      return true;
    } finally {
      client.close();
    }
  }
}
