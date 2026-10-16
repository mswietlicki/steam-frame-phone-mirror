#!/bin/sh
# Runs inside the phone-mirror container, started by ~/.local/bin/phone-mirror.
# /data is ~/.local/share/phone-mirror/home: adb's key (the pairing) and caches.
# Alpine's adb has no working mDNS, so the launcher looks phones up with the
# host's Avahi and passes them in: PHONE_ADDRS (wireless debugging, ip:port ...)
# and PAIR_ADDR (the pairing service, ip:port).
#
#   inside.sh run [SCRCPY_ARGS...]   connect to the paired phone, then start scrcpy (exit 3: no phone)
#   inside.sh pair                   pair a phone; asks for its pairing code
#   inside.sh status                 adb key and connected phones
set -u
export HOME=/data

# Connected phones. Lepton containers listen on 5555+ while they run, and adb
# picks those up as emulator-NNNN: skip them.
phones() { adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1 }'; }

find_phone() {
  adb start-server > /dev/null 2>&1
  s=$(phones | head -n 1)
  [ -n "$s" ] && { echo "$s"; return 0; }
  for a in ${PHONE_ADDRS:-}; do
    timeout 5 adb connect "$a" > /dev/null 2>&1
    s=$(phones | head -n 1)
    [ -n "$s" ] && { echo "$s"; return 0; }
  done
  return 1
}

prop() { adb -s "$1" shell getprop "$2" 2> /dev/null | tr -d '\r'; }
describe() { echo "$1, $(prop "$1" ro.product.model), Android $(prop "$1" ro.build.version.release)"; }

case "${1:-}" in
  run)
    shift
    serial=$(find_phone) || { echo "no phone found (tried: ${PHONE_ADDRS:-none})"; exit 3; }
    echo "phone: $(describe "$serial")"
    exec scrcpy -s "$serial" --window-title=Phone "$@"
    ;;
  pair)
    if [ -n "${PAIR_ADDR:-}" ]; then
      printf 'Phone found at %s. Press Enter to use it, or type the "IP address & port" shown under the code: ' "$PAIR_ADDR"
    else
      printf 'Type the "IP address & port" shown under the code: '
    fi
    read -r addr
    addr=${addr:-${PAIR_ADDR:-}}
    [ -n "$addr" ] || { echo "No address given."; exit 1; }
    adb start-server > /dev/null 2>&1
    adb pair "$addr"   # asks for the 6-digit code
    ;;
  status)
    if [ -f "$HOME/.android/adbkey" ]; then echo "adb key: yes"; else echo "adb key: none"; fi
    find_phone > /dev/null
    n=0
    for s in $(phones); do
      echo "connected: $(describe "$s")"
      n=$((n + 1))
    done
    [ $n -gt 0 ] || { echo "connected: none"; exit 3; }
    ;;
  *)
    echo "usage: inside.sh run [SCRCPY_ARGS...] | pair | status" >&2
    exit 2
    ;;
esac
