# Second Review: Card K2 (`ssdp.dart`, `upnp_igd.dart`, `nat_pmp.dart`, `pcp.dart`)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K2/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Entry Points:**
  1. Multicast UDP datagrams received during SSDP M-SEARCH discovery.
  2. HTTP responses to `LOCATION` XML fetches from local network endpoints.
  3. SOAP XML responses to UPnP action requests (`WANIPConnection`).
  4. UDP datagrams received in response to NAT-PMP and PCP requests.
- **Attacker Goals:**
  1. **SSRF via SSDP:** Force the application to send HTTP GET/POST requests with arbitrary payloads to cloud metadata endpoints (`169.254.169.254`) or internal HTTP administration services.
  2. **XXE / Billion Laughs:** Exploit XML parser to read local filesystem files (`/etc/passwd`, Windows SAM) or trigger out-of-memory denial of service via recursive entity expansion.
  3. **Port Hijacking / Persistent Opening:** Cause external ports on the victim's router to remain permanently forwarded to internal ports after the application closes.
  4. **SOAP Action Spoofing:** Trick client into invoking dangerous SOAP actions on unrelated LAN devices.

---

## 2. Attack Attempts & Verification

### Attack 1: SSDP SSRF Redirect to Cloud Metadata
- **Vector:** Attacker broadcasts SSDP response with `LOCATION: http://192.168.1.1:8080/desc.xml`. When fetched, attacker server responds with `HTTP/1.1 302 Found` and `Location: http://169.254.169.254/latest/meta-data/`.
- **Result:** `SsdpClient` explicitly disables redirects:
  ```dart
  final client = HttpClient();
  final req = await client.getUrl(uri);
  req.followRedirects = false;
  ```
  The 302 response is returned directly without following the redirect. The payload does not contain valid IGD device XML, and the fetch fails safely.
- **Finding:** SAFE.

### Attack 2: XXE Entity Expansion & External Entity Retrieval
- **Vector:** Hostile IGD gateway returns XML device description containing:
  ```xml
  <?xml version="1.0"?>
  <!DOCTYPE lolz [
   <!ENTITY file SYSTEM "file:///etc/passwd">
  ]>
  <root><device><friendlyName>&file;</friendlyName></device></root>
  ```
- **Result:** `SsdpClient` inspects the raw XML string before passing it to any DOM parser:
  ```dart
  if (body.contains('<!DOCTYPE') || body.contains('<!ENTITY')) {
    return null;
  }
  ```
  The payload is immediately rejected, returning `null`. No entity expansion or local file read can execute.
- **Finding:** SAFE.

### Attack 3: SOAP Control URL Hijacking (Cross-Origin Control)
- **Vector:** Hostile IGD XML returns `controlURL: http://192.168.1.50:9000/trigger_malware`.
- **Result:** `_extractControlUrl` enforces that the control URL must resolve to the identical origin (host and port) as the original `LOCATION` URL:
  ```dart
  final resolved = baseUri.resolve(controlPath);
  if (resolved.host != baseUri.host || resolved.port != baseUri.port) {
    return null; // Cross-origin control URL rejected
  }
  ```
  Any attempt to point the control URL to an external or different LAN host is refused.
- **Finding:** SAFE.

### Attack 4: Orphan Port Mapping on Crashed / Aborted Share
- **Vector:** Application process is stopped or interrupted while an active UPnP port mapping exists on the home router.
- **Result:**
  1. `UnifiedPortMapper` requests bounded leases (default 3600 seconds, 1 hour).
  2. `UnifiedPortMapper.sweepStale()` checks and cleans up mappings matching `LibreShare:` descriptions.
  3. `UnifiedPortMapper.close()` iterates over all registered mappings and invokes `DeletePortMapping`.
- **Finding:** SAFE.

---

## 3. Residual Risk / Final Deep Review Notes
- Ensure that in CLI and UI, the port mapping feature defaults to **OFF** (per D1 security guideline) so that users explicitly consent before any UPnP or NAT-PMP port forwarding request is issued to their router.
