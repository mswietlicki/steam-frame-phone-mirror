#!/usr/bin/env bash
# Steam Frame phone mirror: install, update, pair, check or remove.
# Run it ON the Frame (Konsole on the headset desktop, or over SSH as steamos):
#
#   ./install.sh                     # install, or rebuild after you update this repo
#   ./install.sh install --update    # ...and get the newest scrcpy and Alpine packages
#   ./install.sh pair                # pair your phone (asks for its pairing code)
#   ./install.sh status              # image, versions, phones on the network
#   ./install.sh uninstall           # remove it (keeps the pairing and your options)
#   ./install.sh uninstall --purge   # ...and those too
#
# Or without cloning:
#   curl -fsSL https://raw.githubusercontent.com/mswietlicki/steam-frame-phone-mirror/main/install.sh | bash
#
# No root, nothing outside your home directory, survives SteamOS updates.
set -euo pipefail

REPO=mswietlicki/steam-frame-phone-mirror
IMAGE=localhost/phone-mirror:latest
BASE=docker.io/library/alpine:3.24   # keep in step with files/Containerfile
NAME=phone-mirror

bin=$HOME/.local/bin
data=$HOME/.local/share/phone-mirror
apps=$HOME/.local/share/applications
conf=$HOME/.config/phone-mirror/options
desktop=phone-mirror.desktop

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Piped from curl: fetch the rest of the repo and run its copy of this script.
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2> /dev/null && pwd || echo /nonexistent)
if [[ ! -f $here/files/Containerfile ]]; then
  tmp=$(mktemp -d /tmp/steam-frame-phone-mirror.XXXXXX)
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp" --strip-components=1
  exec bash "$tmp/install.sh" "$@"
fi
src=$here/files

check() {
  [[ $(id -u) != 0 ]] || die "run it as your normal user (steamos), not root"
  local c
  for c in podman avahi-browse; do
    command -v "$c" > /dev/null || die "$c is missing (it comes with SteamOS on the Frame)"
  done
}

# Rootless podman creates its cgroups through systemd on the session bus, and
# the desktop's Konsole has a bus of its own without systemd: name the user bus.
pod() {
  env "XDG_RUNTIME_DIR=/run/user/$(id -u)" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" podman "$@"
}
image_id() { pod image inspect -f '{{.Id}}' "$IMAGE" 2> /dev/null || true; }
running() { [[ $(pod inspect -f '{{.State.Running}}' "$NAME" 2> /dev/null) == true ]]; }
paired() { [[ -f $data/home/.android/adb_known_hosts.pb ]]; }

versions() {
  pod run --rm "$IMAGE" sh -c 'scrcpy --version | head -n 1; adb version | sed -n 2p; echo "Alpine $(cat /etc/alpine-release)"' \
    | sed 's/^/  /'
}

do_install() {
  check
  local old new build=(pod build -t "$IMAGE" -f "$src/Containerfile")
  [[ ${1:-} == --update ]] && build+=(--no-cache --pull=always)
  old=$(image_id)
  say "Building $IMAGE (the first time takes a minute or two; the image is about 800 MB)"
  "${build[@]}" "$src" > /dev/null
  new=$(image_id)
  if [[ -n $old && $old != "$new" ]]; then
    pod rmi "$old" > /dev/null 2>&1 || echo "The old image is still in use; it goes once Phone is closed (podman image prune)."
  fi

  mkdir -p "$data/home" "$bin" "$apps" "${conf%/*}"
  install -m 644 "$src/inside.sh" "$data/inside.sh"
  install -m 755 "$src/phone-mirror" "$bin/phone-mirror"
  sed "s#@BIN@#$bin#" "$src/$desktop" > "$apps/$desktop"
  [[ -f $conf ]] || install -m 644 "$src/options" "$conf"

  versions
  say "Installed. In the headset: dashboard > + > Launch Program > Phone."
  if ! paired; then
    echo "Next, pair your phone, in a terminal: ~/.local/bin/phone-mirror pair"
  fi
}

do_status() {
  if [[ -z $(image_id) ]]; then
    echo "image: not built (run ./install.sh)"
    return
  fi
  echo "image: $IMAGE, $(pod image inspect -f '{{.Size}}' "$IMAGE" | numfmt --to=iec), built $(pod image inspect -f '{{.Created}}' "$IMAGE" | cut -d. -f1)"
  versions
  echo "launcher: $([[ -x $bin/phone-mirror ]] && echo "$bin/phone-mirror" || echo missing)"
  echo "menu entry: $([[ -f $apps/$desktop ]] && echo "$apps/$desktop" || echo missing)"
  echo "paired: $(paired && echo yes || echo no)"
  echo "running: $(running && echo yes || echo no)"
  "$bin/phone-mirror" status || true
}

do_uninstall() {
  if running; then
    echo "Closing Phone"
    pod stop -t 5 "$NAME" > /dev/null
  fi
  pod rm -f "$NAME" > /dev/null 2>&1 || true
  pod rmi "$IMAGE" > /dev/null 2>&1 || true
  pod rmi "$BASE" > /dev/null 2>&1 || true
  rm -f "$bin/phone-mirror" "$apps/$desktop" "$data/inside.sh" "$data/last.log"
  if [[ ${1:-} == --purge ]]; then
    rm -rf "$data" "${conf%/*}"
    say "Removed, with the pairing and your options."
    echo "Also remove the Frame on the phone: Wireless debugging > Paired devices."
  else
    say "Removed. Kept the pairing ($data/home) and $conf; uninstall --purge deletes them."
  fi
}

case "${1:-install}" in
  install) shift || true; do_install "$@" ;;
  pair)
    [[ -x $bin/phone-mirror ]] || die "not installed yet: run ./install.sh first"
    [[ -t 0 ]] || die "pair asks for the phone's pairing code: run it in a terminal"
    exec "$bin/phone-mirror" pair
    ;;
  status) do_status ;;
  uninstall|remove) shift; do_uninstall "$@" ;;
  -h|--help) sed -n '2,15p' "$0" ;;
  *) die "unknown command '$1' (see --help)" ;;
esac
