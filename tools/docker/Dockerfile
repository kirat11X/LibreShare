# LibreShare end-to-end test image (spec 12 Inc 2 FR-02, spec 13/14).
#
#   build context : the repository root (see compose.yaml)
#   ignore rules  : tools/docker/Dockerfile.dockerignore (allow-list: only packages/, the root
#                   pubspec and these scripts are sent to the daemon)
#   result        : libreshare-e2e/ls:local = AOT-compiled `ls` + iproute2/iptables + the test scripts
#
# The repo root is a pub WORKSPACE whose pubspec also lists apps/libreshare_app. That member needs
# the Flutter SDK, which the official `dart` image does not have, and the app is not copied into the
# build context at all. So the build trims every `apps/...` line out of the root `workspace:` list.

ARG DART_VERSION=3.13.7

# ------------------------------------------------------------------ build
# Same Dart as tools/env.sh (Flutter 3.47.9 ships Dart 3.13.7). The official image is Debian 13
# (trixie); the runtime stage uses the same release so the AOT binary finds a matching glibc.
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
 && dart compile exe packages/libreshare_cli/bin/ls.dart -o /out/ls

# ---------------------------------------------------------------- runtime
FROM debian:trixie-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 iptables procps jq tcpdump \
 && rm -rf /var/lib/apt/lists/* \
 # Non-root user for the devices under test. Only the tester container runs as root (compose.yaml
 # sets user 0:0 there) because adding an iptables rule needs CAP_NET_ADMIN.
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin libreshare \
 # /data = receive directory (alice's is a named volume the tester mounts read-only);
 # /sync = marker files that let the tester drive "carol" without a docker socket;
 # /alice-id, /bob-id, /dave-id = persistent identity volumes.
 && mkdir -p /data /sync /alice-id /bob-id /dave-id \
 && chown libreshare:libreshare /data /alice-id /bob-id /dave-id \
 && chmod 1777 /sync

# The CLI is built from bin/ls.dart ("ls") but installed as `libreshare` so that it never shadows
# coreutils `ls` (PATH has /usr/local/bin first) inside the test scripts or a debugging shell.
COPY --from=build /out/ls /usr/local/bin/libreshare

# Last layers: editing a test script does not invalidate the (slow) compile above.
COPY tools/docker/e2e.sh tools/docker/alice.sh tools/docker/bob.sh tools/docker/carol.sh tools/docker/dave.sh tools/docker/legacy.sh tools/docker/cut_wifi.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/*.sh

USER libreshare
WORKDIR /data
CMD ["libreshare", "--help"]
