# syntax=docker/dockerfile:1
#
# LibreShare headless node (user-facing image): the AOT-compiled CLI running `receive` as a
# service, i.e. a "drop box" that stays up, receives into /data and can also send.
#
#   build context : the repository root (see compose.linux.yaml / compose.windows.yaml)
#   ignore rules  : deploy/docker/Dockerfile.dockerignore (allow-list)
#   result        : libreshare/node:local
#
# This is NOT the end-to-end test image (tools/docker/Dockerfile): no iproute2/iptables/jq, no
# test scripts, no tools of any kind in the runtime stage.
#
# The repo root is a pub WORKSPACE whose pubspec also lists apps/libreshare_app. That member needs
# the Flutter SDK, which the official `dart` image does not have, and the app is not in the build
# context at all. So the build stage trims every `apps/...` line out of the root `workspace:` list
# (same proven trick as tools/docker/Dockerfile; the first layers are textually identical, so the
# slow `pub get` layer is shared with that image's build cache).

ARG DART_VERSION=3.13.7

# ------------------------------------------------------------------ build
FROM dart:${DART_VERSION} AS build
WORKDIR /src

# 1) Manifests only -> the (slow) `pub get` layer is cached until a pubspec changes.
COPY pubspec.yaml pubspec.lock* ./
COPY packages/libreshare_core/pubspec.yaml packages/libreshare_core/pubspec.yaml
COPY packages/libreshare_cli/pubspec.yaml packages/libreshare_cli/pubspec.yaml
RUN sed -i -E '/^[[:space:]]*-[[:space:]]*(\.\/)?apps\//d' pubspec.yaml \
 && echo '--- trimmed workspace pubspec ---' && cat pubspec.yaml \
 && dart pub get

# 2) Sources, then the native executable.
COPY packages/ packages/
RUN dart pub get --offline \
 && mkdir -p /out \
 && dart compile exe packages/libreshare_cli/bin/ls.dart -o /out/libreshare

# ---------------------------------------------------------------- runtime
# Same Debian release as the dart image (13 "trixie"), so the AOT binary finds a matching glibc.
# Nothing is installed with apt: the binary needs only libc, and the entrypoint/healthcheck need
# only /bin/sh and the binary itself.
FROM debian:trixie-slim AS runtime

ARG LS_VERSION=0.1.0-proto1
LABEL org.opencontainers.image.title="LibreShare headless node" \
      org.opencontainers.image.description="LibreShare prototype: AOT CLI running 'receive' as a service (drop box). Plain HTTP, no TLS/PIN yet." \
      org.opencontainers.image.version="${LS_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="LibreShare" \
      dev.libreshare.component="headless-node" \
      dev.libreshare.project="libreshare"

# Non-root. /data (received files) and /config (state, reserved for Increment 3) are world-writable
# so that the same image works with any uid: compose runs it as the host user (`user:`), so that
# files received into a bind-mounted folder belong to you, and named volumes are initialised from
# these modes. The container has one process and no capabilities; the modes are not a boundary.
RUN useradd --system --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin libreshare \
 && mkdir -p /data /config \
 && chown libreshare:libreshare /data /config \
 && chmod 0777 /data /config

COPY --from=build /out/libreshare /usr/local/bin/libreshare
COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
# A Windows checkout with core.autocrlf=true turns the script's LF into CRLF, and "/bin/sh^M" then
# cannot be found at start. Normalise (a no-op for a correct checkout).
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
 && chmod 0755 /usr/local/bin/entrypoint.sh

ENV LS_PORT=53318 \
    LS_AUTO_ACCEPT=1 \
    LS_VISIBILITY=everyone

USER libreshare
WORKDIR /data
VOLUME ["/data", "/config"]

# TCP: the HTTP API. UDP: LAN discovery (multicast 224.0.0.168:53318 + unicast answers).
EXPOSE 53318/tcp 53318/udp

# Really asks the listener (GET /info on loopback); non-zero exit when nothing answers.
# Shell form on purpose: ${LS_PORT} follows the port the container was started with.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
  CMD libreshare info --to "127.0.0.1:${LS_PORT:-53318}" >/dev/null 2>&1 || exit 1

# exec's the binary, so SIGTERM (docker stop) reaches it and it shuts down gracefully.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["receive"]
