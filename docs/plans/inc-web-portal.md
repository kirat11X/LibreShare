# Increment Web Portal - Zero-Install Browser Interoperability (Web Share Mode)

Status: **PLAN APPROVED BY ORCHESTRATOR**.
Role breakdown follows CLAUDE.md:
- **Orchestrator**: Writes plan & contracts, spawns subagents, gates with real exit codes. Writes no feature code.
- **Tester Agent**: Writes tests FIRST from seams doc, verifies they are RED. Later performs mutation checks and flake verification.
- **Coder Agent**: Implements the contracts under `packages/libreshare_core/lib/src/web_portal/` until tests are GREEN. Never alters tests.

---

## 1. Objective & Scope

Allow a native LibreShare device (Android, Linux, Windows, macOS) to exchange files with any peer on the same network using only a standard web browser (Chrome, Safari, Firefox, Edge) with zero software installation required on the browser side.

### In Scope:
1. **Embedded Web Portal Service (`WebPortalService` / `WebPortalHandler`)**:
   - HTTP server running locally on the native device (configurable port, default fallback).
   - Serves an embedded, self-contained, responsive HTML5/CSS3/JavaScript web application (no CDNs, works completely offline on local Wi-Fi).
2. **Web Download**:
   - Displays list of active files offered for download by the native device.
   - Direct download endpoint (`GET /web/download/:fileId`) with `Content-Disposition`, `Content-Length`, `Accept-Ranges: bytes`, and HTTP 206 Partial Content support for large file streaming.
3. **Web Upload**:
   - Drag-and-drop and file-picker upload from the browser directly to the native device (`POST /web/api/upload`).
   - Supports single and multiple file uploads.
   - Robust path-traversal protection (`../`, absolute paths, null bytes, Windows reserved names).
   - Safe file naming collision handling (`(1)`, `(2)`, etc.).
4. **Security & Session Control**:
   - Optional PIN verification: when enabled, browser clients must enter a 4- or 6-digit PIN displayed on the native device before downloading or uploading.
   - Session tokens: valid PIN grants a session cookie/header.
   - Maximum upload size enforcement & concurrency limits.
   - Security response headers (`X-Content-Type-Options: nosniff`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`).
5. **Pure Dart Core**:
   - Resides strictly in `packages/libreshare_core/lib/src/web_portal/`.
   - Zero Flutter imports.

---

## 2. API Endpoints Specification

All routes are mounted under `/web`:

| Route | Method | Purpose | Auth Required |
|---|---|---|---|
| `/web` or `/web/` | `GET` | Serves the standalone HTML/JS/CSS Web Portal Single-Page App | No |
| `/web/api/info` | `GET` | Returns JSON: device name, version, pinRequired, active shared files summary | No |
| `/web/api/auth` | `POST` | Validates entered PIN: `{ "pin": "1234" }` -> sets session / returns auth token | No |
| `/web/api/files` | `GET` | Returns JSON list of available files to download | If PIN enabled |
| `/web/download/<fileId>` | `GET` | Streams file content to browser (supports Range headers) | If PIN enabled |
| `/web/api/upload` | `POST` | Receives multipart or octet-stream upload from browser | If PIN enabled |

---

## 3. Security Requirements

1. **Path Traversal Prevention**:
   - Filenames from uploads must be stripped of any directory components (`/`, `\`, `..`).
   - Any upload attempting to escape the designated receive folder throws or is sanitized to a flat basename.
2. **Pin Protection**:
   - Constant-time comparison or salted hashing for PIN validation to prevent timing attacks.
   - Rate limiting on failed PIN attempts (max 5 failed attempts per minute per IP).
3. **Safe File Collision**:
   - Files with existing names in the downloads folder are renamed safely rather than silently overwritten (e.g. `report (1).pdf`).
4. **Resource Bounds**:
   - Streamed chunk handling prevents buffer bloat in RAM.
   - Configurable max file size limit.
