# ADR 0003: No hole punching or WebRTC in the connection ladder

- Status: accepted
- Date: 2026-11-06
- Spec: `docs/design/02-free-rendezvous.md` section 3.7, `docs/plans/inc6.md`

## Context

Increment 6 introduces free internet rendezvous and presence for paired devices across networks. Two primary mechanisms were considered for direct data transfer when peers are on different private networks without a direct route:
1. **Interactive Connectivity Establishment (ICE) / UDP hole punching (STUN/TURN)** or WebRTC.
2. **TCP simultaneous open**.

An empirical and architectural evaluation of hole punching revealed:
- **Transport mismatch:** LibreShare's transport protocol (LSP-1) is HTTPS/TCP with TLS 1.3 authentication. Pure Dart does not include an in-tree QUIC implementation (`RawDatagramSocket` is available, but building a reliable, congestion-controlled, encrypted transport in pure Dart represents enormous scope and security risk).
- **Failure rates & CGNAT:** Real-world measurements (IPFS DCUtR across 4.4M attempts) demonstrate hole punching failure rates around 30% even when signaling succeeds. Furthermore, over 90% of cellular networks and 18% of consumer ISPs operate behind Carrier-Grade NAT (CGNAT, RFC 6598), where port allocation behavior (symmetric NAT / address-dependent mapping) inherently defeats hole punching without relay fallback (TURN).
- **Cost constraint ($0):** Operating public TURN servers violates the $0 zero-marginal-cost architectural principle (NFR-10).

## Decision

1. **No hole punching or WebRTC in v1:** LibreShare will not implement UDP hole punching or WebRTC data channels for Increment 6.
2. **Candidate ladder integration:** Rendezvous is modeled as an out-of-band **candidate source**, not a distinct transport. When paired devices signal over Nostr/ntfy rendezvous channels:
   - Direct global unicast candidates (IPv6 and UPnP/NAT-PMP port mappings from Increment 5b) are exchanged and raced directly.
   - If direct paths are blocked by symmetric NAT or firewall policies, connections cleanly fall back to sender-hosted end-to-end encrypted tunnels (`TunnelOffer` via Cloudflare Quick Tunnels or zrok, as defined in Increment 5).
3. **Extensibility preservation:** `CandidateKind.reflexive` remains reserved and representable in data models so that future reflexive STUN traversal can be introduced without breaking wire compatibility.

## Consequences

- **Positive:** Zero server operating costs ($0 forever); no dependency on third-party TURN servers.
- **Positive:** Reliable data integrity and resume semantics over standard HTTPS/TCP and TLS 1.3.
- **Positive:** Clean failure modes: peers either connect directly (IPv6/port mapping) or pull through encrypted tunnels without prolonged hanging hole-punch negotiations.
- **Negative:** Transfer speed between two peers both behind CGNAT without IPv6 relies entirely on free tunnel relays (Cloudflare/zrok rate limits apply).
