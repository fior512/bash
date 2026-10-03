#!/usr/bin/env bash
# controls for spotify UI-less
#
set -o pipefail
 
cmd="$1"; shift
STATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/spotify-vol-toggle"

# find pipewire line
find_sink_idx() {
  pactl list sink-inputs | awk '
    /^Sink Input #/{i=$3; sub("#","",i)}
    /application.name = "spotify-player"/{print i; exit}'
}

#read vol pipewire
sink_volume() {
  pactl list sink-inputs | awk -v idx="$1" '
    /^Sink Input #/{in_block=($3=="#"idx)}
    in_block && /Volume:/{
      match($0, /[0-9]+%/); print substr($0, RSTART, RLENGTH-1); exit
    }'
}

#read mute pipewire
sink_mute() {
  pactl list sink-inputs | awk -v idx="$1" '
    /^Sink Input #/{in_block=($3=="#"idx)}
    in_block && /Mute:/{print ($2=="yes")?"1":"0"; exit}'
}

#ensure playlist repeat
ensure_loop() {
  local repeat_state
  repeat_state=$(spotify_player get key playback 2>/dev/null \
    | jq -r '.repeat_state // empty')
  case "$repeat_state" in
    context) ;;
    off) spotify_player playback repeat >/dev/null 2>&1 ;;
    track)
      spotify_player playback repeat >/dev/null 2>&1
      spotify_player playback repeat >/dev/null 2>&1 ;;
  esac
}

# make sure the spotify_player daemon (the "spotify-player" device) is running
has_device() {
  spotify_player get key devices 2>/dev/null \
    | jq -e 'any(.[]; .name == "spotify-player")' >/dev/null 2>&1
}
is_active_device() {
  spotify_player get key devices 2>/dev/null \
    | jq -e 'any(.[]; .name == "spotify-player" and .is_active)' >/dev/null 2>&1
}
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/spotify-daemon-launch.lock"
ensure_daemon() {
  has_device && return 0
  if ! pgrep -x spotify_player >/dev/null; then
    (
      flock -n 9 || exit 0
      spotify_player -d >/dev/null 2>&1 &
    ) 9>"$LOCK_FILE"
  fi
  for _ in $(seq 1 60); do
    sleep 0.5
    has_device && return 0
  done
  echo "spot: spotify_player daemon not available (run 'spotify_player -d' to debug)" >&2
  exit 1
}
ensure_active_device() {
  is_active_device && return 0
  spotify_player connect --name spotify-player >/dev/null 2>&1
  for _ in $(seq 1 10); do
    sleep 0.2
    is_active_device && return 0
  done
  echo "spot: could not activate spotify-player device" >&2
  return 1
}
ensure_daemon
ensure_loop

{
case "$cmd" in
  p)
    ensure_active_device || exit 1
    spotify_player playback play-pause || { echo "spot: play-pause failed" >&2; exit 1; } ;;
  +)
    ensure_active_device || exit 1
    spotify_player playback next || { echo "spot: next failed" >&2; exit 1; } ;;
  -)
    ensure_active_device || exit 1
    spotify_player playback previous || { echo "spot: previous failed" >&2; exit 1; } ;;
  s)
    ensure_active_device || exit 1
    before=$(spotify_player get key playback 2>/dev/null \
      | jq -r '.shuffle_state // "unknown"')
    spotify_player playback shuffle
    state="$before"
    for _ in 1 2 3 4 5; do
      sleep 0.3
      state=$(spotify_player get key playback 2>/dev/null \
        | jq -r '.shuffle_state // "unknown"')
      [[ "$state" != "$before" ]] && break
    done
    if [[ "$state" == "true" ]]; then
      echo "shuffle: on"
    else
      echo "shuffle: off"
    fi ;;
  v)
    # volume through spotify use `Spotify Connect`, costing ~300ms/call (network)
    # pipewire costing ~10ms/call (local)
    sink_idx=$(find_sink_idx)
    if [[ -z "$sink_idx" ]]; then
      if is_active_device; then
        echo "spotify-player active but no PipeWire stream (paused, or audio not routed)" >&2
      else
        echo "spotify-player device not active, nothing playing" >&2
      fi
      exit 1
    fi
    if [[ -n "$1" ]]; then
      echo "$1" > "$STATE_FILE"
      pactl set-sink-input-volume "$sink_idx" "$1%"
      pactl set-sink-input-mute "$sink_idx" 0
    else
      pactl set-sink-input-mute "$sink_idx" toggle
    fi ;;
  "")
    # no arg: launch spotify_player or music+vol status
    ensure_active_device
    track=$(spotify_player get key playback 2>/dev/null | jq -r \
      'if .item == null then empty else
        "\(if .is_playing then "playing" else "paused" end): \(.item.name) - \(.item.artists[0].name)"
      end' 2>/dev/null)
    if [[ -z "$track" ]]; then
      echo "nothing playing" >&2
      exit 0
    fi
    sink_idx=$(find_sink_idx)
    if [[ -z "$sink_idx" && "$track" == playing:* ]]; then
      # "paused" || "playing"
      track="paused${track#playing}"
    fi
    if [[ -n "$sink_idx" ]]; then
      vol=$(sink_volume "$sink_idx")
      muted=$(sink_mute "$sink_idx")
      [[ "$muted" == "1" ]] && track="$track (muted)"
      echo "$track [${vol:-?}%]"
    else
      echo "$track [no Pipewire]"
    fi ;;
  *)
    echo "usage: spotify {p|+|-|s|v [0-100]}" ;;
esac
} | sed '/^$/d'

