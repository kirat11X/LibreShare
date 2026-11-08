# Increment 7 Seams: BLE Discovery & Hotspot Handoff ("LS-BLE/1")

Status: **Wave 0 Contract Specification**  
Date: 2026-11-07  
Authors: LibreShare Architecture Lead & Orchestrator  
Related: `docs/design/03-ble-hotspot.md`, `docs/plans/inc7.md`, `docs/protocol/LSP-1.md`, ADR 0002

---

## 1. Architectural Overview & Boundaries

Increment 7 introduces **LS-BLE/1**, providing local out-of-band peer discovery and automated ad-hoc Wi-Fi hotspot connection handoffs.

### Key Architectural Invariants
1. **Control-Plane Only**: Bluetooth Low Energy carries only discovery beacons, encrypted session negotiation, consent prompts, and network connection parameters. File data chunks are **NEVER** transmitted over BLE.
2. **IP Transport Preservation**: All file transfers run over standard LSP/1 mTLS sessions using standard TCP sockets.
3. **Strict Consent Prior to Disruption**: Starting or joining a Wi-Fi hotspot frequently interrupts a device's internet uplink. No hotspot may ever be started or joined without explicit user approval.
4. **Fast LAN Bypass**: If both peers share a local Wi-Fi router (e.g. multicast or mDNS blocked by AP isolation), peers exchange local LAN IP addresses over the encrypted BLE channel. If direct LAN connectivity succeeds, the transfer proceeds over standard LAN without activating a hotspot.
5. **No Long-Lived Identifiers in Beacons**: Beacons carry only a rotating 8-byte Ephemeral ID (EID) derived via HMAC-SHA256 from a shared `advKey` across 15-minute epochs ($\pm 1$ tolerance). Unpaired beacons emit random EIDs. Device names and certificate fingerprints are never broadcast.

---

## 2. Integration Seams with Core Subsystems

```
                                      +-------------------------+
                                      |      LibreShareEngine   |
                                      +------------+------------+
                                                   |
                     +-----------------------------+-----------------------------+
                     |                             |                             |
                     v                             v                             v
           +--------------------+        +--------------------+        +--------------------+
           |     BleBackend     |        |   HotspotBackend   |        | ConnectionManager  |
           +---------+----------+        +---------+----------+        +---------+----------+
                     |                             |                             |
      +--------------+--------------+              |                             |
      |                             |              |                             |
      v                             v              v                             v
+------------+               +------------+  +------------+             +-------------------+
| Advertiser |               |  Scanner   |  | AP / Join  |             |  HotspotCandidate |
+------------+               +------------+  +------------+             +-------------------+
```

### Seam 1: `PeerRegistry` & Discovery Engine
- Discovered BLE devices enter `PeerRegistry` tagged with `DiscoverySource.ble`.
- Scan results parse manufacturer data (`0xFFFF`, magic `LS`).
- Known peers: Scanners evaluate trusted peer `advKey` secrets against EID across epochs $\{t-1, t, t+1\}$. Matching EID resolves directly to the trusted contact's identity.
- Unknown peers: Emitted as anonymous "Nearby Device" with platform icon and RSSI.

### Seam 2: `TrustStore` & Key Exchange
- On "Trust this device" / pairing:
  Peers call `PUT /api/v1/peers/ble-key` over mTLS carrying `{"advKey": "<b64url-32-bytes>"}`.
- `TrustStore` persists `peerAdvKey` alongside pinned certificate fingerprints.
- Revoking trust rotates the local `advKey` and broadcasts updates to remaining trusted contacts.

### Seam 3: GATT Secure Channel State Machine
- Service UUID: `fc7a9155-e024-4269-82a6-433dab94653e`
- Characteristics: RX `...653f`, TX `...6540`.
- Handshake:
  1. `M1`: Central sends ephemeral X25519 pubkey + 16-byte nonce.
  2. `M2`: Peripheral replies with ephemeral X25519 pubkey + 16-byte nonce.
  3. Shared Secret & Transcript: $ss = \text{X25519}(priv, epk)$, $th = \text{SHA256}(\text{"LSBLE1"} \parallel M1 \parallel M2)$.
  4. Keys: $k_{C2P}, k_{P2C} = \text{HKDF-SHA256}(ss, salt=th, info=\text{"LSBLE1-keys"}, 64)$.
  5. `AUTH`: Encrypted exchange of persistent identity certificate DER and ECDSA signature over transcript.
  6. SAS verification: Unpaired connections require identical 6-digit SAS confirmation before proceeding.

### Seam 4: `ConnectionManager` & `HotspotCandidate`
- `Candidate` gains asynchronous lifecycle hooks:
  - `Duration get setupBudget`: (90s for joiner, 10s for host, 0s for LAN/direct).
  - `Duration get connectBudget`: (3-5s for mTLS socket connect).
  - `Future<void> setup()`: Triggers AP creation or network joining.
  - `Future<void> teardown()`: Reverts network state to previous profiles.
- `CandidateKind.hotspot`:
  - Cost hint: 15 (preferred over internet relay tunnels [100], deferred after direct LAN [10]).
  - If a hotspot dies mid-transfer, `ConnectionManager.fallbackToNext()` resumes transfer on alternative tiers without re-sending acknowledged chunks.

---

## 3. LSP/1.1 Additions

### Additive Wire Fields
1. **Capabilities Token**: `caps` array in announcement and info includes `"ble1"`.
2. **Offer Identifier**: `SessionRequest` carries optional `offerId` (16 bytes base64).
3. **Immediate Session Binding**: When `SessionRequest.offerId` matches an accepted `BleOffer` with verified peer certificate fingerprint, receiver immediately yields `200 IN_PROGRESS` without re-prompting user.

### API Endpoints
- `PUT /api/v1/peers/ble-key`:
  Authenticated mTLS endpoint to exchange rotating beacon derivation keys.
  Request body: `{"advKey": "<b64url 32 bytes>"}`.
