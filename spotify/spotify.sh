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

{
case "$cmd" in
  p)
    spotify_player playback play-pause ;;
  +)
    spotify_player playback next ;;
  -)
    spotify_player playback previous ;;
  v)
    # volume through spotify use `Spotify Connect`, costing ~300ms/call (network)
    # pipewire costing ~10ms/call (local)
    sink_idx=$(find_sink_idx)
    if [[ -z "$sink_idx" ]]; then
      echo "nothing playing right now" >&2
      exit 1
    fi
    if [[ -n "$1" ]]; then
      echo "$1" > "$STATE_FILE"
      pactl set-sink-input-volume "$sink_idx" "$1%"
    else
      pactl set-sink-input-mute "$sink_idx" toggle
    fi ;;
  "")
    # no arg: launch spotify_player or music/vol status
    track=$(spotify_player get key playback 2>/dev/null | jq -r \
      'if .item == null then empty else
        "\(if .is_playing then "playing" else "paused" end): \(.item.name) - \(.item.artists[0].name)"
      end' 2>/dev/null)
    [[ -z "$track" ]] && exit 0
    sink_idx=$(find_sink_idx)
    if [[ -n "$sink_idx" ]]; then
      vol=$(sink_volume "$sink_idx")
      echo "$track [${vol:-?}%]"
    else
      echo "$track [no Pipewire]"
    fi ;;
  *)
    echo "usage: spotify {p|+|-|v [0-100]}" ;;
esac
} | sed '/^$/d'

