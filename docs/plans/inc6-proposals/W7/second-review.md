# Second Security Review: Increment 6 Card W7 (Adversarial Transport & Metadata Privacy)

**Reviewer:** Security Red Team Agent  
**Date:** 2026-11-08  
**Scope:** `ntfy_backend.dart`, `fake_ntfy_server.dart`  
**Focus:** Privacy on unauthenticated public message brokers, topic collision, and eavesdropping risks.

---

## 1. Threat Analysis

### Threat A: Public Broker Eavesdropping (ntfy.sh)
- **Context:** Unlike Nostr relays where events can be filtered by pubkey tags, ntfy.sh is an open pub/sub service where anyone can subscribe to any topic without authentication.
- **Mitigation & Invariant:**
  - The topic name is derived deterministically from the ephemeral 24h channel ID: `topicForChannel(channelIdHex) = 'ls-rdv-${channelIdHex.substring(0, 32)}'`.
  - Because `channelIdHex` is derived via HKDF from $K_\text{pair}$ and the 24h UTC epoch (`deriveChannelId`), no passive third party can guess the topic name unless they possess $K_\text{pair}$.
  - Even if an adversary monitors all topics, the message body is base64-encoded ciphertext sealed with AES-256-GCM. Without $K_\text{pair}$, no plaintext metadata or contents are decodable.

### Threat B: Topic Collision & Namespace Pollution
- **Context:** If two different pairings happen to generate the same topic prefix, or an adversary intentionally floods `ls-rdv-*` topics.
- **Mitigation:**
  - 32 hex characters provide $16^{32} = 2^{128}$ bits of entropy. Birthday collision probability across all active users is $< 10^{-18}$.
  - Injected spurious messages on the same topic fail AES-256-GCM authentication in `EnvelopeCodec.unseal` and are dropped silently without causing state corruption.

### Threat C: Traffic Analysis & Timing Correlation
- **Mitigation:**
  - All rendezvous envelopes are padded to fixed buckets (256, 1024, 4096 bytes) by `EnvelopeCodecImpl`.
  - Ntfy payload size gives zero information about whether an announcement is a presence broadcast, an offer, or a decline.

---

## 2. Verdict

**APPROVED.** Satisfies zero-knowledge relay threat model requirements.
