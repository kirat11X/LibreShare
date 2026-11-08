/// LibreShare pure-Dart core (no Flutter imports — enforced by CI).
library;

export 'src/clock.dart';
export 'src/protocol.dart';
export 'src/model/device.dart';
export 'src/model/events.dart';
export 'src/model/file_item.dart';
export 'src/model/ls_exception.dart';
export 'src/model/session_models.dart';
export 'src/model/transfer_status.dart';
export 'src/transfer/chunker.dart';
export 'src/server/incoming_transfer_handler.dart';
export 'src/client/peer_client.dart';
export 'src/transfer/hashing.dart';
export 'src/transfer/speed_mode.dart';
export 'src/transfer/manifest.dart';
export 'src/transfer/file_sender.dart';
export 'src/transfer/filename_sanitizer.dart';
export 'src/transfer/resume_store.dart';
export 'src/transfer/file_receiver.dart';
export 'src/server/api_server.dart';
export 'src/server/rate_limiter.dart';
export 'src/client/api_client.dart';
export 'src/engine/libreshare_engine.dart';
export 'src/discovery/device_discovery.dart';
export 'src/discovery/mdns_backend.dart';
export 'src/discovery/network_interfaces.dart';
export 'src/discovery/announce_codec.dart';
export 'src/discovery/peer_registry.dart';
export 'src/discovery/multicast_transport.dart';
export 'src/discovery/multicast_discovery.dart';
export 'src/discovery/subnet_scanner.dart';
export 'src/discovery/manual_peer.dart';
export 'src/discovery/peer_registrar.dart';
export 'src/receive/receive_state.dart';
export 'src/receive/receive_gate.dart';
export 'src/receive/receive_scheduler.dart';
export 'src/receive/receive_settings.dart';
export 'src/receive/receive_controller.dart';
export 'src/storage/receive_settings_store.dart';
export 'src/engine/discovery_config.dart';
export 'src/engine/outgoing_send.dart';
export 'src/engine/security_wiring.dart';
export 'src/security/contracts.dart';
export 'src/storage/file_secret_store.dart'
    show
        FileSecretStore,
        InMemorySecretStore,
        SecretStoreException,
        ChmodRunner,
        isValidSecretName;
export 'src/storage/credential_store.dart';
export 'src/storage/device_registry.dart';
export 'src/security/trust_store.dart';
// sha256Hex is hidden: the legacy test helper test/helpers/api_fake_handler.dart defines its own and
// existing tests import both. Security code imports it from src/security/crypto_primitives.dart.
export 'src/security/crypto_primitives.dart' hide sha256Hex;
export 'src/security/cert_factory.dart'
    show
        GeneratedIdentity,
        generateIdentity,
        generateIdentityFor,
        parseCertificate,
        ParsedCertificate,
        CertificateFormatException,
        KeyFormatException,
        kMaxCertDerBytes;
export 'src/security/identity_proof.dart';
export 'src/security/sas.dart';
export 'src/security/key_identity.dart';
export 'src/security/tls_context.dart';
export 'src/security/pin_guard.dart';
export 'src/security/pairing_service.dart';
export 'src/client/peer_security_exceptions.dart';
export 'src/connection/candidate.dart';
export 'src/connection/connection.dart';
export 'src/connection/connection_manager.dart';
export 'src/connection/http_connection.dart';
export 'src/monitor/channel_event.dart';
export 'src/monitor/event_record.dart' hide shortFingerprint;
export 'src/monitor/event_log.dart';
export 'src/storage/session_record.dart';
export 'src/storage/session_store.dart';
export 'src/transfer/idle_timeout_manager.dart';
export 'src/transfer/receiver_adoption_helper.dart';

export 'src/security/tunnel_crypto.dart';

export 'src/share/share_link.dart';

export 'src/security/secret_redactor.dart';

export 'src/tunnel/tunnel_provider.dart';
export 'src/model/origin_candidate.dart';
export 'src/model/share_models.dart';

export 'src/tunnel/fake_tunnel_provider.dart';
export 'src/server/tunnel_origin_server.dart';

export 'src/share/link_share.dart';
export 'src/share/share_store.dart';

export 'src/connection/origin_pull_connection.dart';
export 'src/connection/tunnel_connection.dart';

export 'src/tunnel/binary_installer.dart';
export 'src/tunnel/cloudflared_provider.dart';
export 'src/tunnel/cloudflared_versions.dart';
export 'src/tunnel/manual_url_provider.dart';
export 'src/tunnel/process_supervisor.dart';
export 'src/tunnel/zrok_provider.dart';
export 'src/rendezvous/records.dart';
export 'src/rendezvous/rendezvous_backend.dart';
export 'src/rendezvous/channel_deriver.dart';
export 'src/rendezvous/envelope_codec.dart';
export 'src/rendezvous/rendezvous_service.dart';
export 'src/rendezvous/rendezvous_candidate_source.dart';
export 'src/rendezvous/replay_guard.dart';
export 'src/rendezvous/in_memory_relay.dart';
export 'src/rendezvous/bip340.dart';
export 'src/rendezvous/nip01.dart';
export 'src/rendezvous/loopback_nostr_relay.dart';
export 'src/rendezvous/nostr_backend.dart';
export 'src/rendezvous/presence_cache.dart';
export 'src/rendezvous/rendezvous_service_impl.dart';
export 'src/rendezvous/ntfy_backend.dart';
