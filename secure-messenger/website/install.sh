#!/usr/bin/env bash
# Set up a BitDM relay — one command, a few questions, no config file to touch.
#
#   curl -fsSL https://bitdm.net/install.sh | sudo bash
#
# If you would rather not pipe a script straight into a shell — and that is the
# more sensible instinct — download it and read it first:
#
#   curl -fsSLO https://bitdm.net/install.sh
#   less install.sh && sudo bash install.sh
#
# To see what it would do without changing anything:
#
#   curl -fsSL https://bitdm.net/install.sh | sudo bash -s -- --dry-run
#
# This touches no existing service and opens no port beyond 80 and 443, which
# nginx already has. Running it again is safe.

set -euo pipefail

# ── Probelauf ─────────────────────────────────────────────────────────────
# Alles pruefen, nichts anfassen. Jeder Schritt, der etwas veraendert, laeuft
# durch `run` — im Probelauf sagt es nur, was es tun WUERDE.
DRY=""
[[ ${1:-} == --dry-run ]] && DRY=1
run() {
  if [[ -n $DRY ]]; then printf '  would run: %s
' "$*"; else "$@"; fi
}

REPO="https://github.com/Henner4746/BitDM.git"
TARGET="/opt/bitdm"

red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; bold=$'\033[1m'; off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$green" "$off" "$*"; }
warn() { printf '%s  !!%s  %s\n' "$yellow" "$off" "$*"; }
die()  { printf '\n%s  %s%s\n' "$red" "$*" "$off"; exit 1; }

# ── Preconditions, before anything happens ────────────────────────────────
# Der Probelauf aendert nichts und braucht darum auch keine Rechte.
[[ $EUID -eq 0 || -n $DRY ]] || die "Please run with sudo."
command -v apt-get >/dev/null || die \
  "This script only knows Debian and Ubuntu. For anything else the manual steps
  are in deploy/README.md — there are not many."

say ""
say "${bold}Set up a BitDM relay${off}"
[[ -n $DRY ]] && say "${yellow}  dry run — nothing will be changed${off}"
say ""
say "A relay carries encrypted envelopes between devices that cannot reach each"
say "other directly. It cannot read them. What it does see is traffic data — and"
say "that stays here if you run it yourself."
say ""
say "${bold}One thing up front:${off} everyone involved needs THE SAME relay."
say "Two people on different servers cannot message each other."
say ""

# ── Questions ─────────────────────────────────────────────────────────────
ask() {                         # ask <variable> <prompt> [default]
  local __v=$1 __t=$2 __d=${3:-} __a __n=0
  # ANTWORTEN AUS DER UMGEBUNG, je Variable: BITDM_DOMAIN, BITDM_EMAIL,
  # BITDM_GO_ON. Damit laeuft das Skript in einem Container oder Testlauf ohne
  # Terminal durch, und die zwei Sonderfaelle, die ich dafuer erst gebaut
  # hatte, sind wieder weg.
  local __env="BITDM_$__v"
  if [[ -n ${!__env:-} ]]; then
    printf -v "$__v" '%s' "${!__env}"
    ok "$__t: ${!__env}"
    return
  fi
  # VON /dev/tty UND NICHT VON DER STANDARDEINGABE: durch `curl | bash` IST die
  # Standardeingabe das Skript selbst; davon zu lesen frisst den eigenen Code.
  #
  # Die Schleife ist BEGRENZT. Ohne Terminal — in einem Container, in einem
  # Testlauf — schlaegt `read` sofort fehl, und eine unbegrenzte Schleife liefe
  # ewig und schriebe "(required)" bis irgendwer sie abwuergt.
  while (( __n++ < 3 )); do
    if [[ -n $__d ]]; then read -rp "  $__t [$__d]: " __a </dev/tty 2>/dev/null || true
    else                        read -rp "  $__t: "        __a </dev/tty 2>/dev/null || true; fi
    __a=${__a:-$__d}
    [[ -n $__a ]] && break
    say "    (required)"
  done
  if [[ -z ${__a:-} ]]; then
    die "No answer for: $__t
  Without a terminal, pass it in the environment instead:
    BITDM_DOMAIN=relay.example.net BITDM_EMAIL=you@example.com"
  fi
  printf -v "$__v" '%s' "$__a"
}

ask DOMAIN "Domain for the relay (e.g. relay.example.net)"
ask EMAIL  "Email for certificate expiry notices"
say ""

# ── Does the name actually point here? ────────────────────────────────────
# This is the most common failure, and certbot reports it late and cryptically.
# Better now, and in plain words.
my_ip=$(curl -fsS --max-time 10 https://api.ipify.org || true)
target_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)

if [[ -z $target_ip ]]; then
  die "$DOMAIN does not resolve. Point an A record at $my_ip first."
fi
if [[ -n $my_ip && $target_ip != "$my_ip" ]]; then
  warn "$DOMAIN points at $target_ip, this machine is $my_ip."
  # Cloudflare ranges, roughly: 104.16-31, 172.64-71, 188.114, 162.158, 198.41
  if [[ $target_ip =~ ^(104\.(1[6-9]|2[0-9]|3[01])|172\.6[4-9]|172\.7[01]|188\.114|162\.158|198\.41)\. ]]; then
    say ""
    say "  That looks like Cloudflare. A relay speaks WebSocket over a long-lived"
    say "  connection, and that does not work reliably through the Cloudflare"
    say "  proxy. Set the record to ${bold}DNS only${off} (grey cloud) and run"
    say "  this again."
  fi
  say ""
  ask GO_ON "Continue anyway? (yes/no)" "no"
  [[ $GO_ON == yes ]] || die "Stopped. Nothing changed."
else
  ok "$DOMAIN points at this machine"
fi

# ── Packages ──────────────────────────────────────────────────────────────
say ""
say "${bold}Packages${off}"
missing=()
for p in nginx certbot git python3-venv curl; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if ((${#missing[@]})); then
  say "  installing: ${missing[*]}"
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi
ok "nginx, certbot, git, python3-venv"

run install -d -m 755 /var/www/acme
run systemctl enable --now nginx
ok "/var/www/acme created, nginx running"

# ── Source ────────────────────────────────────────────────────────────────
say ""
say "${bold}Source${off}"
if [[ -d $TARGET/.git ]]; then
  run git -C "$TARGET" pull --ff-only --quiet && ok "updated: $TARGET"
else
  run git clone --depth 1 --quiet "$REPO" "$TARGET" && ok "cloned to $TARGET"
fi

SCRIPT="$TARGET/secure-messenger/deploy/install-relay.sh"
if [[ ! -f $SCRIPT ]]; then
  [[ -n $DRY ]] || die "$SCRIPT is missing from the source — please report this."
  say "  (not present yet — the clone above was skipped)"
fi

# ── The actual setup ──────────────────────────────────────────────────────
say ""
say "${bold}Setup${off}  (nginx, certificate, service — may take a minute)"
say ""
# The DNS check already ran above, with more Cloudflare ranges than the inner
# script knows. Telling the operator the same thing twice, by two different
# rules, confuses more than it helps.
if [[ -n $DRY ]]; then
  say "  would run: $SCRIPT $DOMAIN $EMAIL"
  say ""
  say "  That script sets up the service user, the Python environment, the"
  say "  certificate, nginx and the systemd unit, then prints an acceptance"
  say "  list. It refuses to take over an existing relay without asking."
else
  BITDM_DNS_CHECKED=1 bash "$SCRIPT" "$DOMAIN" "$EMAIL"
fi

# ── What the operator needs to know now ──────────────────────────────────
say ""
say "${bold}Done.${off}${DRY:+ (dry run — nothing was changed)} Enter this in the app:"
say ""
say "    Settings > Receiving > server address"
say "    ${bold}wss://$DOMAIN${off}"
say ""
say "Clearing the field and applying returns you to the default at any time."
say ""
warn "Attachments also need a blob store, and there is no script for that yet."
say "      Without one they fail with an error that looks like a network problem."
say "      The manual route is in"
say "      $TARGET/secure-messenger/docs/ZWISCHENLAGER.md"
say ""
say "Everything else, with the reasoning:  https://bitdm.net/docs"
say ""
