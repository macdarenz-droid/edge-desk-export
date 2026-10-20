#!/usr/bin/env bash
# Edge Desk server installer (bootstrap). Made by deploy/make_release.py from deploy/install/install.sh.in; edit the
# template, not the copy in the export repo. The owner runs it from Vultr's web console, as root, with two pastes:
#   read -rs T                         then the export repo's token (fine-grained: that repo only, Contents)
#   <the install line make_release.py prints>   downloads this file with the token, checks its sha256, runs it
# It refuses the meme bot's server and servers under 1.5 GiB of RAM, downloads the release (sha256 pinned below),
# asks the owner's questions (secrets hidden), then runs deploy/install/stage2.sh as the transient unit
# edge-desk-install and shows its progress. Safe to run again. Never prints a secret, never uses set -x: secrets
# go only to root-only files, written by printf (a bash builtin, so never in a process's argv).
set -euo pipefail
umask 077
export LC_ALL=C

EXPORT_REPO="macdarenz-droid/edge-desk-export"
EXPORT_BRANCH="main"
RELEASE_NAME="edge-desk-0d5e1b85a1bd.tar.gz"
RELEASE_SHA256="99e8a5e17938c91f711db41012aae44ce1be495d8a9e48c498098727867d7a9b"
COMMIT="0d5e1b85a1bdd0f8719e9e6b70de45c16b9c2a12"
API=https://api.github.com
OPT=/opt/edge-desk
SECRETS=/etc/edge-desk/install
ENV_FILE=/etc/edge-desk/env
STATE=/var/lib/edge-desk-install
MT5_DONE=/home/mt5/edge/setup.done
DASH_NEW=""

say() { printf '%s\n' "$*"; }
die() { printf 'Install stopped: %s\n' "$*" >&2; exit 1; }

# ---- the host guard (deploy/install/guard.sh, copied in by make_release.py) ----
# Host guard for the Edge Desk installer (sourced; make_release.py also copies it into install.sh, so the bootstrap
# checks the host before it downloads anything). The owner types no hostname or machine id: the meme bot's host is
# known by its own markers (meme-snipe ops/install.sh): any zeroed-* systemd unit, /var/lib/zeroed, or the
# zeroed-signer or zeroed-worker user. deploy/check.py's host line uses the same markers.
# EDGE_ROOT is empty on a server; only the tests point it at a fake root.

EDGE_MIN_MEM_KB=1572864   # 1.5 GiB: refuses the 1 GB plan (about 0.96 GiB) widely, passes the 2 GB plan

edge_meme_markers() {     # prints one line per marker found
  local r="${EDGE_ROOT:-}" d f
  for d in etc/systemd/system lib/systemd/system usr/lib/systemd/system run/systemd/system run/systemd/transient; do
    for f in "$r/$d"/zeroed-*; do
      [ -e "$f" ] || [ -L "$f" ] && printf '%s\n' "/$d/${f##*/}"
    done
  done
  [ -e "$r/var/lib/zeroed" ] && printf '%s\n' "/var/lib/zeroed"
  for f in zeroed-signer zeroed-worker; do
    grep -q "^$f:" "$r/etc/passwd" 2>/dev/null && printf 'user %s\n' "$f"
  done
  return 0
}

edge_mem_kb() {
  awk '$1 == "MemTotal:" { print $2; exit }' "${EDGE_ROOT:-}/proc/meminfo" 2>/dev/null || true
}

edge_guard() {            # 0 when this host may take the Edge Desk; otherwise a reason on stderr
  local found kb
  found="$(edge_meme_markers)"
  if [ -n "$found" ]; then
    printf 'Install stopped: this is the meme bot'\''s server (found: %s). The Edge Desk never runs there.\n' \
      "$(printf '%s' "$found" | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi
  kb="$(edge_mem_kb)"
  if ! [[ "$kb" =~ ^[0-9]{1,12}$ ]]; then
    printf 'Install stopped: the RAM size could not be read from /proc/meminfo.\n' >&2
    return 1
  fi
  if [ "$kb" -lt "$EDGE_MIN_MEM_KB" ]; then
    awk -v k="$kb" 'BEGIN { printf "Install stopped: this server has %.2f GiB of RAM; the app and MT5 need the 2 GB plan (at least 1.5 GiB reported).\n", k / 1048576 }' >&2
    return 1
  fi
  return 0
}
# ---- end of the host guard ----

check_token() {
  if ! [[ "${T:-}" =~ ^[A-Za-z0-9_]{20,255}$ ]]; then
    printf 'Install stopped: the export token is missing or is not a GitHub token. Type: read -rs T  (Enter), paste the token (Enter), then paste the install line again.\n' >&2
    return 1
  fi
}

# gh_get PATH OUT: one file from the private export repo. The token goes to curl in a config file on a pipe
# (-K <(printf ...)), never in curl's arguments.
gh_get() {
  check_token || return 1
  curl -fsS --proto =https --tlsv1.2 --retry 3 --retry-delay 5 \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$T") \
    -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "$2" "$API/repos/$EXPORT_REPO/contents/$1?ref=$EXPORT_BRANCH"
}

# valid KIND VALUE: the owner's answers, checked before they are saved (and never echoed back).
valid() {
  local v="$2"
  case "$1" in
    mt5_login) [[ "$v" =~ ^[0-9]{3,20}$ ]] ;;
    mt5_server) [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._:\ -]{1,63}$ ]] ;;
    password) [[ -n "$v" && ${#v} -le 64 && "$v" =~ ^[\ -~]+$ ]] ;;
    ts_key) [[ "$v" =~ ^tskey-[A-Za-z0-9-]{10,200}$ ]] ;;
    oanda) [[ "$v" =~ ^[A-Za-z0-9-]{20,200}$ ]] ;;
    dashboard) [[ ${#v} -ge 32 && ${#v} -le 200 && "$v" =~ ^[!-~]+$ && "$v" != *[\"\'\\\`]* && "$v" != \#* ]] ;;
    *) return 1 ;;
  esac
}

get_release() {
  local dir="$OPT/releases/${RELEASE_SHA256:0:16}" tmp
  REL="$dir/edge-desk"
  [ -f "$dir/.verified" ] && return 0
  install -d -m 0755 -o root -g root "$OPT" "$OPT/releases"
  rm -rf "$dir" "$dir.tmp"
  tmp="$(mktemp -d "$OPT/releases/.dl.XXXXXX")"
  trap 'rm -rf "$tmp" "$dir.tmp"' EXIT
  say "Downloading the release ($RELEASE_NAME, commit ${COMMIT:0:9})"
  gh_get "release/$RELEASE_NAME" "$tmp/release.tar.gz" \
    || die "could not download the release from $EXPORT_REPO. Check the token: that repo only, Contents read."
  echo "$RELEASE_SHA256  $tmp/release.tar.gz" | sha256sum -c --quiet - \
    || die "the release does not match its pinned sha256; nothing was installed"
  install -d -m 0755 "$dir.tmp"
  (umask 022; tar -xzf "$tmp/release.tar.gz" -C "$dir.tmp" --no-same-owner --no-same-permissions)
  rm -rf "$tmp"
  [ -f "$dir.tmp/edge-desk/deploy/install/stage2.sh" ] || die "the release has no installer in it"
  : > "$dir.tmp/.verified"
  mv "$dir.tmp" "$dir"
  trap - EXIT
}

ts_joined() {   # the same test stage 2 uses: Tailscale's backend state is Running
  command -v tailscale >/dev/null && command -v jq >/dev/null || return 1
  [ "$(timeout 30 tailscale status --json 2>/dev/null | jq -r '.BackendState // "NoState"' 2>/dev/null)" = Running ]
}

ask() {
  local MT5_LOGIN MT5_SERVER MT5_PASSWORD TS_KEY OANDA DASH
  install -d -m 0755 -o root -g root "$(dirname "$ENV_FILE")"
  install -d -m 0700 -o root -g root "$SECRETS"
  [ -f "$ENV_FILE" ] || { : > "$ENV_FILE"; chmod 0600 "$ENV_FILE"; }
  say ""
  say "A few questions. Secrets you paste are not shown. Enter keeps a value already saved."
  say ""
  # MT5: asked until the terminal is set up; afterwards Enter keeps it, and a new account number logs in again
  local prompt="MT5 login (account number): "
  if [ -f "$MT5_DONE" ]; then
    prompt="MT5 is set up. Enter keeps it, or type an account number to log in again: "
  elif [ -s "$SECRETS/mt5-login" ]; then
    prompt="MT5 login from the last run is saved. Enter keeps it, or type the account number again: "
  fi
  while :; do
    IFS= read -r -p "$prompt" MT5_LOGIN
    if [ -z "$MT5_LOGIN" ] && { [ -f "$MT5_DONE" ] || [ -s "$SECRETS/mt5-login" ]; }; then break; fi
    valid mt5_login "$MT5_LOGIN" && break
    say "  digits only, please"
  done
  if [ -n "$MT5_LOGIN" ]; then
    while :; do IFS= read -r -p "MT5 server name (as MT5 shows it): " MT5_SERVER; valid mt5_server "$MT5_SERVER" && break; say "  letters, digits, spaces, . - _ : only"; done
    while :; do IFS= read -r -s -p "MT5 INVESTOR password (the read-only one, never the master password): " MT5_PASSWORD; say ""; valid password "$MT5_PASSWORD" && break; say "  that did not look right; paste it again"; done
    printf 'MT5_LOGIN=%s\nMT5_SERVER=%s\nMT5_PASSWORD=%s\n' "$MT5_LOGIN" "$MT5_SERVER" "$MT5_PASSWORD" > "$SECRETS/mt5-login"
    unset MT5_PASSWORD
    rm -f "$MT5_DONE"
  fi
  # Tailscale: an auth key (login.tailscale.com/admin/settings/keys), until the server has joined
  if ts_joined; then
    say "Tailscale: already joined."
  else
    say "Tailscale auth key: a reusable or one-off key, NOT ephemeral. Afterwards, in the admin console, turn off"
    say "key expiry for edge-desk (otherwise the app is unreachable when the node key expires, 180 days by default)."
    while :; do IFS= read -r -s -p "Tailscale auth key (tskey-..., Enter skips for now): " TS_KEY; say ""; [ -z "$TS_KEY" ] && break; valid ts_key "$TS_KEY" && break; say "  that is not a Tailscale auth key (it starts with tskey-)"; done
    [ -n "$TS_KEY" ] && printf '%s\n' "$TS_KEY" > "$SECRETS/tailscale-authkey"
    unset TS_KEY
  fi
  # OANDA practice token: optional; without it Part B (price feed, suggestions, paper leads) stays off
  while :; do IFS= read -r -s -p "OANDA practice token (optional, Enter skips: suggestions stay off): " OANDA; say ""; [ -z "$OANDA" ] && break; valid oanda "$OANDA" && break; say "  that is not an OANDA token"; done
  [ -n "$OANDA" ] && VALUE="$OANDA" set_env EDGE_OANDA_TOKEN
  unset OANDA
  # The dashboard login: pasted from the phone's password manager, or made here and shown once at the end
  if env_has EDGE_DASHBOARD_TOKEN; then
    while :; do IFS= read -r -s -p "Dashboard password (Enter keeps the current one): " DASH; say ""; [ -z "$DASH" ] && break; valid dashboard "$DASH" && break; say "  32 or more characters, no spaces or quotes"; done
  else
    while :; do IFS= read -r -s -p "Dashboard password (paste 32+ characters; Enter makes one): " DASH; say ""; [ -z "$DASH" ] && break; valid dashboard "$DASH" && break; say "  32 or more characters, no spaces or quotes"; done
    if [ -z "$DASH" ]; then
      DASH_NEW="$(head -c 48 /dev/urandom | base64 -w0 | tr -d '/+=' | head -c 40)"
      [ "${#DASH_NEW}" -ge 32 ] || die "could not make a password"
      VALUE="$DASH_NEW" set_env EDGE_DASHBOARD_TOKEN
    fi
  fi
  [ -n "$DASH" ] && VALUE="$DASH" set_env EDGE_DASHBOARD_TOKEN
  unset DASH
  # Made here, never typed: the EA's ingest token; and the export token from the paste
  env_has EDGE_INGEST_TOKEN || VALUE="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" set_env EDGE_INGEST_TOKEN
  VALUE="$T" set_env EDGE_EXPORT_TOKEN
}

show_new_login() {
  [ -n "$DASH_NEW" ] || return 0
  say ""
  say "Your dashboard password (made here; shown on this console only, never logged):"
  say ""
  say "    $DASH_NEW"
  say ""
  say "Type it into the app's login on your phone. To see it again: edge-desk-install-status --login"
}

follow() {   # follow SINCE: the install unit's progress lines until it ends
  local jp
  say ""
  say "Progress. Ctrl+C only stops watching: the install goes on. edge-desk-install-status shows it again."
  journalctl -u edge-desk-install -f -o cat --since "$1" &
  jp=$!
  trap 'kill "$jp" 2>/dev/null; exit 0' INT
  while systemctl is-active --quiet edge-desk-install 2>/dev/null; do sleep 3; done
  sleep 2
  kill "$jp" 2>/dev/null || true
  wait "$jp" 2>/dev/null || true
  trap - INT
}

main() {
  local since
  [ "$(id -u)" = 0 ] || die "run as root: type sudo -i first"
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] || die "needs Ubuntu 24.04 (found ${PRETTY_NAME:-unknown})"
  [ "$(uname -m)" = x86_64 ] || die "needs an x86_64 server"
  edge_guard || exit 1
  check_token || exit 1
  if systemctl is-active --quiet edge-desk-install 2>/dev/null; then
    say "The install is already running."
    follow "$(date -d '-2 hours' '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi
  get_release
  . "$REL/deploy/install/lib.sh"
  install -m 0755 -o root -g root "$REL/deploy/install/status.sh" /usr/local/sbin/edge-desk-install-status
  ask
  unset T
  show_new_login
  install -d -m 0700 "$STATE"
  printf 'starting\n' > "$STATE/result"
  systemctl reset-failed edge-desk-install.service >/dev/null 2>&1 || true
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemd-run --quiet --unit=edge-desk-install --description="Edge Desk install" --collect \
    --property=TimeoutStartSec=infinity \
    --setenv=EDGE_RELEASE_DIR="$REL" --setenv=EDGE_EXPORT_REPO="$EXPORT_REPO" \
    /bin/bash "$REL/deploy/install/stage2.sh"
  follow "$since"
  say ""
  say "Result: $(cat "$STATE/result" 2>/dev/null || echo unknown)"
  [ -z "$DASH_NEW" ] || say "Your new dashboard password was shown before the progress lines (edge-desk-install-status --login shows it again)."
}

[ -n "${EDGE_INSTALL_SOURCE_ONLY:-}" ] || main "$@"
