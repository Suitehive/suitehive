#!/bin/sh
#
# Suitehive bootstrap installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Suitehive/suitehive/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Suitehive/suitehive/main/install.sh | sh -s -- --domain example.com --yes
#   curl -fsSL https://raw.githubusercontent.com/Suitehive/suitehive/main/install.sh | sh -s -- --local
#
# What it does (and nothing else):
#   1. checks this machine: Linux or macOS, x86_64 or arm64, curl or wget,
#      Docker with compose v2, at least 4 GB of memory, free ports;
#   2. installs the `suitehive` CLI (a bash script) into /usr/local/bin when run
#      as root, otherwise into ~/.local/bin;
#   3. runs `suitehive install` with the arguments you gave it.
#
# It never installs Docker or other packages for you; it tells you how instead.
# Every argument goes through to `suitehive install` (see `--help`).
#
# Environment:
#   SH_REF        git ref to install from (default: main)
#   SH_REPO_RAW   base URL for raw files (default: GitHub raw for $SH_REF)
#   SH_BIN_DIR    where to put the CLI (default: see above)
#
# The whole script is a set of functions and runs only when the last line is
# reached, so a partially downloaded copy does nothing.

set -eu

SH_REF="${SH_REF:-main}"
SH_REPO_RAW="${SH_REPO_RAW:-https://raw.githubusercontent.com/Suitehive/suitehive/${SH_REF}}"
export SH_REF SH_REPO_RAW

# ------------------------------------------------------------------ output --

setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    BOLD=$(printf '\033[1m') RED=$(printf '\033[31m') GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m') BLUE=$(printf '\033[34m') DIM=$(printf '\033[2m') RESET=$(printf '\033[0m')
  else
    BOLD="" RED="" GREEN="" YELLOW="" BLUE="" DIM="" RESET=""
  fi
}

step() { printf '%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok() { printf '    %s+%s %s\n' "$GREEN" "$RESET" "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Suitehive installer: sets up Suitehive (Mail, Calendar, sign-in/SSO, Admin)
on this server with Docker.

Usage:
  curl -fsSL $SH_REPO_RAW/install.sh | sh -s -- [options]
  sh install.sh [options]          (from a clone of the repository)

Common options (all of them are passed to \`suitehive install\`):
  --domain <name>         Your mail domain, e.g. example.com
  --hostname <name>       Public hostname [suite.<domain>]
  --admin-email <addr>    First admin [admin@<domain>]
  --org-name <name>       Organization name
  --local                 Try it on this machine: http://localhost:8080, demo data
  --build                 Build the images from source
  --dir <path>            Install directory [/opt/suitehive as root, ~/suitehive]
  --version <tag>         Image tag [edge]
  --yes                   No questions; accept defaults
  --dry-run               Write the configuration, start nothing
  --skip-checks           Continue with less than 4 GB of memory
  -h, --help              This help (\`suitehive help install\` lists everything)

Needs: Linux or macOS (x86_64/arm64), Docker with compose v2, 4 GB of memory,
ports 80, 443, 25, 465, 587 and 993 (8080 for --local).
EOF
}

# ------------------------------------------------------------------ checks --

check_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case $OS in
    Linux | Darwin) ;;
    *) die "unsupported operating system: $OS. Suitehive runs on Linux (servers) or macOS (trial).
       On Windows, use install.ps1 (Docker Desktop) or WSL." ;;
  esac
  case $ARCH in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $ARCH (Suitehive images are built for amd64 and arm64)" ;;
  esac
  ok "$OS $ARCH"
}

check_downloader() {
  if have curl; then
    DL=curl
  elif have wget; then
    DL=wget
  else
    die "curl or wget is required"
  fi
  have bash || die "bash is required for the suitehive CLI (install it with your package manager)"
}

# docker_fail <message>: a missing Docker is fatal, except with --dry-run.
docker_fail() {
  if [ "$DRY_RUN" = 1 ]; then
    warn "$1 (ignored for --dry-run)"
  else
    die "$1"
  fi
}

check_docker() {
  if ! have docker; then
    if [ "$OS" = Darwin ]; then
      docker_fail "Docker is not installed.
       Install Docker Desktop (https://www.docker.com/products/docker-desktop/)
       or OrbStack (https://orbstack.dev), start it, and run this again."
    else
      docker_fail "Docker is not installed. Install it with:
         curl -fsSL https://get.docker.com | sh
       (or see https://docs.docker.com/engine/install/), then run this again."
    fi
    return 0
  fi
  if [ -z "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" ]; then
    if [ "$OS" = Darwin ]; then
      docker_fail "the Docker daemon is not reachable. Start Docker Desktop / OrbStack and try again."
    else
      docker_fail "the Docker daemon is not reachable.
       Start it (sudo systemctl start docker) and run this as root, or add your
       user to the docker group: sudo usermod -aG docker \"\$USER\" (then log in again)."
    fi
    return 0
  fi
  if ! docker compose version >/dev/null 2>&1; then
    if [ "$OS" = Darwin ]; then
      docker_fail "docker compose v2 is missing. Update Docker Desktop / OrbStack."
    else
      docker_fail "docker compose v2 is missing (docker-compose v1 is not supported). Install it with:
         Debian/Ubuntu: sudo apt-get install docker-compose-plugin
         Fedora/RHEL:   sudo dnf install docker-compose-plugin
       or reinstall Docker: curl -fsSL https://get.docker.com | sh"
    fi
    return 0
  fi
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $(docker compose version --short 2>/dev/null || echo v2)"
}

# Suitehive needs about 4 GB. A "4 GB" VPS reports slightly less than 4 GiB,
# so the hard limit is 3.5 GiB (3670016 KiB).
check_memory() {
  kb=""
  case $OS in
    Linux) kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true) ;;
    Darwin) kb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024)) ;;
  esac
  if [ -z "$kb" ] || [ "$kb" -eq 0 ]; then
    warn "could not determine the amount of memory; Suitehive needs at least 4 GB"
    return 0
  fi
  gib=$(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1048576 }')
  if [ "$kb" -ge 3670016 ]; then
    ok "memory: $gib GiB"
  elif [ "$LOCAL" = 1 ] || [ "$SKIP_CHECKS" = 1 ]; then
    warn "only $gib GiB of memory; Suitehive needs about 4 GB (continuing anyway)"
  else
    die "only $gib GiB of memory; Suitehive needs at least 4 GB.
       Use a bigger server, or pass --skip-checks to try anyway."
  fi
}

# listening_ports: every listening TCP port, one per line. The awk picks the
# first <address>:<port> / <address>.<port> field, which works for the output of
# ss, lsof, and Linux/macOS netstat alike.
listening_ports() {
  if have ss; then
    ss -ltn 2>/dev/null | tail -n +2
  elif have lsof; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2
  elif have netstat; then
    netstat -an 2>/dev/null | grep -i listen
  else
    return 2
  fi | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /[.:][0-9]+$/ && $i ~ /[.:*]/) {
      n = split($i, parts, /[.:]/); print parts[n]; break
    }
  }' | sort -u
}

check_ports() {
  if ! have ss && ! have lsof && ! have netstat; then
    warn "cannot check ports (no ss, lsof or netstat)"
    return 0
  fi
  listening=$(listening_ports || true)
  taken=""
  for p in "$@"; do
    if printf '%s\n' "$listening" | grep -qx "$p"; then taken="$taken $p"; fi
  done
  if [ -n "$taken" ]; then
    warn "ports already in use:$taken."
    warn "If this is an earlier Suitehive install, that is fine. Otherwise stop whatever"
    warn "listens there (another web or mail server?) or the containers cannot start."
  else
    ok "ports free: $*"
  fi
}

# --------------------------------------------------------------- the CLI --

fetch() { # fetch <url> <dest>
  if [ "$DL" = curl ]; then
    curl -fsSL --retry 2 --connect-timeout 10 -o "$2" "$1"
  else
    wget -q -T 20 -O "$2" "$1"
  fi
}

# install_cli: put `suitehive` on the PATH. Sets CLI to the script to run.
install_cli() {
  if [ -n "${SH_BIN_DIR:-}" ]; then
    bin_dir=$SH_BIN_DIR
  elif [ "$(id -u)" = 0 ]; then
    bin_dir=/usr/local/bin
  else
    bin_dir=$HOME/.local/bin
  fi
  mkdir -p "$bin_dir" || die "cannot create $bin_dir"
  tmp="$bin_dir/.suitehive.$$"

  # Running from a clone: use its CLI (and, through it, its templates).
  here=""
  case $0 in
    */install.sh | install.sh) here=$(cd "$(dirname "$0")" && pwd) ;;
  esac
  if [ -n "$here" ] && [ -f "$here/bin/suitehive" ] && [ -d "$here/templates" ]; then
    cp "$here/bin/suitehive" "$tmp"
    CLI="$here/bin/suitehive"
    note "using the CLI and templates from $here"
  else
    fetch "$SH_REPO_RAW/bin/suitehive" "$tmp" || {
      rm -f "$tmp"
      die "could not download $SH_REPO_RAW/bin/suitehive"
    }
    CLI="$bin_dir/suitehive"
  fi
  # Sanity check before replacing anything: a real script, completely downloaded.
  if ! head -n 1 "$tmp" | grep -q '^#!.*bash' || ! grep -q '^SUITEHIVE_CLI_VERSION=' "$tmp"; then
    rm -f "$tmp"
    die "the downloaded suitehive CLI looks wrong; try again later"
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$bin_dir/suitehive" || die "cannot write $bin_dir/suitehive"
  ok "installed $bin_dir/suitehive"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) warn "$bin_dir is not on your PATH. Add it (e.g. echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.profile) or run $bin_dir/suitehive." ;;
  esac
}

# -------------------------------------------------------------------- main --

main() {
  setup_colors
  DRY_RUN=0 LOCAL=0 SKIP_CHECKS=0
  for arg in "$@"; do
    case $arg in
      -h | --help) usage; exit 0 ;;
      --dry-run) DRY_RUN=1 ;;
      --local) LOCAL=1 ;;
      --skip-checks) SKIP_CHECKS=1 ;;
    esac
  done

  printf '%sSuitehive installer%s\n' "$BOLD" "$RESET"
  step "Checking this machine"
  check_platform
  check_downloader
  check_docker
  check_memory
  if [ "$LOCAL" = 1 ]; then
    check_ports 8080 8443 8081
  else
    check_ports 80 443 25 465 587 993 8081
  fi

  step "Installing the suitehive CLI"
  install_cli

  # Hand over to the CLI; the checks above are not repeated there.
  SH_PREFLIGHT_DONE=1
  export SH_PREFLIGHT_DONE
  exec bash "$CLI" install "$@"
}

main "$@"
