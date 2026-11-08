// Candidate source mapping rendezvous presence records into ConnectionManager candidates.
library;

import '../connection/candidate.dart';
import 'records.dart';

/// Adapter converting incoming [PresenceRecord] candidate entries into [Candidate] objects.
class RendezvousCandidateSource {
  const RendezvousCandidateSource();

  /// Converts candidates from [presence] for [peerFingerprint] into [Candidate] list.
  List<Candidate> candidatesFromPresence({
    required PresenceRecord presence,
    required String peerFingerprint,
  }) {
    final results = <Candidate>[];
    for (final raw in presence.candidates) {
      final host = raw['host'] as String?;
      final port = raw['port'] as int?;
      final kindStr = raw['kind'] as String? ?? 'manual';
      if (host == null || port == null || port <= 0 || port > 65535) {
        continue;
      }

      final CandidateKind kind;
      final int costHint;
      if (kindStr == 'directIpv6') {
        kind = CandidateKind.manual;
        costHint = 15;
      } else if (kindStr == 'mappedIpv4') {
        kind = CandidateKind.manual;
        costHint = 25;
      } else if (kindStr == 'tunnel') {
        kind = CandidateKind.tunnel;
        costHint = 100;
      } else {
        kind = CandidateKind.manual;
        costHint = 35;
      }

      results.add(
        Candidate(
          id: 'rdv:$kindStr:$host:$port',
          kind: kind,
          host: host,
          port: port,
          peerFingerprint: peerFingerprint,
          costHint: costHint,
        ),
      );
    }
    return results;
  }
}
