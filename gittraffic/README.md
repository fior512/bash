# github_traffic.sh

Tracks clones and unique cloners for your GitHub repos over time. GitHub's traffic API only keeps 14 days of history, so this script fetches it periodically and appends to a local JSON file, meant to run from a cron job so the numbers don't get lost.

## Usage

```bash
export GITHUB_TOKEN=<personal access token, needs repo read scope>
export GITHUB_USER=<your github username>

./github_traffic.sh -w    # fetch latest traffic, write to history, print a summary table
./github_traffic.sh -W    # same, but compressed one-line output (for cron)
./github_traffic.sh -r    # read and display aggregated history (default with no flags)
./github_traffic.sh -l    # print the last log lines
./github_traffic.sh -h    # help
```

Cron example (twice a day, quiet):
```cron
0 */12 * * * GITHUB_TOKEN=... GITHUB_USER=... /path/to/github_traffic.sh -W >> /path/to/cron.log 2>&1
```

## Implementation

| | |
|---|---|
| Lines | 266 |
| Dependencies | `bash`, `curl`, `python3` with the `tabulate` package (`pip install tabulate`) |
| Parametrization | `GITHUB_TOKEN` / `GITHUB_USER` - required env vars, script exits if unset when `-w`/`-W` is used. `DATA_FILE` / `LOG_FILE` - optional env vars, default to `~/.local/share/gittraffic/`. `REPOS` array at the top of the script - **edit this by hand** to list the repos you want tracked. |

`-w`/`-W` hit `GET /repos/{user}/{repo}` and `GET /repos/{user}/{repo}/traffic/clones` per repo in `REPOS`, merge new daily entries into `DATA_FILE` (keyed by date, so re-running is idempotent), and append a row to `LOG_FILE`. `-r` reads `DATA_FILE` and prints totals, first/last data point, and a rough gap estimate per repo.
