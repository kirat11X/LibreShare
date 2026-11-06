#!/usr/bin/env bash
# LibreShare headless node: one-command Docker install for Linux (and macOS, see below).
#
#   deploy/install.sh                 build + start the node, wait until healthy, print how to reach it
#   deploy/install.sh --status        is it running? where? what link do other devices use?
#   deploy/install.sh --uninstall     stop, remove container + image; asks before touching received files
#
# Options (install): --data-dir DIR  --port N  --alias NAME  --project NAME  --env-file FILE
#                    --host-ip IP (NAT mode)  --nat   --keep-data (uninstall, never prompts)  -h
# Environment: LS_PROJECT (compose project, default "libreshare"), LS_ENV_FILE (settings file,
#              default deploy/docker/.env), LS_WAIT_SECONDS (health wait, default 120).
#
# Linux uses compose.linux.yaml (host networking: LAN multicast discovery works). macOS Docker
# Desktop, like Windows, runs containers behind a NAT: the script then uses compose.windows.yaml
# (published ports), no LAN discovery, and prints a link that carries this Mac's LAN IP.
# --nat forces that mode on any OS.
#
# PROTOTYPE: plain HTTP, no TLS/PIN yet, auto-accept on. Trusted private networks only.
# Safe to re-run (idempotent). Nothing is deleted without an explicit "delete" answer.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="libreshare/node:local"
SERVICE="libreshare"

PROJECT="${LS_PROJECT:-libreshare}"
ENV_FILE="${LS_ENV_FILE:-$ROOT/deploy/docker/.env}"
WAIT_SECONDS="${LS_WAIT_SECONDS:-120}"

ACTION=install
KEEP_DATA=0
NAT=0
ARG_DATA=""
ARG_PORT=""
ARG_ALIAS=""
ARG_HOSTIP=""

if [ -t 1 ]; then
  RED=$'\033[31m'
  YEL=$'\033[33m'
  GRN=$'\033[32m'
  BLD=$'\033[1m'
  RST=$'\033[0m'
else
  RED="" YEL="" GRN="" BLD="" RST=""
fi

say() { printf '%s\n' "$*"; }
kv() { printf '  %-15s: %s\n' "$1" "$2"; }
note() { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die() {
  printf '%sERROR:%s %s\n' "$RED" "$RST" "$*" >&2
  exit 1
}

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status) ACTION=status ;;
    --uninstall) ACTION=uninstall ;;
    --keep-data) KEEP_DATA=1 ;;
    --nat) NAT=1 ;;
    --data-dir | --port | --alias | --project | --env-file | --host-ip)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --data-dir) ARG_DATA="$2" ;;
        --port) ARG_PORT="$2" ;;
        --alias) ARG_ALIAS="$2" ;;
        --project) PROJECT="$2" ;;
        --env-file) ENV_FILE="$2" ;;
        --host-ip) ARG_HOSTIP="$2" ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------------ settings file

# env_get KEY -> value of KEY in $ENV_FILE ('' if absent), surrounding single quotes removed.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  local line
  line="$(grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null)" || return 0
  line="${line#*=}"
  line="${line#\'}"
  line="${line%\'}"
  printf '%s' "$line"
}

# env_set KEY VALUE: replace or append KEY in $ENV_FILE (single-quoted when it needs it).
env_set() {
  local key="$1" val="$2" tmp
  case "$val" in
    *"'"* | *$'\n'*) die "$key must not contain a quote or a newline" ;;
  esac
  case "$val" in
    *[!A-Za-z0-9_./:@-]*) val="'$val'" ;;
  esac
  mkdir -p "$(dirname "$ENV_FILE")" || die "cannot create $(dirname "$ENV_FILE")"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || die "cannot write next to $ENV_FILE"
  if [ -f "$ENV_FILE" ]; then
    grep -v "^$key=" "$ENV_FILE" >"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
}

compose() {
  if [ -f "$ENV_FILE" ]; then
    docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
  fi
}

# ------------------------------------------------------------------ prerequisites

need_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "Docker is not installed (no 'docker' on PATH)." >&2
    case "$(uname -s)" in
      Darwin) say "  Install Docker Desktop for Mac: https://docs.docker.com/desktop/setup/install/mac-install/" >&2 ;;
      *) say "  Install Docker Engine: https://docs.docker.com/engine/install/  (Fedora: sudo dnf install docker-ce docker-compose-plugin; Debian/Ubuntu: see the page above)" >&2 ;;
    esac
    exit 1
  fi
  local out
  if ! out="$(docker info 2>&1)"; then
    if printf '%s' "$out" | grep -qi 'permission denied'; then
      say "Docker is installed, but your user may not talk to it (permission denied)." >&2
      say "  Fix: sudo usermod -aG docker \"\$USER\"   then log out and in again (or run: newgrp docker)." >&2
    else
      say "Docker is installed, but its daemon is not reachable." >&2
      case "$(uname -s)" in
        Darwin) say "  Start Docker Desktop and wait until it says it is running." >&2 ;;
        *) say "  Start it: sudo systemctl enable --now docker   (rootless Docker: systemctl --user start docker)" >&2 ;;
      esac
    fi
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    say "The Docker Compose v2 plugin ('docker compose') is missing." >&2
    if command -v docker-compose >/dev/null 2>&1; then
      say "  Only the old standalone 'docker-compose' (v1) is installed; it is not supported." >&2
    fi
    say "  Install it: Debian/Ubuntu: sudo apt install docker-compose-plugin; Fedora: sudo dnf install docker-compose-plugin;" >&2
    say "  or see https://docs.docker.com/compose/install/linux/ ; Docker Desktop already includes it." >&2
    exit 1
  fi
  local os
  os="$(docker info --format '{{.OSType}}' 2>/dev/null)"
  [ "$os" = "linux" ] || die "Docker is running $os containers; LibreShare needs Linux containers."
}

# ------------------------------------------------------------------ helpers

container_id() { compose ps -a -q "$SERVICE" 2>/dev/null | head -n1; }

health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null; }
state_of() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }

# The LAN IPv4 of this machine, best effort ('' when unknown).
detect_host_ip() {
  local ip="" ifc=""
  case "$(uname -s)" in
    Linux)
      ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
      [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      ;;
    Darwin)
      ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
      [ -n "$ifc" ] && ip="$(ipconfig getifaddr "$ifc" 2>/dev/null)"
      ;;
  esac
  printf '%s' "$ip"
}

# The ip= of a peer link ('' if none).
link_ip() { printf '%s' "$1" | sed -n -E 's/.*[?&]ip=([^&]*).*/\1/p'; }

# The last PEER-LINK the running node printed ('' if none yet).
raw_link() {
  docker logs "$1" 2>&1 | grep -a '^PEER-LINK ' | tail -n1 | cut -d' ' -f2-
}

# The link to hand out: NAT mode swaps the container-internal IP for the host's LAN IP; the
# device id is dropped so that the link survives restarts (the prototype CLI makes a new device id
# on every start; a link that pins the old id would be refused after a restart).
public_link() {
  local raw="$1" host_ip="$2"
  [ -n "$raw" ] || return 0
  if [ "$MODE" = nat ] && [ -n "$host_ip" ]; then
    raw="$(printf '%s' "$raw" | sed -E "s/([?&])ip=[^&]*/\\1ip=$host_ip/")"
  fi
  printf '%s' "$raw" | sed -E 's/&id=[^&]*//'
}

plaintext_warning() {
  cat <<'EOF'
LibreShare prototype: transfers are NOT encrypted or authenticated and anyone on this network
can drop files into the received folder. Use only on a trusted private network (Increment 3
adds TLS/PIN).
EOF
}

# has_content DIR: prints one path if DIR holds anything but the installer's marker.
has_content() { find "$1" -mindepth 1 -maxdepth 1 ! -name '.libreshare-data' 2>/dev/null | head -n1; }

dir_summary() { # DIR -> "N files, X"
  local d="$1" n kb
  n="$(find "$d" -type f ! -name '.libreshare-data' 2>/dev/null | wc -l | tr -d ' ')"
  kb="$(du -sk "$d" 2>/dev/null | awk '{print $1}')"
  printf '%s files, %s MiB' "$n" "$(((${kb:-0} + 1023) / 1024))"
}

firewall_hint() {
  local port="$1"
  if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then
    say "firewalld is active. Host networking bypasses Docker's own firewall rules, so allow the"
    say "node on your LAN zone yourself (not done for you):"
    say "  sudo firewall-cmd --add-port=${port}/tcp --add-port=53318/udp            # now"
    say "  sudo firewall-cmd --permanent --add-port=${port}/tcp --add-port=53318/udp  # keep after reboot"
  elif command -v ufw >/dev/null 2>&1; then
    say "If ufw is active, allow the node yourself (not done for you):"
    say "  sudo ufw allow ${port}/tcp && sudo ufw allow 53318/udp"
  fi
}

# ------------------------------------------------------------------ load settings

load_settings() {
  local m
  m="$(env_get LS_MODE)"
  if [ "$NAT" = 1 ]; then
    MODE=nat
  elif [ -n "$m" ]; then
    MODE="$m"
  elif [ "$(uname -s)" = Darwin ]; then
    MODE=nat
  else
    MODE=host
  fi
  case "$MODE" in
    host) COMPOSE_FILE="$ROOT/deploy/docker/compose.linux.yaml" ;;
    nat) COMPOSE_FILE="$ROOT/deploy/docker/compose.windows.yaml" ;;
    *) die "LS_MODE in $ENV_FILE must be host or nat, got '$MODE'" ;;
  esac
  [ -f "$COMPOSE_FILE" ] || die "missing $COMPOSE_FILE (run this script from a full checkout of the repository)"
}

# ------------------------------------------------------------------ install

do_install() {
  need_docker

  local data port alias hostip
  data="${ARG_DATA:-$(env_get LS_DATA_DIR)}"
  [ -n "$data" ] || data="${HOME:?HOME is not set}/LibreShare"
  case "$data" in /*) ;; *) data="$PWD/$data" ;; esac
  port="${ARG_PORT:-$(env_get LS_PORT)}"
  [ -n "$port" ] || port=53318
  case "$port" in
    '' | *[!0-9]*) die "port must be a number, got '$port'" ;;
  esac
  { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || die "port must be 1..65535, got '$port'"
  alias="${ARG_ALIAS:-$(env_get LS_ALIAS)}"
  [ -n "$alias" ] || alias="libreshare-$(hostname | cut -d. -f1)"
  hostip="${ARG_HOSTIP:-$(env_get LS_HOST_IP)}"
  if [ "$MODE" = nat ] && [ -z "$ARG_HOSTIP" ]; then
    hostip="$(detect_host_ip)"
  fi
  if [ "$MODE" = nat ] && [ -z "$hostip" ]; then
    die "cannot work out this machine's LAN IP; pass it: $0 --host-ip 192.168.x.y"
  fi

  # Port already taken by something else? (our own running node is fine: re-run = update)
  if [ -z "$(container_id)" ] && command -v ss >/dev/null 2>&1; then
    if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
      die "TCP port $port is already in use on this machine (the LibreShare desktop app? another node?). Pick another: $0 --port $((port + 1))"
    fi
  fi

  # Received-files folder, created by you (not by the Docker daemon as root).
  local created=0
  if [ ! -d "$data" ]; then
    mkdir -p "$data" || die "cannot create $data"
    created=1
  elif [ -z "$(has_content "$data")" ]; then
    created=1
  fi
  [ -w "$data" ] || die "$data is not writable by you; choose another folder with --data-dir"
  if [ "$created" = 1 ]; then
    : >"$data/.libreshare-data" || die "cannot write into $data"
  fi

  env_set LS_MODE "$MODE"
  env_set LS_UID "$(id -u)"
  env_set LS_GID "$(id -g)"
  env_set LS_PORT "$port"
  env_set LS_ALIAS "$alias"
  env_set LS_DATA_DIR "$data"
  if [ "$MODE" = nat ]; then env_set LS_HOST_IP "$hostip"; fi

  note "Building and starting LibreShare (project '$PROJECT', $MODE networking). The first build takes a few minutes."
  compose up -d --build || die "docker compose failed (see the output above). Nothing was changed on your files."

  note "Waiting for the node to become healthy (up to ${WAIT_SECONDS}s)"
  local cid="" st="" hs="" waited=0
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    cid="$(container_id)"
    if [ -n "$cid" ]; then
      st="$(state_of "$cid")"
      hs="$(health_of "$cid")"
      [ "$hs" = healthy ] && break
      if [ "$st" = exited ] || [ "$st" = dead ] || [ "$st" = restarting ] || [ "$hs" = unhealthy ]; then
        break
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$hs" != healthy ]; then
    say "" >&2
    say "The node did not become healthy (state=${st:-none}, health=${hs:-none}). Last log lines:" >&2
    if [ -n "$cid" ]; then docker logs --tail 25 "$cid" 2>&1 | sed 's/^/  | /' >&2; fi
    say "" >&2
    say "Hints: port $port busy; the received folder not writable; see docs/dev/docker-install.md (Troubleshooting)." >&2
    exit 1
  fi

  print_summary "$cid" "$port" "$data" "$alias" "$hostip"
}

print_summary() {
  local cid="$1" port="$2" data="$3" alias="$4" hostip="$5" raw link addr
  raw="$(raw_link "$cid")"
  if [ -z "$hostip" ]; then
    # Host networking: the node picks its own LAN address (Wi-Fi first); that is the one in its link.
    hostip="$(link_ip "$raw")"
    [ -n "$hostip" ] || hostip="$(detect_host_ip)"
  fi
  link="$(public_link "$raw" "$hostip")"
  addr="${hostip:-<this-machine-IP>}:$port"
  say ""
  say "${GRN}${BLD}LibreShare node is running.${RST}"
  kv "Alias" "$alias"
  kv "Address" "$addr   (TCP; project '$PROJECT', container $(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##'))"
  kv "Received files" "$data"
  if [ -n "$link" ]; then
    kv "Peer link" "$link"
    printf '  %-15s  %s\n' "" "(in the app: Add device by link / QR; CLI: libreshare send --device '<link>' FILE)"
  else
    kv "Peer link" "(not printed yet; run: $0 --status)"
  fi
  if [ "$MODE" = nat ]; then
    say ""
    say "NAT mode: LAN auto-discovery (multicast) does NOT reach this node; other devices must use the link"
    say "above or $addr. Allow TCP+UDP $port in this machine's firewall if connections time out."
  else
    say ""
    firewall_hint "$port"
  fi
  say ""
  warn "$(plaintext_warning)"
  say ""
  say "Status: $0 --status      Uninstall: $0 --uninstall      Logs: docker logs -f $(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
}

# ------------------------------------------------------------------ status

do_status() {
  need_docker
  local cid st hs port data alias hostip raw link
  port="$(env_get LS_PORT)"
  [ -n "$port" ] || port=53318
  data="$(env_get LS_DATA_DIR)"
  alias="$(env_get LS_ALIAS)"
  cid="$(container_id)"
  kv "Project" "$PROJECT ($MODE networking)"
  if [ -z "$cid" ]; then
    kv "Container" "not installed or removed (run: $0)"
    return 3
  fi
  st="$(state_of "$cid")"
  hs="$(health_of "$cid")"
  kv "Container" "$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')  state=$st health=$hs"
  kv "Started" "$(docker inspect -f '{{.State.StartedAt}}' "$cid")"
  kv "Image" "$(docker inspect -f '{{.Config.Image}}' "$cid")"
  kv "Alias / port" "${alias:-?} / $port"
  raw="$(raw_link "$cid")"
  hostip="$(env_get LS_HOST_IP)"
  if [ -z "$hostip" ]; then hostip="$(link_ip "$raw")"; fi
  link="$(public_link "$raw" "$hostip")"
  if [ -n "$link" ]; then kv "Peer link" "$link"; fi
  if [ -n "$data" ] && [ -d "$data" ]; then
    kv "Received files" "$data  ($(dir_summary "$data"))"
  else
    kv "Received files" "${data:-unknown} (folder missing)"
  fi
  if [ "$hs" = healthy ]; then
    return 0
  fi
  say "The node is not healthy. Last log lines:" >&2
  docker logs --tail 15 "$cid" 2>&1 | sed 's/^/  | /' >&2
  return 1
}

# ------------------------------------------------------------------ uninstall

safe_to_delete() { # DIR -> 0 only for a folder this installer created and that is clearly not special
  local d="$1" real
  real="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  case "$real" in
    '' | / | /home | /root | /usr | /etc | /var | /tmp | /opt | /mnt | /media | /srv | "${HOME:-/}") return 1 ;;
  esac
  case "$ROOT" in "$real" | "$real"/*) return 1 ;; esac
  [ -f "$d/.libreshare-data" ]
}

do_uninstall() {
  need_docker
  local data cfgvol
  data="$(env_get LS_DATA_DIR)"
  cfgvol="${PROJECT}_config"

  note "Stopping and removing the LibreShare container (project '$PROJECT')"
  compose down --remove-orphans || warn "docker compose down reported a problem (see above)"

  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    note "Removing image $IMAGE"
    docker image rm "$IMAGE" >/dev/null || warn "could not remove $IMAGE (still used by another LibreShare project?)"
  fi

  local delete=0
  if [ -n "$data" ] && [ -d "$data" ]; then
    if [ "$KEEP_DATA" = 1 ]; then
      say "Keeping received files: $data ($(dir_summary "$data"))"
    elif [ -z "$(has_content "$data")" ]; then
      delete=1 # nothing but our marker: nothing to lose
    else
      say ""
      say "Received files are in: $data  ($(dir_summary "$data"))"
      printf "Type 'delete' to PERMANENTLY delete that folder, anything else keeps it [keep]: "
      local ans=""
      read -r ans || ans=""
      if [ "$ans" = delete ]; then
        delete=1
      else
        say "Keeping $data"
      fi
    fi
    if [ "$delete" = 1 ]; then
      if safe_to_delete "$data"; then
        rm -r -- "$data" && say "Deleted $data"
      else
        warn "not deleting $data: it was not created by this installer (no .libreshare-data marker) or it is a protected location. Remove it yourself if you want."
        delete=0
      fi
    fi
  fi

  if docker volume inspect "$cfgvol" >/dev/null 2>&1; then
    if [ "$delete" = 1 ]; then
      docker volume rm "$cfgvol" >/dev/null && say "Removed state volume $cfgvol"
    else
      say "Kept state volume $cfgvol (empty in the prototype; it will hold the device identity later). Remove: docker volume rm $cfgvol"
    fi
  fi
  if [ -f "$ENV_FILE" ]; then
    say "Kept settings file $ENV_FILE (delete it for a fresh start)."
  fi
  say "Shared base images (dart, debian) and the build cache are left alone: docker image prune / docker builder prune."
  say "${GRN}LibreShare uninstalled.${RST}"
}

# ------------------------------------------------------------------ main

load_settings
case "$ACTION" in
  install) do_install ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
esac
