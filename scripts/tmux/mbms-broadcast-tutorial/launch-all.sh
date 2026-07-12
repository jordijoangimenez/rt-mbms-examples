#!/usr/bin/env bash
#
# launch-all.sh -- bring the whole LTE-based 5G Broadcast stack up in the
# background (no tmux required), one log file per component. Companion to
# mbms-broadcast-tutorial.sh, which launches the same stack in tmux windows.
#
#   ./launch-all.sh            launch everything (background) and report
#   ./launch-all.sh --stop     stop everything this script started
#
# Config is shared with the tmux tutorial (same ./conf, same defaults); override
# any variable via the environment.
#
set -u

# =============================================================================
# CONFIG  (mirrors mbms-broadcast-tutorial.sh)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$SCRIPT_DIR/conf}"
SOAPY_ZMQ_DIR="${SOAPY_SDR_PLUGIN_PATH:-$HOME/soapy-zmq-bridge}"   # user-built zmqrx bridge

TX_DIR="${TX_DIR:-$HOME/rt-mbms-tx}"
GW_DIR="${GW_DIR:-$HOME/rt-mbms-gw}"
BMSC_DIR="${BMSC_DIR:-$HOME/rt-mbms-bmsc}"
MODEM_DIR="${MODEM_DIR:-$HOME/rt-mbms-modem}"
CLIENT_DIR="${CLIENT_DIR:-$HOME/rt-mbms-client}"
APP_DIR="${APP_DIR:-$HOME/rt-mbms-application}"
PORTAL_DIR="${PORTAL_DIR:-$HOME/rt-mbms-application-provider}"

SRSEPC="${SRSEPC:-$TX_DIR/build/srsepc/src/srsepc}"
SRSENB="${SRSENB:-$TX_DIR/build/srsenb/src/srsenb}"
MBMSGW="${MBMSGW:-$GW_DIR/build/mbms-gw/mbms-gw}"
BMSC="${BMSC:-$BMSC_DIR/build/bmsc/bmsc}"
MODEM="${MODEM:-$MODEM_DIR/build/modem}"
CLIENT_BIN="${CLIENT_BIN:-$CLIENT_DIR/build/client}"
# Uplink sample feeder: answers the eNB's ZMQ rx sample-requests on :2001 so its
# downlink-only radio can clock and stay paced. See tools/ul-feeder.cpp.
UL_FEEDER="${UL_FEEDER:-$SCRIPT_DIR/tools/ul-feeder}"
UL_FEEDER_ENDPOINT="${UL_FEEDER_ENDPOINT:-tcp://*:2001}"

EPC_CONF="${EPC_CONF:-epc.conf}"
ENB_CONF="${ENB_CONF:-enb_baseline.conf}"
GW_CONF="${GW_CONF:-mbms-gw.conf}"
BMSC_CONF="${BMSC_CONF:-bmsc.conf}"
MODEM_CONF="${MODEM_CONF:-modem_zmqtest.conf}"
CLIENT_CONF="${CLIENT_CONF:-client_recv.conf}"
# Client FLUTE receiver bind address. MUST be 0.0.0.0 (not a unicast iface IP):
# a socket bound to a unicast address won't receive multicast on Linux even with
# the group joined. The multicast group is joined via the route to it.
CLIENT_IFACE="${CLIENT_IFACE:-0.0.0.0}"

LOG_DIR="${LOG_DIR:-$HOME/.local/state/mbms-broadcast-tutorial}"
PID_FILE="$LOG_DIR/launch-all.pids"
STAGE_PAUSE="${STAGE_PAUSE:-2}"

# Which components run under sudo (see the tmux tutorial for the rationale).
SUDO_EPC="${SUDO_EPC:-sudo}"; SUDO_ENB="${SUDO_ENB:-}"; SUDO_GW="${SUDO_GW:-}"; SUDO_MODEM="${SUDO_MODEM:-}"

# NOTE on RF frequency: the eNB (network side) and the TV Service Configuration
# MO (receiver-side provisioning, in the modem's tv_config) are configured
# INDEPENDENTLY and MANUALLY -- the eNB does NOT read the MO. They must simply
# carry the SAME EARFCN by default so transmit and receive agree: keep
# enb_baseline.conf's dl_earfcn and modem_zmqtest.conf's tv_config ran_info in
# sync when you change the cell frequency.

# "Name|WorkingDir|Command|pause|sudo"
COMPONENTS=(
  "EPC|$CONF|$SRSEPC $EPC_CONF|$STAGE_PAUSE|$SUDO_EPC"
  "UL-Feeder|$CONF|$UL_FEEDER $UL_FEEDER_ENDPOINT|1|"
  "eNB|$CONF|$SRSENB $ENB_CONF|1|$SUDO_ENB"
  "MBMS-GW|$CONF|$MBMSGW $GW_CONF|1|$SUDO_GW"
  "BM-SC|$CONF|$BMSC $BMSC_CONF|1|"
  "Modem|$CONF|env SOAPY_SDR_PLUGIN_PATH=$SOAPY_ZMQ_DIR $MODEM -c $MODEM_CONF -b 10 -l 2 -s 4|$STAGE_PAUSE|$SUDO_MODEM"
  "Client|$CONF|$CLIENT_BIN -c $CLIENT_CONF -i $CLIENT_IFACE -l 2|1|"
  "Application|$APP_DIR|node app.js|1|"
  "Portal|$PORTAL_DIR|node --env-file=.env server.js|0|"
)

die() { echo "ERROR: $*" >&2; exit 1; }
require_exec() { [ -x "$1" ] || die "not executable: $1 (build it, or set its path variable)"; }

# Full teardown of the demo stack on this host, by process name -- so it clears
# leftovers regardless of how they were started (manual runs, previous launches).
# Single-deployment demo host only; do NOT use where a separate live srsenb/EPC
# must keep running.
stop_stack() {
  # SIGTERM everything (srsepc is root -> sudo).
  for b in srsenb ul-feeder mbms-gw bmsc modem; do
    pkill -x "$b" 2>/dev/null && echo "  $b"
  done
  # The client binary is named "client" -- too generic for pkill -x on a shared
  # host, so target it by its full build path instead.
  pkill -f "$CLIENT_BIN" 2>/dev/null && echo "  client (rt-mbms-client)"
  pkill -f 'node app.js' 2>/dev/null && echo "  application (app.js)"
  pkill -f 'node --env-file=.env server.js' 2>/dev/null && echo "  portal (server.js)"
  pgrep -x srsepc >/dev/null 2>&1 && { sudo pkill -x srsepc 2>/dev/null && echo "  srsepc (root)" || echo "  srsepc: run 'sudo pkill -x srsepc'"; }
  # Wait for them to die; escalate to SIGKILL at 4s (some catch SIGTERM).
  for i in 1 2 3 4 5 6 7 8; do
    left=""; for b in srsepc srsenb ul-feeder mbms-gw bmsc modem; do pgrep -x "$b" >/dev/null 2>&1 && left=1; done
    pgrep -f "$CLIENT_BIN" >/dev/null 2>&1 && left=1
    [ -z "$left" ] && break
    if [ "$i" = 4 ]; then
      for b in srsenb ul-feeder mbms-gw bmsc modem; do pkill -9 -x "$b" 2>/dev/null; done
      pkill -9 -f "$CLIENT_BIN" 2>/dev/null
      pgrep -x srsepc >/dev/null 2>&1 && sudo pkill -9 -x srsepc 2>/dev/null
    fi
    sleep 1
  done
  # SIGKILL can leave the S1-MME SCTP socket lingering a moment -- wait it out,
  # else the next srsepc hits "Error binding SCTP socket".
  for i in 1 2 3 4 5 6; do grep -q 36412 /proc/net/sctp/eps 2>/dev/null || break; sleep 1; done
  rm -f "$PID_FILE" 2>/dev/null || true
}

# =============================================================================
# --stop : tear down everything this script started
# =============================================================================
if [ "${1:-}" = "--stop" ] || [ "${1:-}" = "-k" ]; then
  echo "Stopping the LTE-broadcast demo stack..."
  stop_stack
  echo "Done."
  exit 0
fi

# --transmit-only: launch just the transmit side (EPC/eNB/MBMS-GW/BM-SC). Use this
# together with receive-netns.sh, which runs modem/client/application in a network
# namespace so their UDP :2153 doesn't collide with the eNB's M1-U receiver.
TRANSMIT_ONLY=0
{ [ "${1:-}" = "--transmit-only" ] || [ "${1:-}" = "-t" ]; } && TRANSMIT_ONLY=1

# =============================================================================
# Pre-flight
# =============================================================================
command -v node >/dev/null 2>&1 || die "'node' not found (Application/Portal are Node.js)"
[ -d "$CONF" ] || die "config dir not found: $CONF"
require_exec "$SRSEPC"; require_exec "$SRSENB"; require_exec "$MBMSGW"
require_exec "$BMSC";   require_exec "$MODEM";  require_exec "$CLIENT_BIN"
# ul-feeder: build on demand if the binary is missing (needs libzmq dev headers).
if [ ! -x "$UL_FEEDER" ] && [ -f "$UL_FEEDER.cpp" ]; then
  echo "Building ul-feeder..."
  g++ -std=c++17 "$UL_FEEDER.cpp" -o "$UL_FEEDER" $(pkg-config --cflags --libs libzmq) \
    || die "failed to build ul-feeder ($UL_FEEDER.cpp) -- need libzmq3-dev"
fi
require_exec "$UL_FEEDER"
[ -f "$APP_DIR/app.js" ]       || die "not found: $APP_DIR/app.js"
[ -f "$PORTAL_DIR/server.js" ] || die "not found: $PORTAL_DIR/server.js"
[ -f "$PORTAL_DIR/.env" ]      || echo "WARNING: $PORTAL_DIR/.env missing -- portal needs AUTH_TOKEN."
[ -f "$SOAPY_ZMQ_DIR/libzmqrxSupport.so" ] || echo "WARNING: no libzmqrxSupport.so in '$SOAPY_ZMQ_DIR' -- modem ZeroMQ RX needs the user-built 'zmqrx' bridge (see README). Not needed for a real SDR."

mkdir -p "$LOG_DIR"

# sudo once up front + keep-alive (never stores the password).
NEED_SUDO=0; printf '%s\n' "${COMPONENTS[@]}" | grep -q '|sudo$' && NEED_SUDO=1
SUDO_KEEPALIVE_PID=""
cleanup() { [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; }
trap cleanup EXIT
if [ "$NEED_SUDO" = 1 ]; then
  command -v sudo >/dev/null 2>&1 || die "'sudo' not found (EPC needs root)"
  echo "Some functions need root -- authenticating with sudo once..."
  sudo -v || die "sudo authentication failed"
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) & SUDO_KEEPALIVE_PID=$!
fi

# Clean start: fully tear down any existing stack first (leftovers, a previous
# run, or manually-started components) so nothing collides on the sockets. sudo
# is primed above, so the root srsepc is stopped too. This makes the launcher
# idempotent -- safe to run repeatedly for a demo.
echo "Clearing any existing stack for a clean start..."
stop_stack
sleep 2   # let sockets (especially the SCTP S1-MME socket) release before relaunch
# Sanity: warn if a stack port is somehow still bound after the clean.
for _p in 2100 2101 2102 3000 3010 3020 8080 8543; do
  ss -ltn 2>/dev/null | grep -q ":${_p} " && echo "NOTE: port ${_p} still in use after cleanup -- check for a process outside this stack."
done

# =============================================================================
# Launch: each component backgrounded (nohup), one log file per component
# =============================================================================
: > "$PID_FILE"
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r name workdir cmd pause usesudo <<<"$entry"
  if [ "$TRANSMIT_ONLY" = 1 ]; then
    case "$name" in
      Modem|Client|Application)
        echo "Skipping $name (transmit-only; run the receive side with: sudo ./receive-netns.sh)"; continue ;;
    esac
  fi
  [ "$usesudo" = "sudo" ] && cmd="sudo $cmd"
  log="$LOG_DIR/${name}.log"
  echo "Starting $name  (log: $log)"
  ( cd "$workdir" && exec nohup $cmd >"$log" 2>&1 ) &
  echo "$name $!" >> "$PID_FILE"
  sleep "${pause:-1}"
done

echo
echo "All components launched in the background. Logs: $LOG_DIR/<Name>.log"
echo "Listening ports:"; ss -ltn 2>/dev/null | grep -oE ':(2100|2101|2102|3000|3010|3020|8080|8543)\b' | sort -u | sed 's/^/  /'
echo "Stop everything with:  $0 --stop"
