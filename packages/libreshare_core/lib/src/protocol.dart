/// LSP/1 protocol constants (spec §4.1).
library;

const int kChunkSize = 4 * 1024 * 1024; // 4 MiB
const int kDefaultPort = 53318;
const int kPortFallbackMax = 53327;
const String kProtocolName = 'libreshare';
const String kProtocolVersion = '1.0';

/// Version a device in the secure (TLS + signed proof) profile reports in `/info` and announces.
/// [kProtocolVersion] stays '1.0' for the plaintext profile so the Inc 1 conformance tests and
/// legacy peers are untouched (docs/plans/inc3.md section 3; deviation recorded in the Outcome). [I3]
const String kProtocolVersionSecure = '1.1';
const String kApiPrefix = '/api/v1';
const String kMulticastGroup = '224.0.0.168';
const int kMaxJsonBytes = 256 * 1024;

/// POST /sessions only (10,000 files x ~260 B); every other body stays at [kMaxJsonBytes]. [I3]
const int kMaxSessionJsonBytes = 4 * 1024 * 1024;
const int kMaxFilesPerSession = 10000;
const int kChunkRetries = 3;
const Duration kPermissionTimeout = Duration(seconds: 120);
const String kChunkHashHeader = 'x-ls-chunk-sha256';

/// Request header carrying the signed identity proof (docs/plans/inc3.md D1, section 3 item 3). [I3]
const String kAuthHeader = 'x-ls-auth';

/// How long the receiver waits for the sender to reveal its SAS nonce (D4). [I3]
const Duration kSasRevealTimeout = Duration(seconds: 30);

/// POST /pair is held open until the inviter decides (D13). [I3]
const Duration kPairTimeout = Duration(seconds: 125);

/// Signed proof timestamp window (D9). [I3]
const Duration kAuthWindow = Duration(seconds: 120);
