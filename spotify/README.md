# Spotify (UI-less)

I moved Spotify to UI-less usage to reduce CPU usage reducing noise during low-latency benchmarks while keeping music. The official client renders frames i don't need, plus Electron optimized-less memory usage.

## Setup

Spotify now runs through `spotify_player`, a headless Spotify client. 
It has no UI. It uses between 5x less CPU and 10 to 5x less RAM than the official Spotify client.

## spotify.sh

`spotify.sh` is a thin wrapper around `spotify_player`. It exposes short commands for a keybinding or a launcher.

| Command | Action |
|---|---|
| ` ` | Boot spotify, toggle with status | 
| `p` | Toggle play or pause. |
| `+` | Skip to the next track. |
| `-` | Skip to the previous track. |
| `v [0-100]` | Set volume to a percent. |
| `v` | Toggle to mute/unmute music |

`spotify_player` controls playback through Spotify Connect, Spotify's own remote-control protocol. Every play or pause command goes through Spotify's servers, adding ~300ms of latency (humanly noticeable).
`v` toggle-mute is a UX workaround for this. It mutes `PipeWire` locally instead of pausing through Spotify Connect. This gives ~10ms of latency for a "pause", +30x throughput ^^.
