#!/usr/bin/env bash
# controls for spotify UI-less
set -o pipefail
 
cmd="$1"; shift
STATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/spotify-vol-toggle"
 
{
case "$cmd" in
  p)
    spotify_player playback play-pause ;;
  +)
    spotify_player playback next ;;
  -)
    spotify_player playback previous ;;
  v)
    # spotify is managed through Spotify Connect, costing ~300ms/call
    # modifying pipewire sound locally cost ~10ms
    sink_idx=$(pactl list sink-inputs | awk '
      /^Sink Input #/{i=$3; sub("#","",i)}
      /application.name = "spotify-player"/{print i; exit}')
    if [[ -z "$sink_idx" ]]; then
      echo "nothing playing right now, no stream to adjust" >&2
      exit 1
    fi
    if [[ -n "$1" ]]; then
      echo "$1" > "$STATE_FILE"
      pactl set-sink-input-volume "$sink_idx" "$1%"
    else
      pactl set-sink-input-mute "$sink_idx" toggle
    fi ;;
  status)
    spotify_player get key playback | jq -r \
      '"\(if .is_playing then "playing" else "paused" end): \(.item.name) - \(.item.artists[0].name) [\(.device.volume_percent)%]"' ;;
  *)
    echo "usage: spotify {p|+|-|v [0-100]|status}" ;;
esac
} | sed '/^$/d'
 
