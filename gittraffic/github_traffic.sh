#!/bin/bash
# github_traffic.sh

GITHUB_TOKEN="${GITHUB_TOKEN:-YOUR_GITHUB_TOKEN}"
GITHUB_USER="${GITHUB_USER:-YOUR_GITHUB_USERNAME}"
DATA_FILE="${DATA_FILE:-$HOME/.local/share/gittraffic/github_traffic_history.json}"
LOG_FILE="${LOG_FILE:-$HOME/.local/share/gittraffic/github_traffic.log}"
PYTHON=$(command -v python3)
CURL=$(command -v curl)

# Repos to track - edit this list for your own account.
REPOS=(
    "your-repo-1"
    "your-repo-2"
)

DO_WRITE=false
SILENT=false
DO_READ=false
PRINT_LOG=false
SHOW_HELP=false

while getopts "wrWhl" opt; do
    case "$opt" in
        w) DO_WRITE=true;  SILENT=false ;;
        W) DO_WRITE=true;  SILENT=true  ;;
        r) DO_READ=true ;;
        l) PRINT_LOG=true ;;
        h) SHOW_HELP=true ;;
        *) SHOW_HELP=true ;;
    esac
done

if [ $# -eq 0 ]; then
    DO_READ=true
fi

show_help() {
    echo "Usage: $(basename $0) [-w] [-W] [-r] [-l] [-h]"
    echo ""
    echo "  -w   fetch from GitHub API and write to history"
    echo "  -W   cron mode, compressed output"
    echo "  -r   read and display aggregated history"
    echo "  -l   print last log"
    echo "  -h   show this help"
    echo ""
}

if [ "$SHOW_HELP" = true ]; then
    show_help
    exit 0
fi

if [ "$DO_WRITE" = true ]; then

    if [ "$GITHUB_TOKEN" = "YOUR_GITHUB_TOKEN" ] || [ "$GITHUB_USER" = "YOUR_GITHUB_USERNAME" ]; then
        echo "Set GITHUB_TOKEN and GITHUB_USER (env vars) before running -w/-W." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$DATA_FILE")"
    [ ! -f "$DATA_FILE" ] && echo '{}' > "$DATA_FILE"
    WRITE_LOG=$(mktemp)

    for REPO in "${REPOS[@]}"; do

        REPO_META=$($CURL -s \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/$GITHUB_USER/$REPO")

        CLONES=$($CURL -s \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/$GITHUB_USER/$REPO/traffic/clones")

        $PYTHON - <<EOF
import json
from datetime import datetime, timezone

data_file = "$DATA_FILE"
repo      = "$REPO"
log_file  = "$WRITE_LOG"
meta      = json.loads('''$REPO_META''')
new_data  = json.loads('''$CLONES''')

if "message" in new_data:
    row = f"{repo}\t-\t-\t-\t-\te\t{new_data['message']}"
    with open(log_file, 'a') as f:
        f.write(row + '\n')
    raise SystemExit(0)

with open(data_file, 'r') as f:
    history = json.load(f)

if repo not in history:
    history[repo] = {
        "created":    meta.get("created_at", ""),
        "last_write": "",
        "zero_days":  0,
        "clones":     {}
    }

try:
    existing_dates = set(history[repo]["clones"].keys())
    last_write_ts  = history[repo].get("last_write", "1970-01-01T00:00:00Z")

    for entry in new_data.get("clones", []):
        if entry["count"] == 0 and entry["uniques"] == 0:
            continue
        ts = entry["timestamp"]
        history[repo]["clones"][ts] = {
            "count":   entry["count"],
            "uniques": entry["uniques"]
        }

    # recompute zero_days from actual stored data
    dates = sorted(history[repo]["clones"].keys())
    if dates:
        first_dt   = datetime.fromisoformat(dates[0].replace('Z',''))
        last_dt    = datetime.fromisoformat(dates[-1].replace('Z',''))
        inner_span = (last_dt - first_dt).days + 1
        history[repo]["zero_days"] = inner_span - len(dates)

    history[repo]["last_write"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT00:00:00Z")

    with open(data_file, 'w') as f:
        json.dump(history, f, indent=2)

    new_dates  = set(history[repo]["clones"].keys()) - existing_dates
    compressed = [e for e in new_data.get("clones", [])
                  if e["count"] == 0 and e["uniques"] == 0
                  and e["timestamp"] > last_write_ts]
    total_c    = sum(history[repo]["clones"][ts]["count"]   for ts in new_dates)
    total_u    = sum(history[repo]["clones"][ts]["uniques"] for ts in new_dates)
    row = f"{repo}\t{len(new_dates)}\t{total_c}\t{total_u}\t{len(compressed)}\tOK\t"

except Exception as e:
    row = f"{repo}\t-\t-\t-\t-\te\t{str(e)}"

with open(log_file, 'a') as f:
    f.write(row + '\n')

EOF

    done

    if [ "$SILENT" = false ]; then
        $PYTHON - "$WRITE_LOG" <<'EOF'
import sys
from tabulate import tabulate

rows   = []
errors = []

with open(sys.argv[1]) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        repo, days, clones, uniques, compressed, status, err = parts
        if status == 'e':
            rows.append([repo, '-', '-', '-', '-', '✗'])
            errors.append((repo, err))
        else:
            rows.append([repo, days, clones, uniques, compressed, '✓'])

print(tabulate(rows,
    headers=["REPO", "+DAYS", "CLONES", "UNIQUES", "COMPRESSED", ""],
    tablefmt="rounded_outline",
    colalign=("left","right","right","right","right","center")
))

if errors:
    print("\nErrors:")
    for repo, err in errors:
        print(f"  {repo}: {err}")
EOF
        echo ""
        echo "Done. Data stored in $DATA_FILE"

    else
        $PYTHON - "$WRITE_LOG" <<'EOF'
import sys
from datetime import datetime
print("\n~~~[ " + datetime.now().strftime("%H:%M:%S %d/%m/%y") + " ]~~~")
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        repo, days, clones, uniques, compressed, status, err = parts
        if status == 'e':
            print(f"ERROR {repo}: {err}")
        else:
            print(f"OK {repo} +{days}d clones={clones} uniques={uniques} compressed={compressed}")
EOF

    fi

    rm -f "$WRITE_LOG"

fi

if [ "$DO_READ" = true ]; then

    if [ ! -f "$DATA_FILE" ]; then
        echo "No history yet at $DATA_FILE. Run with -w first." >&2
        exit 1
    fi
    $PYTHON - "$DATA_FILE" <<'EOF'
import json, sys
from datetime import datetime
from tabulate import tabulate

with open(sys.argv[1]) as f:
    data = json.load(f)

def fmt_date(ts):
    return datetime.fromisoformat(ts.replace('Z','')).strftime('%d/%m/%y')

grand_clones = grand_uniques = 0
rows = []

for repo, info in data.items():
    clones = info.get('clones', {})

    if not clones:
        rows.append([repo, '(no data)', '', '', '', '', ''])
        continue

    dates = sorted(clones.keys())

    total_clones  = sum(v['count']   for v in clones.values())
    total_uniques = sum(v['uniques'] for v in clones.values())
    grand_clones  += total_clones
    grand_uniques += total_uniques

    first      = fmt_date(info.get('created', dates[0]))
    last       = fmt_date(dates[-1])
    created    = datetime.fromisoformat(info.get('created',    dates[0]).replace('Z',''))
    last_write = datetime.fromisoformat(info.get('last_write', dates[-1]).replace('Z',''))
    zero_days  = info.get('zero_days', 0)
    span       = (last_write - created).days
    true_gaps  = span - len(dates) - zero_days
    gap_str    = f"{true_gaps}d" if true_gaps > 0 else "none"

    proj     = true_gaps / (len(dates) + zero_days) if true_gaps > 0 and len(dates) > 0 else 0
    proj_str = f"{proj:.1f}x" if proj > 0 else "-"

    rows.append([repo, total_clones, total_uniques, first, last, gap_str, proj_str])

rows.sort(key=lambda x: x[1] if isinstance(x[1], int) else -1, reverse=True)
rows.append(['-', '-', '-', '-', '-', '-', '-'])
rows.append(['TOTAL', grand_clones, grand_uniques, '', '', '', ''])

print(tabulate(rows,
    headers=["REPO", "CLONES", "UNIQUE CLONERS", "FIRST DATA", "LAST UPDATE", "GAPS", "PROJ"],
    tablefmt="rounded_outline",
    colalign=("left","right","right","center","center","right","right")
))
EOF

    echo ""
fi

if [ "$PRINT_LOG" = true ]; then
    tail -n 8 "$LOG_FILE"
fi
