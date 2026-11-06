#!/bin/sh
# LibreShare headless node entrypoint: maps LS_* environment variables to `libreshare receive`
# flags and exec's the binary (so SIGTERM from `docker stop` reaches it and it stops gracefully).
#
#   LS_ALIAS        name other devices see          (default: the host/container name)
#   LS_PORT         TCP port of the API             (default 53318)
#   LS_AUTO_ACCEPT  1/true/yes/on = accept every incoming transfer without asking (default 1:
#                   a headless box has nobody to click Accept; 0 = ask on stdin, which needs
#                   `docker attach` / `docker run -it`, otherwise every transfer is rejected)
#   LS_VISIBILITY   everyone | contacts             (default everyone; contacts needs pairing: not yet)
#   LS_EXTRA_ARGS   extra flags for `receive`, split on whitespace, e.g. "--no-discovery"
#
# Any other first argument (send, info, devices, peer-link, sh, ...) is run as given.
# Never prints file contents, keys or PINs.
set -eu

BIN=/usr/local/bin/libreshare
DATA_DIR=/data

die() {
  echo "libreshare: $*" >&2
  exit 64
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on | y) return 0 ;;
    *) return 1 ;;
  esac
}

# Not `receive`: pass through (`docker run IMAGE send --to ...`, `docker run -it IMAGE sh`).
if [ "$#" -gt 0 ] && [ "$1" != "receive" ]; then
  case "$1" in
    send | info | devices | peer-link | --help | -h | --verbose | -v) exec "$BIN" "$@" ;;
    *) exec "$@" ;;
  esac
fi
if [ "$#" -gt 0 ]; then shift; fi # drop "receive"; any further args are appended last (see below)
extra_count=$#

port="${LS_PORT:-53318}"
case "$port" in
  '' | *[!0-9]*) die "LS_PORT must be a number, got '$port'" ;;
esac
{ [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || die "LS_PORT must be 1..65535, got '$port'"

visibility="${LS_VISIBILITY:-everyone}"
case "$visibility" in
  everyone | contacts) ;;
  *) die "LS_VISIBILITY must be 'everyone' or 'contacts', got '$visibility'" ;;
esac

# A real write probe (not `test -w`): it also catches SELinux denials on bind mounts.
probe="$DATA_DIR/.libreshare-write-test.$$"
if ! (: >"$probe") 2>/dev/null; then
  echo "libreshare: cannot write to $DATA_DIR as uid $(id -u):$(id -g)." >&2
  echo "  - bind mount: the host folder must be writable by that uid (compose runs the container as" >&2
  echo "    the user in LS_UID/LS_GID; deploy/install.sh sets them), or chown the folder." >&2
  echo "  - SELinux (Fedora/RHEL): the mount needs the :z option (compose.linux.yaml has it)." >&2
  echo "  - read-only mount: /data must be read-write." >&2
  exit 73
fi
rm -f "$probe"

# Build the argument list in "$@" (POSIX sh has no arrays), appending after whatever the caller
# passed after `receive`; those are rotated to the end afterwards. --always is the default mode.
set -- "$@" receive --always --dir "$DATA_DIR" --port "$port" --visibility "$visibility" --insecure-plaintext
if [ -n "${LS_ALIAS:-}" ]; then
  set -- "$@" --alias "$LS_ALIAS"
fi
auto=0
if truthy "${LS_AUTO_ACCEPT:-1}"; then
  auto=1
  set -- "$@" --auto-accept
fi
if [ -n "${LS_EXTRA_ARGS:-}" ]; then
  # Intentional word splitting; globbing off so "*" in a value is never expanded.
  set -f
  # shellcheck disable=SC2086
  set -- "$@" $LS_EXTRA_ARGS
  set +f
fi

i=0
while [ "$i" -lt "$extra_count" ]; do
  set -- "$@" "$1"
  shift
  i=$((i + 1))
done

# Every start, once, on stderr (docker logs). No TLS/PIN exists yet, so the transport is always
# plaintext; auto-accept makes it a drop box open to the whole network.
if [ "$auto" = 1 ]; then
  cat >&2 <<WARN
################################################################################
# WARNING  LibreShare prototype: transfers are NOT encrypted or authenticated  #
# and anyone on this network can drop files into /data. Use only on a trusted  #
# private network (Increment 3 adds TLS/PIN).                                  #
################################################################################
WARN
else
  cat >&2 <<WARN
################################################################################
# WARNING  LibreShare prototype: transfers are NOT encrypted or authenticated. #
# Use only on a trusted private network (Increment 3 adds TLS/PIN).            #
# LS_AUTO_ACCEPT is off: without a terminal attached every transfer is         #
# rejected (docker attach / docker run -it to answer the prompts).             #
################################################################################
WARN
fi

echo "libreshare: starting receive: port=$port auto-accept=$auto visibility=$visibility dir=$DATA_DIR uid=$(id -u)" >&2
exec "$BIN" "$@"
