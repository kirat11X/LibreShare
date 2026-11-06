# ADR 0002: The connection ladder is an ordered list of candidates, not radio technologies

- Status: accepted
- Date: 2026-11-03
- Spec: `docs/LIBRESHARE_BUILD_SPEC.md` sections 2 (feasibility), 6, 7 and Recommendations #1

## Context

The original idea was a fallback chain "WiFi (Wi-Fi Direct) -> LAN -> Internet". Programmatic Wi-Fi Direct is not available on macOS/iOS (AWDL is private and cannot be implemented without driver-level access), needs native C++/WinRT and a capability on Windows, is driver-dependent on Linux, and works on Android only through `WifiP2pManager`/`LocalOnlyHotspot` with runtime permissions. A design that depends on a specific radio would be untestable in CI and would fail for evaluators and users on half of the target platforms. What every platform can do is open sockets to an address it can reach.

## Decision

Model the ladder as ordered connection **candidates**, as ICE does, where each tier is a path, not a radio:

| Tier | Class | Meaning | Candidates |
|---|---|---|---|
| 1 | `WiFiConnection` | Direct mTLS HTTPS to the peer over the shared WLAN (stretch: a LibreShare-created hotspot) | peer `addrs` with `if:"wifi"`, hotspot gateway |
| 2 | `LANConnection` | Every other local path: Ethernet, second NIC, other private subnet, IPv6 link-local, manual/QR address | remaining `addrs` plus manual |
| 3 | `TunnelConnection` | Sender-hosted, end-to-end-encrypted (AES-256-GCM) origin reached through a Cloudflare Quick Tunnel (zrok backup); the receiver pulls | `tunnelOffer.url` |

`ConnectionManager` (module 4.0) walks the ladder: `connect()` tries each tier (same-tier candidates raced, 3 s connect, 8 s tier budget); on 3 consecutive chunk failures, a connection error, or two failed `GET /info` probes in 4 s the session calls `fallbackToNext()`, which activates the next available tier and resynchronises from `GET .../files/{fid}/state` so that no acknowledged chunk is re-sent. If no tier is healthy for 120 s the session becomes `FAILED(NO_CONNECTION)` and its state is kept for 24 h. `TransferStatus` keeps only the four UML states; the cause is a `FailureReason`.

The tunnel is pre-warmed for desktop senders of sessions larger than 50 MB and travels in `tunnelOffer` inside the authenticated channel, so the provider never learns the key. It is not used while a local tier is healthy (NFR-06). The names "WiFi" and "LAN" are kept for the UI badge (Wi-Fi / LAN / Internet) and the UML, with an SRS addendum stating that they denote path tiers.

## Consequences

- Positive: behaviour is identical on every OS and testable headlessly: Docker networks `wifi_net`, `lan_net`, `inet_net` plus `tc netem` reproduce "cut Wi-Fi, switch to LAN, then Internet" (FR-12, FR-13, FR-14), and the in-process `FaultyTcpProxy` covers the rest. Radio-specific modes (hotspot, Wi-Fi Direct) become optional candidate sources rather than architectural dependencies.
- Positive: adding a new path (BLE-assisted address exchange, hotspot, a self-hosted relay) means adding a candidate source or a `Connection` subclass, not changing the manager.
- Negative: the product cannot claim literal Wi-Fi Direct or AirDrop-style radio features; evaluators who expect them need the SRS addendum (risk table, section 16).
- Negative: the ladder depends on correct candidate generation (`NetworkInterface`, `network_info_plus`); campus AP/client isolation can leave only the tunnel, which is mitigated by QR/manual addresses, a phone hotspot, and the tunnel link.
- Negative: relying on Quick Tunnels carries availability and terms risk (no SLA, 429/1015); mitigated by a zrok backup, `FakeTunnelProvider` in CI, self-hosting docs and an early recorded live test.
- The protocol remains transport-agnostic: the same chunk and resume semantics (`/state`, inclusive ranges, idempotent PUT) apply on every tier, with the tunnel origin API (LSP-1 section 4.5) carrying sealed equivalents.
