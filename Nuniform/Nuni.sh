#!/bin/bash

# Script to find various patterns in files (tabs, non-ASCII, trailing spaces, etc.)

# Detect if terminal supports colors
if [[ -t 1 ]] && [[ "$TERM" != "dumb" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# Default values
SEARCH_DIR="."
FILE_PATTERN="*"
USE_COLORS=true
CHECK_COPYRIGHT=false
COPYRIGHT_HOLDER=""
STRICT_MODE=false
VERBOSE=false
LIST_RULES=false

declare -A pattern_counts
files_with_issues=0
total_issues_count=0

# Define custom order for issues within each severity (exact names)
declare -A issue_order
issue_order["CRITICAL"]="Private Key"
issue_order["ERROR"]="Password API Key Secret Key Bearer Token AWS Key Windows line breaks BOM character XXX comments BUG comments Breakpoint Missing Copyright"
issue_order["WARNING"]="Tabs Leading tabs Trailing spaces Multiple empty lines Line length Non-ASCII FIXME comments HACK comments Placeholder comment Absolute Unix Path Home Dir Path Debug Print Magic Number Commented Code Localhost URL IP Address"
issue_order["INFO"]="TODO comments NOTE comments Hardcoded URL Env Variable Path"

# PATTERNS array: name|regex|description|severity
PATTERNS=(
    "Tabs|\\t|Tab character (use spaces)|WARNING"
    "Leading tabs|^\\t+|Leading tabs (use spaces instead)|WARNING"
    "Trailing spaces|[ \t]+$|Trailing whitespace|WARNING"
    "Multiple empty lines|\\n\\s*\\n\\s*\\n|Multiple consecutive empty lines (3+)|WARNING"
    "Line length|^.{81,}$|Lines longer than 80 characters|WARNING"
    "Non-ASCII|[^\\x00-\\x7F]|Non-ASCII character|WARNING"
    "Windows line breaks|\\r$|Windows (CRLF) line endings|ERROR"
    "BOM character|^\\xEF\\xBB\\xBF|Byte Order Mark (BOM) at file start|ERROR"
    "TODO comments|(?i)TODO|TODO comment (needs attention)|INFO"
    "FIXME comments|(?i)FIXME|FIXME comment (needs fix)|WARNING"
    "HACK comments|(?i)HACK|HACK comment (technical debt)|WARNING"
    "NOTE comments|(?i)NOTE|NOTE comment (documentation)|INFO"
    "XXX comments|(?i)XXX|XXX comment (critical)|ERROR"
    "BUG comments|(?i)BUG|BUG comment (known issue)|ERROR"
    "Placeholder comment|(?i)PLACEHOLDER|Placeholder comment|WARNING"
    "API Key|(?i)(api[_-]?key|key[_-]?api|apikey|keyapi)[[:space:]]*=|Hardcoded API key|ERROR"
    "Secret Key|(?i)(secret[_-]?key|key[_-]?secret|secretkey|keysecret)[[:space:]]*=|Hardcoded secret key|ERROR"
    "Password|(?i)(password|passwrd|pwrd|pwd)[[:space:]]*=|Hardcoded password|ERROR"
    "Bearer Token|(?i)bearer [0-9a-zA-Z_\\-\\.]+|Hardcoded bearer token|ERROR"
    "AWS Key|(?i)aws[_-]?(key|secret|access)|AWS Access Key|ERROR"
    "Private Key|-----BEGIN (RSA|DSA|EC|OPENSSH) PRIVATE KEY-----|Private key embedded|CRITICAL"
    "Absolute Unix Path|/[a-zA-Z0-9/_.-]+|Hardcoded absolute Unix path|WARNING"
    "Home Dir Path|~/[a-zA-Z0-9/_.-]+|Hardcoded home directory path|WARNING"
    "Env Variable Path|\\$[A-Z_]+/|Hardcoded environment variable path|INFO"
    "Debug Print|console\\.log|Debug print statement|WARNING"
    "Breakpoint|debugger|Debugger breakpoint|ERROR"
    "Magic Number|[^a-zA-Z0-9_][0-9]{4,}|Magic number|WARNING"
    "Commented Code|^[[:space:]]*//|Commented out code|WARNING"
    "Hardcoded URL|https?://|Hardcoded URL|INFO"
    "Localhost URL|localhost|Hardcoded localhost URL|WARNING"
    "IP Address|[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|Hardcoded IP address|WARNING"
)

MAX_LINES_PER_PATTERN=5
[[ "$VERBOSE" == true ]] && MAX_LINES_PER_PATTERN=999999

# Helper functions
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

OPTIONS:
    -c, --no-color          Disable colored output
    -h, --help              Show this help
    -l, --list-rules        List all patterns
    --copyright NAME        Check for missing copyright header for NAME
    --strict                Exit with error code if issues found
    -v, --verbose           Show all matching lines
EOF
    exit 0
}

list_rules() {
    print_color "$BLUE" "=== Pattern Checking Rules ==="
    echo ""
    for pattern in "${PATTERNS[@]}"; do
        IFS='|' read -r name regex desc severity <<< "$pattern"
        print_color "$CYAN" "[$severity]"
        printf "  • %b%s%b: %s\n" "$YELLOW" "$name" "$NC" "$desc"
        echo ""
    done
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
    
    if [[ "$name" == "BOM character" ]]; then
        if head -c 3 "$file" | od -t x1 | head -1 | grep -q "ef bb bf"; then
            echo "        BOM character found at file start"
            return 1
        fi
        return 0
    fi
    
    if [[ "$name" == "Line length" ]]; then
        local line_len found=0
        while IFS= read -r line; do
            ((count++))
            line_len=${#line}
            if [[ $line_len -gt 80 ]]; then
                ((found++))
                [[ $found -le $MAX_LINES_PER_PATTERN ]] || continue
                first_80="${line:0:70}"
                overflow=$((line_len - 80))
                results+="        $count: $first_80... [+${overflow} chars]\n"
            fi
        done < "$file"
        [[ -n "$results" ]] && { echo -e "$results"; return 1; }
        return 0
    fi
    
    if grep -q -P -i "$regex" "$file" 2>/dev/null; then
        while IFS= read -r line; do
            line_num=$(echo "$line" | cut -d: -f1)
            line_content=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//')
            results+="        $line_num: $line_content\n"
        done < <(grep -P -n -i "$regex" "$file" 2>/dev/null | head -n "$MAX_LINES_PER_PATTERN")
        echo -e "$results"
        return 1
    fi
    return 0
}

# Parse arguments
SEARCH_DIR_SET=false
FILE_PATTERN_SET=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--no-color)      USE_COLORS=false; shift ;;
        -h|--help)          show_help ;;
        -l|--list-rules)    LIST_RULES=true; shift ;;
        --copyright)        CHECK_COPYRIGHT=true; COPYRIGHT_HOLDER="$2"; shift 2 ;;
        --strict)           STRICT_MODE=true; shift ;;
        -v|--verbose)       VERBOSE=true; MAX_LINES_PER_PATTERN=999999; shift ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ "$SEARCH_DIR_SET" == false ]]; then
                SEARCH_DIR="$1"; SEARCH_DIR_SET=true
            elif [[ "$FILE_PATTERN_SET" == false ]]; then
                FILE_PATTERN="$1"; FILE_PATTERN_SET=true
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

# Main execution
printf "%bSearching for patterns in: %s%b\n" "$YELLOW" "$SEARCH_DIR" "$NC"
printf "%bFile pattern: %s%b\n" "$YELLOW" "$FILE_PATTERN" "$NC"
[[ "$CHECK_COPYRIGHT" == true ]] && printf "%bCopyright check: Enabled (Holder: %s)%b\n" "$YELLOW" "$COPYRIGHT_HOLDER" "$NC"
echo "================================================"

# Storage
for pattern in "${PATTERNS[@]}"; do
    IFS='|' read -r name _ _ _ <<< "$pattern"
    pattern_counts["$name"]=0
done

declare -A file_issues   # file -> newline-separated list of issue names
declare -A issue_details # "file:issue" -> formatted output

# Process files
while IFS= read -r file; do
    file "$file" | grep -q "binary" && ! file "$file" | grep -q "text" && continue
    
    file_has_issues=0
    
    # Copyright
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
    
    # Patterns
    for pattern in "${PATTERNS[@]}"; do
        IFS='|' read -r name regex desc severity <<< "$pattern"
        out=$(check_pattern "$file" "$name" "$regex")
        if [[ $? -eq 1 ]]; then
            file_has_issues=1
            issue_details["$file:$name"]="$out"
            if [[ ! "${file_issues["$file"]}" =~ "$name\n" ]]; then
                file_issues["$file"]="${file_issues["$file"]}$name\n"
            fi
            ((pattern_counts["$name"]++))
            ((total_issues_count++))
        fi
    done
    
    ((file_has_issues)) && ((files_with_issues++))
done < <(find "$SEARCH_DIR" -type f -name "$FILE_PATTERN" 2>/dev/null)

# Display results
if (( files_with_issues > 0 )); then
    severities=("CRITICAL" "ERROR" "WARNING" "INFO")
    
    for severity in "${severities[@]}"; do
        # Get ordered list for this severity
        ordered_list="${issue_order[$severity]}"
        ordered_issues=()
        [[ -n "$ordered_list" ]] && IFS=' ' read -ra ordered_issues <<< "$ordered_list"
        
        # Collect (file, issue) pairs for this severity
        declare -A severity_pairs
        for file in "${!file_issues[@]}"; do
            while IFS= read -r issue; do
                [[ -z "$issue" ]] && continue
                # Find severity of this issue
                for pattern in "${PATTERNS[@]}"; do
                    IFS='|' read -r pname _ _ psev <<< "$pattern"
                    if [[ "$pname" == "$issue" && "$psev" == "$severity" ]]; then
                        severity_pairs["$file:$issue"]=1
                    fi
                done
                if [[ "$issue" == "Missing Copyright" && "$severity" == "ERROR" ]]; then
                    severity_pairs["$file:$issue"]=1
                fi
            done < <(echo -e "${file_issues["$file"]}")
        done
        
        (( ${#severity_pairs[@]} )) || { unset severity_pairs; continue; }
        
        echo "------------------------------------------------"
        color=$(get_color_by_severity "$severity")
        printf "%b[%s]%b\n" "$color" "$severity" "$NC"
        
        # Get unique files for this severity
        declare -A unique_files
        for key in "${!severity_pairs[@]}"; do
            file="${key%:*}"
            unique_files["$file"]=1
        done
        
        # Sort files
        sorted_files=($(printf '%s\n' "${!unique_files[@]}" | sort))
        
        for file in "${sorted_files[@]}"; do
            printf "  %s\n" "$file"
            
            # Show issues in custom order, then any remaining
            shown_issues=()
            # First custom order
            for issue_name in "${ordered_issues[@]}"; do
                if [[ -n "${severity_pairs["$file:$issue_name"]}" ]]; then
                    printf "    - %s\n" "$issue_name"
                    details="${issue_details["$file:$issue_name"]}"
                    [[ -n "$details" ]] && echo -e "$details"
                    shown_issues+=("$issue_name")
                fi
            done
            # Then any other issues of this severity not in custom order
            for key in "${!severity_pairs[@]}"; do
                if [[ "$key" == "$file:"* ]]; then
                    issue_name="${key#*:}"
                    # Check if already shown
                    already=0
                    for shown in "${shown_issues[@]}"; do
                        [[ "$shown" == "$issue_name" ]] && { already=1; break; }
                    done
                    ((already)) && continue
                    printf "    - %s\n" "$issue_name"
                    details="${issue_details["$file:$issue_name"]}"
                    [[ -n "$details" ]] && echo -e "$details"
                fi
            done
            echo ""
        done
        unset severity_pairs unique_files
    done
fi

echo "------------------------------------------------"
echo ""
printf "%bSummary:%b\n" "$GREEN" "$NC"
printf "  %bFiles with issues:%b %d\n" "$YELLOW" "$NC" "$files_with_issues"
printf "  %bTotal issues found:%b %d\n" "$YELLOW" "$NC" "$total_issues_count"
echo ""

if (( files_with_issues > 0 )); then
    printf "  %bIssues by type:%b\n" "$YELLOW" "$NC"
    declare -A severity_counts
    for severity in "${severities[@]}"; do
        ordered_list="${issue_order[$severity]}"
        [[ -n "$ordered_list" ]] && IFS=' ' read -ra ordered_issues <<< "$ordered_list"
        for issue_name in "${ordered_issues[@]}"; do
            count=${pattern_counts["$issue_name"]}
            if (( count > 0 )); then
                printf "    %-30s: %3d file(s) [%s]\n" "$issue_name" "$count" "$severity"
                severity_counts["$severity"]=$((severity_counts["$severity"] + count))
            fi
        done
    done
    echo ""
    printf "  %bSummary by severity:%b\n" "$YELLOW" "$NC"
    for severity in "${severities[@]}"; do
        count=${severity_counts["$severity"]}
        if (( count > 0 )); then
            color=$(get_color_by_severity "$severity")
            printf "    %b%s%b: %d issue(s)\n" "$color" "$severity" "$NC" "$count"
        fi
    done
fi

if [[ "$STRICT_MODE" == true && $files_with_issues -gt 0 ]]; then
    printf "\n%bStrict mode: Issues found, exiting with error code 1%b\n" "$RED" "$NC"
    exit 1
fi
