#!/bin/bash
#
# Nuni.sh - static dev-artefact scanner
#
# Scans files for leftover dev artefacts before pushing to prod:
#   --ai      AI artefacts: zero-width/invisible Unicode, homoglyphs,
#             bidi control chars, soft hyphens/NBSP, smart quotes/dashes,
#             AI placeholder markers, AI attribution/disclaimers
#   --code    Code smells: comments (TODO/FIXME/...), leftover debug code,
#             placeholder git clones, security (secrets, keys, tokens,
#             private keys)
#   --format  Formatting: tabs, leading tabs, trailing whitespace, multiple
#             empty lines, line length, non-ASCII, CRLF, BOM
#   --path    Hardcoded paths, URLs, IP addresses, env-var paths
#   --license Copyright/licensing hygiene: placeholder copyright headers,
#             future copyright years
#   --all     All profiles (default when no profile flag is given)
#
# Usage: ./Nuni.sh [OPTIONS] [DIRECTORY] [FILE_PATTERN]

# --- Colors ------------------------------------------------------------------
if [[ -t 1 ]] && [[ "$TERM" != "dumb" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# --- Defaults -----------------------------------------------------------------
SEARCH_DIR="."
FILE_PATTERN="*"
USE_COLORS=true
CHECK_COPYRIGHT=false
COPYRIGHT_HOLDER=""
STRICT_MODE=false
VERBOSE=false
LIST_RULES=false

MAX_LINES_PER_PATTERN=5

# Directories never scanned by default (--no-exclude scans them anyway):
# VCS metadata, dependencies, build/compile artifacts, and hidden (dot)
# folders such as .FOLDER/ .cache/ .venv/ ... Edit or extend as needed.
EXCLUDE_DIRS=".git .svn .hg node_modules bower_components vendor .venv venv env __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .eggs .gradle .idea .vscode .vs .next .nuxt .svelte-kit .parcel-cache .turbo .cache .npm .yarn .dart_tool .cargo target build builds dist out bin obj Library Temp Logs UserSettings .terraform .serverless .amplify CMakeFiles DerivedData Pods .build xcuserdata"
SKIP_EXCLUDED=true

# File formats NEVER scanned, even with --no-exclude (binary/image/media).
EXT_EXCLUDE="png jpg jpeg gif webp bmp ico tif tiff avif heic svg psd pdf exe dll so dylib a o lib class jar war zip gz tgz tar bz2 xz 7z rar deb rpm apk aab dmg iso woff woff2 ttf otf eot mp3 mp4 mkv avi mov wav flac ogg webm pyc pyo pyd pdb db sqlite sqlite3 bin dat"

declare -A pattern_counts      # pattern name -> files affected
declare -A pattern_hits_total  # pattern name -> total matching lines
declare -A issue_order
files_with_issues=0
files_scanned=0
total_issues_count=0

# --- Unicode character classes (PCRE \x{...} syntax) --------------------------
C_ZW='\x{200B}\x{200C}\x{200D}\x{2060}\x{2061}\x{2062}\x{2063}\x{2064}\x{FEFF}\x{034F}\x{180E}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{2800}'
C_BIDI='\x{200E}\x{200F}\x{202A}\x{202B}\x{202C}\x{202D}\x{202E}\x{2066}\x{2067}\x{2068}\x{2069}\x{061C}'
C_SOFT='\x{00AD}\x{00A0}\x{2007}\x{202F}'
C_TYPO='\x{2013}\x{2014}\x{2015}\x{2018}\x{2019}\x{201A}\x{201B}\x{201C}\x{201D}\x{201E}\x{201F}\x{2026}\x{2032}\x{2033}'
H_CY='\x{0410}\x{0412}\x{0415}\x{041A}\x{041C}\x{041D}\x{041E}\x{0420}\x{0421}\x{0422}\x{0423}\x{0425}\x{0430}\x{0435}\x{043E}\x{0440}\x{0441}\x{0443}\x{0445}'
H_GR='\x{0391}\x{0392}\x{0395}\x{0396}\x{0397}\x{0399}\x{039A}\x{039C}\x{039D}\x{039F}\x{03A1}\x{03A4}\x{03A5}\x{03A7}\x{03B1}\x{03B2}\x{03B5}\x{03B9}\x{03BA}\x{03BC}\x{03BD}\x{03BF}\x{03C1}\x{03C4}\x{03C5}\x{03C7}'
H_FW='\x{FF21}-\x{FF3A}\x{FF41}-\x{FF5A}'
C_HOMO="$H_CY$H_GR$H_FW"
C_ALL="$C_ZW$C_BIDI$C_SOFT$C_TYPO$C_HOMO"

# --- Patterns: name|description|severity|profile|regex -----------------------
# NOTE: regex is the LAST field so it may contain '|' characters freely.
PATTERNS=(
    # ---- formatting / whitespace ----
    "Tabs|Tab character (use spaces)|WARNING|format|\t"
    "Leading tabs|Leading tabs (use spaces instead)|WARNING|format|^\t+"
    "Trailing spaces|Trailing whitespace|WARNING|format|[ \t]+$"
    "Multiple empty lines|3+ consecutive empty lines|WARNING|format|\n\s*\n\s*\n"
    "Line length|Lines longer than 80 characters|WARNING|format|^.{81,}$"
    "Non-ASCII|Non-ASCII character (excluding AI-artefact classes)|WARNING|format|(?![$C_ALL])[^\x00-\x7F]"
    "Windows line breaks|Windows (CRLF) line endings|ERROR|format|\r$"
    "BOM character|Byte Order Mark (BOM) at file start|ERROR|format|^\xEF\xBB\xBF"

    # ---- code smells: comments / leftovers / security ----
    "TODO comments|TODO comment (needs attention)|INFO|code|(?i)\bTODO\b"
    "FIXME comments|FIXME comment (needs fix)|WARNING|code|(?i)\bFIXME\b"
    "HACK comments|HACK comment (technical debt)|WARNING|code|(?i)\bHACK\b"
    "NOTE comments|NOTE comment (documentation)|INFO|code|(?i)\bNOTE\b"
    "XXX comments|XXX comment (critical)|ERROR|code|(?i)\bXXX\b"
    "BUG comments|BUG comment (known issue)|ERROR|code|(?i)\bBUG\b"
    "Placeholder comment|Placeholder comment|WARNING|code|(?i)\bPLACEHOLDER\b"
    "Placeholder git clone|git clone with placeholder repo URL (AI-generated docs)|WARNING|code|(?i)(git\s+clone\s+(<[^>\n]+>|\[[^\]\n]+\]|(your|this)[-_ ]?(repo|repository|project|url|link))|https?://(www\.)?(github|gitlab|bitbucket)\.com/(<[^>\n]+>|\[[^\]\n]+\]|(your|my|this)[-_ ]?(username|user|name|repo|repository)))"
    "Debug Print|Debug print statement|WARNING|code|console\.log"
    "Breakpoint|Debugger breakpoint|ERROR|code|debugger"
    "Commented Code|Commented out code|WARNING|code|^[[:space:]]*//"
    "API Key|Hardcoded API key|ERROR|code|(?i)(api[_-]?key|key[_-]?api|apikey|keyapi)[[:space:]]*="
    "Secret Key|Hardcoded secret key|ERROR|code|(?i)(secret[_-]?key|key[_-]?secret|secretkey|keysecret)[[:space:]]*="
    "Password|Hardcoded password|ERROR|code|(?i)(password|passwrd|pwrd|pwd)[[:space:]]*="
    "Bearer Token|Hardcoded bearer token|ERROR|code|(?i)bearer [0-9a-zA-Z_\-\.]+"
    "AWS Key|AWS Access Key|ERROR|code|(?i)aws[_-]?(key|secret|access)"
    "Private Key|Private key embedded|CRITICAL|code|-----BEGIN (RSA|DSA|EC|OPENSSH) PRIVATE KEY-----"

    # ---- hardcoded paths / URLs / IPs ----
    "Absolute Unix Path|Hardcoded absolute Unix path|WARNING|path|(?<![#/!:a-zA-Z0-9_-])/[a-zA-Z][a-zA-Z0-9/_.-]*"
    "Home Dir Path|Hardcoded home directory path|WARNING|path|~/[a-zA-Z0-9/_.-]+"
    "Env Variable Path|Hardcoded environment variable path|INFO|path|\$[A-Z_]+/"
    "Hardcoded URL|Hardcoded URL|INFO|path|https?://"
    "Localhost URL|Hardcoded localhost URL|WARNING|path|localhost"
    "IP Address|Hardcoded IP address|WARNING|path|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"

    # ---- AI artefacts ----
    "Zero-width characters|Invisible Unicode / zero-width character|WARNING|ai|[$C_ZW]"
    "Homoglyphs|Confusable homoglyph (Cyrillic/Greek/fullwidth)|WARNING|ai|[$C_HOMO]"
    "Bidi control characters|Bidirectional control character (Trojan Source)|ERROR|ai|[$C_BIDI]"
    "Soft hyphens / NBSP|Soft hyphen or non-breaking space|WARNING|ai|[$C_SOFT]"
    "Smart quotes / dashes|Smart quotes or typographic dashes|INFO|ai|[$C_TYPO]"
    "AI attribution|AI-generated attribution or disclaimer|INFO|ai|(?i)((this|the) (code|file|content|script|text) (was|is|has been) (generated|written|created|produced|authored|made) (by|with|using|via)|(generated|written|created|produced|authored|made) (with|using) (chatgpt|claude|gemini|copilot|openai|anthropic|deepseek|an ai|ai|the (assistance|help) of (an )?ai)|(assistance|help) of (an )?(ai|chatgpt|claude|gemini|copilot|openai|anthropic)|(disclaimer|notice|attribution).{0,40}(ai|artificial intelligence))"
    "AI placeholder markers|AI-generated placeholder text|INFO|ai|(?i)(as an ai|generated by (chatgpt|claude|gemini|copilot|bard|openai|an ai)|i suggest the following|ai[- ]?response|ai[- ]?generated|ai[- ]?assistant|this is a placeholder for ai|here'?s? (a|my|the) (suggested|proposed|complete|revised|improved|final|updated) (implementation|version|code|solution)|certainly!? here'?s?|sure!? here'?s?|i'?d be happy to (help|assist)|i hope this helps|let me know if (you|i) (need|have|can)|feel free to (ask|reach out|contact)|please note that|it'?s important to note|as of my (knowledge cutoff|last (update|knowledge))|i (do not|don'?t) (have|currently have) (access to|real[- ]?time)|i cannot (access|browse|view|provide))"

    # ---- copyright / licensing ----
    "Placeholder copyright|Copyright header with placeholder text (e.g. Your Name)|WARNING|license|(?i)(copyright|©).{0,45}(your (name|company|organization|copyright|logo|header)|placeholder|<author>|<name>|<year>|\[(year|name|author|company)\]|insert (your|the) (name|copyright)|add (your|the) (name|copyright))"
    "Copyright year|Copyright year is in the future (possible AI error)|WARNING|license|(special check)"
)

# Display order within each severity (exact pattern names, '|'-separated so
# names containing spaces are preserved)
issue_order["CRITICAL"]="Private Key"
issue_order["ERROR"]="Password|API Key|Secret Key|Bearer Token|AWS Key"
issue_order["ERROR"]+="|Windows line breaks|BOM character|XXX comments"
issue_order["ERROR"]+="|BUG comments|Breakpoint|Missing Copyright"
issue_order["ERROR"]+="|Bidi control characters"
issue_order["WARNING"]="Tabs|Leading tabs|Trailing spaces|Multiple empty lines"
issue_order["WARNING"]+="|Line length|Non-ASCII|FIXME comments|HACK comments"
issue_order["WARNING"]+="|Placeholder comment|Absolute Unix Path|Home Dir Path"
issue_order["WARNING"]+="|Debug Print|Commented Code|Localhost URL"
issue_order["WARNING"]+="|IP Address|Zero-width characters|Homoglyphs"
issue_order["WARNING"]+="|Soft hyphens / NBSP|Placeholder copyright|Copyright year"
issue_order["WARNING"]+="|Placeholder git clone"
issue_order["INFO"]="TODO comments|NOTE comments|Hardcoded URL"
issue_order["INFO"]+="|Env Variable Path|Smart quotes / dashes"
issue_order["INFO"]+="|AI placeholder markers|AI attribution"

# --- Profiles -----------------------------------------------------------------
declare -A PROFILE
PROFILE[ai]=0; PROFILE[code]=0; PROFILE[format]=0; PROFILE[path]=0
PROFILE[license]=0
PROFILE_FLAG_SET=false

# --- Helper functions ----------------------------------------------------------
print_color() {
    if [[ "$USE_COLORS" == true ]]; then
        printf "%b%s%b\n" "$1" "$2" "$NC"
    else
        printf "%s\n" "$2"
    fi
}

get_color_by_severity() {
    case "$1" in
        "CRITICAL"|"ERROR") echo "$RED" ;;
        "WARNING")          echo "$YELLOW" ;;
        "INFO")             echo "$CYAN" ;;
        *)                  echo "$NC" ;;
    esac
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [DIRECTORY] [FILE_PATTERN]

PROFILES (default: all):
    --ai               AI artefacts: zero-width/invisible Unicode, homoglyphs,
                       bidi control chars, soft hyphens/NBSP, smart quotes/dashes,
                       AI placeholder markers, AI attribution/disclaimers
    --code             Code smells: comments (TODO/FIXME/HACK/...), leftover
                       debug code, placeholder git clones, security (secrets,
                       keys, tokens, private keys)
    --format, --style  Formatting: tabs, leading tabs, trailing whitespace,
                       empty lines, line length, non-ASCII, CRLF, BOM
    --path             Hardcoded paths, URLs, IP addresses, env-var paths
    --license          Copyright/licensing hygiene: placeholder copyright
                       headers, future copyright years
    --all              All profiles (default when no profile flag is given)

OPTIONS:
    -c, --no-color     Disable colored output
    -h, --help         Show this help
    -l, --list-rules   List all detection rules
    --copyright NAME   Also flag files missing a copyright header for NAME
    --strict           Exit with error code 1 if any issue is found
    -v, --verbose      Show all matching lines (default: first 5)
    --no-exclude       Scan build/artifact/hidden folders too (node_modules,
                       .git, .FOLDER/, ...). Binary and image files are
                       ALWAYS skipped regardless.
EOF
    exit 0
}

list_rules() {
    echo ""
    print_color "$BLUE" "Detection rules (grouped by profile)"
    for p in ai code format path license; do
        echo ""
        print_color "$CYAN" "[$p]"
        for pattern in "${PATTERNS[@]}"; do
            IFS='|' read -r name desc severity profile regex <<< "$pattern"
            [[ "$profile" != "$p" ]] && continue
            printf "  %-28s %-9s %s\n" "$name" "[$severity]" "$desc"
        done
    done
    echo ""
    echo "Profiles:"
    echo "  --ai       AI artefacts: invisible chars, homoglyphs, bidi,"
    echo "             soft hyphens/NBSP, smart quotes/dashes, AI placeholders,"
    echo "             AI attribution/disclaimers"
    echo "  --code     Code smells: comments, leftover debug, security"
    echo "  --format   Formatting and whitespace"
    echo "  --path     Hardcoded paths, URLs, IPs"
    echo "  --license  Copyright/licensing hygiene"
    echo "  --all      All profiles (default)"
    exit 0
}

check_copyright() {
    local file="$1" holder="$2"
    if ! head -20 "$file" | grep -qi "copyright.*$holder\|©.*$holder"; then
        printf "        Missing copyright header for: %s\n" "$holder"
        return 1
    fi
    return 0
}

check_pattern() {
    local file="$1" name="$2" regex="$3"
    local results="" count=0 line_num line_content

    # Special case: BOM detection (byte-level)
    if [[ "$name" == "BOM character" ]]; then
        if head -c 3 "$file" | od -t x1 | head -1 | grep -q "ef bb bf"; then
            echo "        BOM character found at file start"
            echo "__HITS__:1"
            return 1
        fi
        return 0
    fi

    # Special case: line length (needs byte/char counting + overflow info)
    if [[ "$name" == "Line length" ]]; then
        local line_len found=0 shown=0
        while IFS= read -r line; do
            ((count++))
            line_len=${#line}
            if (( line_len > 80 )); then
                ((found++))
                if (( shown < MAX_LINES_PER_PATTERN )); then
                    ((shown++))
                    results+="        $count: ${line:0:70}... [+$((line_len - 80)) chars]\n"
                fi
            fi
        done < "$file"
        if (( found > 0 )); then
            echo -e "$results"
            echo "__HITS__:$found"
            return 1
        fi
        return 0
    fi

    # Special case: 3+ consecutive empty lines (multi-line match)
    if [[ "$name" == "Multiple empty lines" ]]; then
        results=$(awk '
            /^[ \t\r]*$/ { blank++; next }
            { if (blank >= 3) {
                  printf "        %d consecutive empty lines (lines %d-%d)\n", blank, NR-blank, NR-1
                  count++
              }
              blank=0 }
            END { if (blank >= 3) {
                      printf "        %d consecutive empty lines (lines %d-%d)\n", blank, NR-blank+1, NR
                      count++
                  } }
        ' "$file")
        if [[ -n "$results" ]]; then
            echo -e "$results"
            echo "__HITS__:$(printf '%s\n' "$results" | grep -c 'consecutive')"
            return 1
        fi
        return 0
    fi

    # Special case: copyright year in the future (possible AI error)
    if [[ "$name" == "Copyright year" ]]; then
        local cur_year=$(date +%Y)
        local total=0 shown=0 lineno content years y
        while IFS= read -r m; do
            lineno=$(printf '%s' "$m" | cut -d: -f1)
            content=$(printf '%s' "$m" | cut -d: -f2- | sed 's/\r$//')
            years=$(printf '%s' "$content" | grep -oE '(19|20)[0-9]{2}' | sort -u)
            for y in $years; do
                if (( y > cur_year )); then
                    ((total++))
                    if (( shown < MAX_LINES_PER_PATTERN )); then
                        ((shown++))
                        results+="        $lineno: $content (year $y)\n"
                    fi
                fi
            done
        done < <(grep -n -i -E 'copyright|©' "$file" 2>/dev/null)
        if (( total > 0 )); then
            echo -e "$results"
            echo "__HITS__:$total"
            return 1
        fi
        return 0
    fi

    # Generic grep-based check
    local matches=()
    mapfile -t matches < <(grep -P -n -i "$regex" "$file" 2>/dev/null | grep -v '^Binary file ')
    local total=${#matches[@]}
    if (( total > 0 )); then
        local shown=0 m
        for m in "${matches[@]}"; do
            (( shown >= MAX_LINES_PER_PATTERN )) && break
            ((shown++))
            line_num=$(printf '%s' "$m" | cut -d: -f1)
            line_content=$(printf '%s' "$m" | cut -d: -f2- | sed 's/^[[:space:]]*//; s/\r$//')
            results+="        $line_num: $line_content\n"
        done
        echo -e "$results"
        echo "__HITS__:$total"
        return 1
    fi
    return 0
}

print_issue() {
    local file="$1" issue_name="$2"
    local desc="" pname pdesc psev pprofile pregex
    local hits="${pattern_hits_total["$file:$issue_name"]}"
    for pattern in "${active_patterns[@]}"; do
        IFS='|' read -r pname pdesc psev pprofile pregex <<< "$pattern"
        if [[ "$pname" == "$issue_name" ]]; then
            desc="$pdesc"; psev="$psev"; break
        fi
    done
    if [[ "$issue_name" == "Missing Copyright" ]]; then
        desc="Missing copyright header"
        psev="ERROR"
        hits=0
    fi
    if (( hits > 0 )); then
        local plural="s"; (( hits == 1 )) && plural=""
        printf "    %b*%b %-24s %b%s%b (%d hit%s)\n" \
            "$YELLOW" "$NC" "$issue_name" "$CYAN" "$desc" "$NC" "$hits" "$plural"
    else
        printf "    %b*%b %-24s %b%s%b\n" \
            "$YELLOW" "$NC" "$issue_name" "$CYAN" "$desc" "$NC"
    fi
    local details="${issue_details["$file:$issue_name"]}"
    [[ -n "$details" ]] && echo -e "$details"
}

# --- Parse arguments ------------------------------------------------------------
SEARCH_DIR_SET=false
FILE_PATTERN_SET=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--no-color)    USE_COLORS=false; shift ;;
        -h|--help)        show_help ;;
        -l|--list-rules)  LIST_RULES=true; shift ;;
        --copyright)      CHECK_COPYRIGHT=true; COPYRIGHT_HOLDER="$2"; shift 2 ;;
        --strict)         STRICT_MODE=true; shift ;;
        -v|--verbose)     VERBOSE=true; MAX_LINES_PER_PATTERN=999999; shift ;;
        --ai)             PROFILE[ai]=1; PROFILE_FLAG_SET=true; shift ;;
        --code)           PROFILE[code]=1; PROFILE_FLAG_SET=true; shift ;;
        --format|--style) PROFILE[format]=1; PROFILE_FLAG_SET=true; shift ;;
        --path)           PROFILE[path]=1; PROFILE_FLAG_SET=true; shift ;;
        --license)        PROFILE[license]=1; PROFILE_FLAG_SET=true; shift ;;
        --no-exclude)     SKIP_EXCLUDED=false; shift ;;
        --all)            PROFILE[ai]=1; PROFILE[code]=1; PROFILE[format]=1; PROFILE[path]=1; PROFILE[license]=1; PROFILE_FLAG_SET=true; shift ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ "$SEARCH_DIR_SET" == false ]]; then
                SEARCH_DIR="$1"; SEARCH_DIR_SET=true
            elif [[ "$FILE_PATTERN_SET" == false ]]; then
                FILE_PATTERN="$1"; FILE_PATTERN_SET=true
            else
                echo "Unknown argument: $1"; exit 1
            fi
            shift
            ;;
    esac
done

[[ "$LIST_RULES" == true ]] && list_rules
if [[ "$CHECK_COPYRIGHT" == true && -z "$COPYRIGHT_HOLDER" ]]; then
    echo "ERROR: --copyright requires a name argument"
    exit 1
fi

# --- Build active pattern list from profile selection ---------------------------
active_patterns=()
for pattern in "${PATTERNS[@]}"; do
    IFS='|' read -r name desc severity profile regex <<< "$pattern"
    if [[ "$PROFILE_FLAG_SET" == false ]] || (( PROFILE["$profile"] == 1 )); then
        active_patterns+=("$pattern")
    fi
done

if [[ "$PROFILE_FLAG_SET" == false ]]; then
    PROFILE_LABEL="all (ai, code, format, path, license)"
else
    PROFILE_LABEL=""
    for p in ai code format path license; do
        if (( PROFILE[$p] == 1 )); then
            [[ -n "$PROFILE_LABEL" ]] && PROFILE_LABEL+=", "
            PROFILE_LABEL+="$p"
        fi
    done
    [[ -z "$PROFILE_LABEL" ]] && PROFILE_LABEL="none"
fi

# --- Header ---------------------------------------------------------------------
printf "%bNuni.sh - static dev-artefact scanner%b\n" "$BLUE" "$NC"
printf "  %-16s : %s\n" "Search directory" "$SEARCH_DIR"
printf "  %-16s : %s\n" "File filter" "$FILE_PATTERN"
printf "  %-16s : %s\n" "Profiles" "$PROFILE_LABEL"
printf "  %-16s : %d rules\n" "Active rules" "${#active_patterns[@]}"
if [[ "$SKIP_EXCLUDED" == true ]]; then
    printf "  %-16s : on (use --no-exclude to scan all)\n" "Excluded dirs"
else
    printf "  %-16s : off (scanning all folders)\n" "Excluded dirs"
fi
[[ "$CHECK_COPYRIGHT" == true ]] && \
    printf "  %-16s : Enabled (holder: %s)\n" "Copyright check" "$COPYRIGHT_HOLDER"
printf "%s\n" "=============================================================="

# --- Init counters ---------------------------------------------------------------
for pattern in "${active_patterns[@]}"; do
    IFS='|' read -r name desc severity profile regex <<< "$pattern"
    pattern_counts["$name"]=0
    pattern_hits_total["$name"]=0
done

declare -A file_issues   # file -> newline-separated list of issue names
declare -A issue_details # "file:issue" -> formatted output

# --- Scan files ------------------------------------------------------------------
# Build the find command. Binary/image/media formats are ALWAYS excluded by
# extension; build/artifact/VCS/hidden directories are pruned unless
# --no-exclude was given.
ext_expr=()
for e in $EXT_EXCLUDE; do
    ext_expr+=(-o -name "*.$e")
done

find_cmd=(find "$SEARCH_DIR")
if [[ "$SKIP_EXCLUDED" == true ]]; then
    prune_expr=()
    for d in $EXCLUDE_DIRS; do
        prune_expr+=(-o -name "$d")
    done
    prune_expr+=(-o -path "*/.*")
    find_cmd+=(\( -type d \( -name "__none__" "${prune_expr[@]}" \) -prune \) -o)
fi
find_cmd+=(-type f -not \( -name "__none__" "${ext_expr[@]}" \) \
           -name "$FILE_PATTERN" -print)

while IFS= read -r file; do
    # Backstop: skip anything not identified as text (binary, image, archive,
    # executable, database, ...). Images are caught here even without an
    # extension (file(1) reports "PNG image data", not "binary").
    filetype=$(file -b "$file")
    case "$filetype" in
        *"JSON"*|*"text"*|*"empty"*|*"XML"*|*"YAML"*|*"CSV"*) ;;
        *) continue ;;
    esac
    ((files_scanned++))

    file_has_issues=0

    if [[ "$CHECK_COPYRIGHT" == true ]]; then
        out=$(check_copyright "$file" "$COPYRIGHT_HOLDER")
        if [[ $? -eq 1 ]]; then
            file_has_issues=1
            issue_details["$file:Missing Copyright"]="$out"
            file_issues["$file"]="${file_issues["$file"]}Missing Copyright\n"
            ((pattern_counts["Missing Copyright"]++))
            ((total_issues_count++))
        fi
    fi

    for pattern in "${active_patterns[@]}"; do
        IFS='|' read -r name desc severity profile regex <<< "$pattern"
        out=$(check_pattern "$file" "$name" "$regex")
        if [[ $? -eq 1 ]]; then
            hits=0
            if [[ "$out" == *"__HITS__:"* ]]; then
                hits=$(printf '%s\n' "$out" | grep '^__HITS__:' | head -1 | cut -d: -f2)
                out=$(printf '%s\n' "$out" | grep -v '^__HITS__:')
            fi
            file_has_issues=1
            issue_details["$file:$name"]="$out"
            if [[ ! "${file_issues["$file"]}" =~ "$name\n" ]]; then
                file_issues["$file"]="${file_issues["$file"]}$name\n"
            fi
            ((pattern_counts["$name"]++))
            ((pattern_hits_total["$name"] += hits))
            ((total_issues_count++))
        fi
    done

    ((file_has_issues)) && ((files_with_issues++))
done < <("${find_cmd[@]}" 2>/dev/null)

# --- Display results ----------------------------------------------------------------
if (( files_with_issues == 0 )); then
    plural="s"; (( files_scanned == 1 )) && plural=""
    printf "\n%ball clean - no issues found in %d file%s%b\n" "$GREEN" "$files_scanned" "$plural" "$NC"
    exit 0
fi

severities=("CRITICAL" "ERROR" "WARNING" "INFO")

for severity in "${severities[@]}"; do
    ordered_list="${issue_order[$severity]}"
    ordered_issues=()
    [[ -n "$ordered_list" ]] && IFS='|' read -ra ordered_issues <<< "$ordered_list"

    # Collect (file, issue) pairs for this severity
    declare -A severity_pairs
    for file in "${!file_issues[@]}"; do
        while IFS= read -r issue; do
            [[ -z "$issue" ]] && continue
            if [[ "$issue" == "Missing Copyright" && "$severity" == "ERROR" ]]; then
                severity_pairs["$file:$issue"]=1
                continue
            fi
            for pattern in "${active_patterns[@]}"; do
                IFS='|' read -r pname pdesc psev pprofile pregex <<< "$pattern"
                if [[ "$pname" == "$issue" && "$psev" == "$severity" ]]; then
                    severity_pairs["$file:$issue"]=1
                fi
            done
        done < <(printf '%b' "${file_issues["$file"]}")
    done

    (( ${#severity_pairs[@]} )) || { unset severity_pairs; continue; }

    declare -A unique_files
    for key in "${!severity_pairs[@]}"; do
        unique_files["${key%:*}"]=1
    done

    echo ""
    color=$(get_color_by_severity "$severity")
    p_plural="s"; (( ${#severity_pairs[@]} == 1 )) && p_plural=""
    f_plural="s"; (( ${#unique_files[@]} == 1 )) && f_plural=""
    printf "%b[ %-8s ]%b  %d issue%s in %d file%s\n" \
        "$color" "$severity" "$NC" \
        "${#severity_pairs[@]}" "$p_plural" "${#unique_files[@]}" "$f_plural"
    printf "  %s\n" "----------------------------------------------"

    while IFS= read -r file; do
        n=0
        for key in "${!severity_pairs[@]}"; do [[ "$key" == "$file:"* ]] && ((n++)); done
        plural="s"; (( n == 1 )) && plural=""
        printf "  %b%s%b  (%d issue%s)\n" "$BLUE" "$file" "$NC" "$n" "$plural"

        shown_issues=()
        # Custom display order first
        for issue_name in "${ordered_issues[@]}"; do
            if [[ -n "${severity_pairs["$file:$issue_name"]}" ]]; then
                print_issue "$file" "$issue_name"
                shown_issues+=("$issue_name")
            fi
        done
        # Then any remaining issues of this severity
        for key in "${!severity_pairs[@]}"; do
            [[ "$key" == "$file:"* ]] || continue
            issue_name="${key#*:}"
            already=0
            for shown in "${shown_issues[@]}"; do
                [[ "$shown" == "$issue_name" ]] && { already=1; break; }
            done
            ((already)) && continue
            print_issue "$file" "$issue_name"
        done
        echo ""
    done < <(printf '%s\n' "${!unique_files[@]}" | sort)

    unset severity_pairs unique_files
done

# --- Summary -----------------------------------------------------------------------
echo "------------------------------------------------"
echo ""
printf "%bSummary%b\n" "$GREEN" "$NC"
printf "  %-20s : %d\n" "Files scanned" "$files_scanned"
printf "  %-20s : %d\n" "Files with issues" "$files_with_issues"
printf "  %-20s : %d\n" "Clean files" "$((files_scanned - files_with_issues))"
printf "  %-20s : %d\n" "Total issues" "$total_issues_count"
echo ""

printf "%bIssues by type:%b\n" "$YELLOW" "$NC"
declare -A severity_counts
for severity in "${severities[@]}"; do
    ordered_list="${issue_order[$severity]}"
    [[ -n "$ordered_list" ]] && IFS='|' read -ra ordered_issues <<< "$ordered_list"
    for issue_name in "${ordered_issues[@]}"; do
        count=${pattern_counts["$issue_name"]}
        if (( count > 0 )); then
            hits=${pattern_hits_total["$issue_name"]}
            printf "    %-26s %4d file(s) %7d hit(s)  [%s]\n" \
                "$issue_name" "$count" "$hits" "$severity"
            severity_counts["$severity"]=$((severity_counts["$severity"] + count))
        fi
    done
done
echo ""
printf "%bBy severity:%b\n" "$YELLOW" "$NC"
for severity in "${severities[@]}"; do
    count=${severity_counts["$severity"]}
    if (( count > 0 )); then
        plural="s"; (( count == 1 )) && plural=""
        color=$(get_color_by_severity "$severity")
        printf "    %b%-8s%b %d issue%s\n" "$color" "$severity" "$NC" "$count" "$plural"
    fi
done

if [[ "$STRICT_MODE" == true && $files_with_issues -gt 0 ]]; then
    printf "\n%bStrict mode: issues found, exiting with error code 1%b\n" "$RED" "$NC"
    exit 1
fi
