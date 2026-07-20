# Nuni.sh

Quick static scan for leftover dev artifacts before pushing to prod: hardcoded secrets, debug prints, TODO/FIXME/HACK comments, tabs, trailing whitespace, overlong lines, hardcoded paths/URLs, and similar smells. Prints a findings report grouped by severity (CRITICAL/ERROR/WARNING/INFO).

## Usage

```bash
./Nuni.sh [OPTIONS] [DIRECTORY] [FILE_PATTERN]
```

```bash
./Nuni.sh                                # scan current directory, all files
./Nuni.sh src/ "*.py"                    # scan src/, only .py files
./Nuni.sh --strict                       # exit 1 if any issue is found (for CI)
./Nuni.sh -v                             # show every matching line, not just the first 5
./Nuni.sh --copyright "Your Name"        # also flag files missing a copyright header
./Nuni.sh -l                             # list all detection rules and exit
./Nuni.sh -c                             # disable colored output
```

`test_sample.txt` and `test_ai_artefacts.txt` are fixtures used to exercise the ruleset - they intentionally contain the issues the scanner looks for (tabs, secrets, TODOs, long lines, etc.) and are not meant to be "clean".

## Implementation

| | |
|---|---|
| Lines | 368 |
| Dependencies | `bash`, `grep -P` (PCRE support), `file`, `od`, `sed`, `awk` |
| Parametrization | No secrets or hardcoded environment values - the only required argument is `--copyright NAME` when using `--copyright`. Detection patterns (regex + severity) live in the `PATTERNS` array near the top of the script; edit there to add/remove rules. `MAX_LINES_PER_PATTERN` (default 5, unlimited with `-v`) caps how many matching lines are shown per rule. |

Each file is matched against every entry in `PATTERNS` (`name|regex|description|severity`) with `grep -P`, plus two special-cased checks (BOM byte detection via `od`, line-length via a read loop). Results are grouped by severity and printed with counts; `--strict` turns findings into a non-zero exit code for CI gating.
