# Spotify (UI-less)

I run Spotify without a UI to keep it out of my benchmark results. The official client renders frames I never look at, through Electron and the GPU. I only need the backend to play music.

## Setup

Spotify now runs through `spotify_player`, a headless Spotify client. 
It has no UI. It uses between 5x less CPU and 10 to 5x less RAM than the official Spotify client.

## spotify.sh

`spotify.sh` is a thin wrapper around `spotify_player`. It exposes short commands for a keybinding or a launcher.

| Command | Action |
|---|---|
| `p` | Toggle play or pause. |
| `+` | Skip to the next track. |
| `-` | Skip to the previous track. |
| `v [0-100]` | Set volume to a percent. |
| `v` | Toggle to mute/unmute music |
| `status` | Print the track, the artist, and the volume. |

`spotify_player` controls playback through Spotify Connect, Spotify's own remote-control protocol. Every play or pause command goes through Spotify's servers, adding ~300ms of latency (humanly noticeable).
`v` toggle-mute is a UX workaround for this. It mutes `PipeWire` locally instead of pausing through Spotify Connect. This gives ~10ms of latency for a "pause", +30x throughput ^^.
