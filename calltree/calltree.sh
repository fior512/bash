#!/usr/bin/env bash
# calltree.sh - ASCII/Mermaid/DOT call graph, multi-language static analysis.
# ~25 languages via universal-ctags, dispatched automatically by extension.
# Run -h for full usage/options; README.md has examples.
#
# Pipeline: ctags (JSON tags) -> perl backend (call graph) -> bash (render).
# Multi-file keys are "filepath::::funcname"; cross-file calls prefer the
# same-file definition, else the first file (input order) that defines it.
#
# Limitations: name-in-body scan, not semantic analysis (overloaded names
# collapse to first definition); method calls (obj.foo/ptr->foo) excluded;
# generics collapse to base name; macros not detected; file extension must
# match content; paths can't contain "::::" (internal key separator).
#
# Deps: bash >= 4.0, perl (JSON::PP, core since 5.14),
# universal-ctags with +json (not exuberant-ctags), graphviz (optional).
set -euo pipefail

readonly _VERSION="2.2.0"
readonly _SEP="::::"
readonly _AUTO="__AUTO__"

# =============================================================================
# Internal key helpers | keys are filepath::::funcname
# =============================================================================
_kfile() { printf '%s' "${1%%${_SEP}*}"; }
_kfunc() { printf '%s' "${1##*${_SEP}}"; }
_kbase() { local _f; _f=$(_kfile "$1"); printf '%s' "${_f##*/}"; }

_ts_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# Sanitize a string for use as a Mermaid node ID.
# Replaces any character that is not alphanumeric with an underscore.
# This handles C++ destructors (~Foo), operators, and other special names.
_mmd_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

_realpath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  elif readlink -f / >/dev/null 2>&1; then
    readlink -f "$1"
  else
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *)  printf '%s/%s\n' "$PWD" "$1" ;;
    esac
  fi
}

# =============================================================================
# Defaults
# =============================================================================
_MAX_DEPTH=4
_ROOT_FUNC=""
_USE_COLOR=0
_SEE_ALL=0
_SHOW_PERF=0
_NO_CLI=0
_OUT_MMD=""
_OUT_DOT=""
_OUT_TXT=""
_OUT_THEME=""    # "" | "light" | "dark"
declare -a _INPUT_FILES=() _SCAN_DIRS=() _INC_PATS=() _EXC_PATS=() _POSITIONAL=()

_usage() {
  cat <<EOF
calltree.sh v${_VERSION} - multi-language call tree (ctags + perl)

USAGE
  calltree.sh PATH [PATH ...] [OPTIONS]

  PATH may be a file or a directory. Multiple paths are accepted. Directories
  are scanned recursively for known source extensions.

OPTIONS
  -I PATTERN      include glob, basename match (repeatable, applied first)
  -E PATTERN      exclude glob, basename match (repeatable, applied last)

  -f FUNC         start tree from FUNC (bare name or 'file::::func' key)
  -d N            max recursion depth (default: 4)

  -out-T [FILE]   write plain text  (default: <base>.txt)
  -out-M [FILE]   write Mermaid     (default: <base>.mmd)
  -out-D [FILE]   write Graphviz    (default: <base>.dot)

  -bg-w       light/white theme for Mermaid and DOT output
  -bg-d       dark theme for Mermaid and DOT output

  -c              colorize terminal output (256-color ANSI)
  -s              expand repeated subtrees ([seen] compression off)
  -t              no terminal output; only -out-* files are written
  -p              show performance footer (timings + line counters)

  -v              print version and exit
  -w              print absolute path to this script and exit
  -h              print this help (with full language list) and exit
  --              end of options; everything after is treated as paths

SUPPORTED LANGUAGES
  Files are dispatched automatically by extension. The backend has an
  explicit kind allow-list for the languages below, plus a permissive
  fallback (function/method/func/fn/subroutine) for everything else.

  Language        Extensions                          Return types
  --------------  ----------------------------------  -------------
  C / C++         .c .h .cpp .hpp .cc .cxx .hxx       yes
  C#              .cs                                 yes
  Python          .py                                 - (no annot.)
  Go              .go                                 yes
  Rust            .rs                                 yes (from sig)
  Java            .java                               yes
  JavaScript      .js .jsx                            partial
  TypeScript      .ts .tsx                            yes
  Ruby            .rb                                 -
  Lua             .lua                                -
  PHP             .php                                yes
  Perl            .pl .pm                             -
  Kotlin          .kt                                 yes
  Scala           .scala                              yes
  Swift           .swift                              yes
  Haskell         .hs                                 best effort
  OCaml           .ml                                 best effort
  F#              .fs                                 best effort

DEPS
  bash >= 4
  perl (core JSON::PP since 5.14)
  universal-ctags with +json support
  graphviz (optional, only for rendering .dot to svg/png)

EXAMPLES
  calltree.sh src/main.cpp -c
  calltree.sh src/                                  # scan a directory
  calltree.sh src/ include/ -d 5 -p                 # multi-dir + depth + perf
  calltree.sh src/ -I '*.cpp' -E 'test_*' -out-D    # filtered DOT export
  calltree.sh src/ -f dispatch -out-M -out-D -c     # rooted Mermaid + DOT
  calltree.sh a.py b.py c.py -out-T graph.txt       # multi-file text export
  calltree.sh src/ -t -out-T -out-M -out-D          # silent run, files only
  calltree.sh src/ -out-M -bg-d                 # Mermaid with dark theme
  calltree.sh src/ -out-D -bg-w                 # DOT with light theme
  calltree.sh -- -weird-file.cpp                    # path starting with dash
EOF
}

# =============================================================================
# Argument parser
# =============================================================================
# A trailing optional FILE for -out-* is detected only if it ends with the
# matching extension (.txt / .mmd / .dot). This avoids grabbing the next
# positional path when the user wants the auto-derived filename.
_peek_ext() {  # _peek_ext <next_token> <expected_ext>
  [[ ${1+x} == x ]] || return 1
  [[ -n "${1-}" ]]   || return 1
  [[ "${1-}" != -* ]] || return 1
  case "$1" in
    *."$2") return 0 ;;
    *)      return 1 ;;
  esac
}

_need_arg() {  # _need_arg <flag> <count_remaining>
  [[ $2 -ge 2 ]] || { printf 'ERROR: %s needs a value\n' "$1" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -I)  _need_arg "$1" "$#"; _INC_PATS+=("$2"); shift 2 ;;
    -E)  _need_arg "$1" "$#"; _EXC_PATS+=("$2"); shift 2 ;;
    -f)  _need_arg "$1" "$#"; _ROOT_FUNC="$2";   shift 2 ;;
    -d)  _need_arg "$1" "$#"; _MAX_DEPTH="$2";   shift 2 ;;

    -out-T) shift; if _peek_ext "${1-}" txt; then _OUT_TXT=$1; shift; else _OUT_TXT=$_AUTO; fi ;;
    -out-M) shift; if _peek_ext "${1-}" mmd; then _OUT_MMD=$1; shift; else _OUT_MMD=$_AUTO; fi ;;
    -out-D) shift; if _peek_ext "${1-}" dot; then _OUT_DOT=$1; shift; else _OUT_DOT=$_AUTO; fi ;;

    -bg-w) _OUT_THEME=light; shift ;;
    -bg-d) _OUT_THEME=dark;  shift ;;

    -c)  _USE_COLOR=1; shift ;;
    -s)  _SEE_ALL=1;   shift ;;
    -t)  _NO_CLI=1;    shift ;;
    -p)  _SHOW_PERF=1; shift ;;

    -v)  printf 'calltree.sh %s\n' "$_VERSION"; exit 0 ;;
    -w)  _realpath "$0"; exit 0 ;;
    -h)  _usage; exit 0 ;;

    --)  shift; while [[ $# -gt 0 ]]; do _POSITIONAL+=("$1"); shift; done ;;
    -*)  printf 'ERROR: unknown option: %s\n' "$1" >&2
         printf 'Try: %s -h\n' "$0" >&2
         exit 1 ;;
    *)   _POSITIONAL+=("$1"); shift ;;
  esac
done

# Classify positional args into files and directories
for _ARG in "${_POSITIONAL[@]+"${_POSITIONAL[@]}"}"; do
  if   [[ -d "$_ARG" ]]; then _SCAN_DIRS+=("$_ARG")
  elif [[ -f "$_ARG" ]]; then _INPUT_FILES+=("$_ARG")
  else
    printf 'ERROR: not a file or directory: %s\n' "$_ARG" >&2
    exit 1
  fi
done

# =============================================================================
# Dependency check
# =============================================================================
_check_ctags() {
  if ! command -v ctags >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: ctags not found. Install universal-ctags:
  Debian/Ubuntu : sudo apt install universal-ctags
  Fedora        : sudo dnf install ctags
  Arch          : sudo pacman -S ctags
  macOS         : brew install universal-ctags
  FreeBSD       : pkg install universal-ctags
EOF
    exit 1
  fi
  if ! ctags --version 2>&1 | head -1 | grep -qi 'universal'; then
    printf 'ERROR: universal-ctags required (found: %s)\n' \
      "$(ctags --version 2>&1 | head -1)" >&2
    exit 1
  fi
  if ! ctags --list-features 2>/dev/null | awk '{print $1}' | grep -qx 'json'; then
    printf 'ERROR: ctags built without JSON support (need +json feature).\n' >&2
    exit 1
  fi
}
_check_ctags

# =============================================================================
# Collect files from directory scans (apply -I/-E filters)
# =============================================================================
for _DIR in "${_SCAN_DIRS[@]+"${_SCAN_DIRS[@]}"}"; do
  while IFS= read -r -d '' _F; do
    _BN="${_F##*/}"
    _OK=1
    if [[ ${#_INC_PATS[@]} -gt 0 ]]; then
      _OK=0
      for _P in "${_INC_PATS[@]}"; do
        # shellcheck disable=SC2254
        case "$_BN" in $_P) _OK=1; break ;; esac
      done
    fi
    [[ $_OK -eq 0 ]] && continue
    for _P in "${_EXC_PATS[@]+"${_EXC_PATS[@]}"}"; do
      # shellcheck disable=SC2254
      case "$_BN" in $_P) _OK=0; break ;; esac
    done
    [[ $_OK -eq 0 ]] && continue
    _INPUT_FILES+=("$_F")
  done < <(find "$_DIR" -type f \( \
        -name '*.c'     -o -name '*.h'     -o -name '*.cpp'  -o -name '*.hpp' \
     -o -name '*.cc'    -o -name '*.cxx'   -o -name '*.hxx'  -o -name '*.cs'  \
     -o -name '*.py'    -o -name '*.rs'    -o -name '*.go'   -o -name '*.java' \
     -o -name '*.js'    -o -name '*.jsx'   -o -name '*.ts'   -o -name '*.tsx' \
     -o -name '*.rb'    -o -name '*.lua'   -o -name '*.php'  -o -name '*.pl'  \
     -o -name '*.pm'    -o -name '*.scala' -o -name '*.kt'   -o -name '*.swift' \
     -o -name '*.hs'    -o -name '*.ml'    -o -name '*.fs'                    \
    \) -print0 | sort -z)
done

if [[ ${#_INPUT_FILES[@]} -eq 0 ]]; then
  _usage
  exit 1
fi
for _F in "${_INPUT_FILES[@]}"; do
  [[ -f "$_F" ]] || { printf 'ERROR: file not found: %s\n' "$_F" >&2; exit 1; }
done

# =============================================================================
# Mode + title + default output base
# =============================================================================
if [[ ${#_INPUT_FILES[@]} -eq 1 ]]; then
  _MULTI=0
  _TITLE="${_INPUT_FILES[0]}"
  _BASE="${_INPUT_FILES[0]%.*}"
else
  _MULTI=1
  if [[ ${#_SCAN_DIRS[@]} -gt 0 ]]; then
    _TITLE="${_SCAN_DIRS[0]}  (${#_INPUT_FILES[@]} files)"
    _BASE="${_SCAN_DIRS[0]%/}/calltree"
  else
    _TITLE="${#_INPUT_FILES[@]} files"
    _BASE="calltree"
  fi
fi
[[ "$_OUT_TXT" == "$_AUTO" ]] && _OUT_TXT="${_BASE}.txt"
[[ "$_OUT_MMD" == "$_AUTO" ]] && _OUT_MMD="${_BASE}.mmd"
[[ "$_OUT_DOT" == "$_AUTO" ]] && _OUT_DOT="${_BASE}.dot"

# =============================================================================
# Run ctags + perl backend
# =============================================================================
_T_START=$(_ts_ms)
_TAGS_TMP=$(mktemp)
trap 'rm -f "$_TAGS_TMP"' EXIT

# --fields=+neKlSt  -> add: line(n) end(e) Kind-long(K) language(l) signature(S) typeref(t)
# --sort=no         -> preserve source order so per-file line sort works
if ! ctags --output-format=json \
           --sort=no \
           --fields=+neKlSt \
           -f - "${_INPUT_FILES[@]}" > "$_TAGS_TMP" 2>/dev/null; then
  printf 'ERROR: ctags failed.\n' >&2
  exit 1
fi

_PERL_OUT=$(perl - "$_TAGS_TMP" <<'PERL'
use strict;
use warnings;
use JSON::PP;

my $SEP = "::::";
my $tags_file = shift @ARGV;

open my $tfh, '<', $tags_file or die "cannot open $tags_file: $!\n";
my $json = JSON::PP->new->utf8(0);

# Per-language kind allow-list. ctags uses different kind names per language;
# this table picks the ones that represent actual callable function defs.
my %ok_kinds_per_lang = (
    'C'          => { function => 1 },
    'C++'        => { function => 1 },
    'C#'         => { method => 1 },
    'Python'     => { function => 1, member => 1 },     # member = class method
    'Go'         => { func => 1 },
    'Rust'       => { function => 1, method => 1 },
    'Java'       => { method => 1 },
    'JavaScript' => { function => 1, method => 1, getter => 1, setter => 1, generator => 1 },
    'TypeScript' => { function => 1, method => 1, getter => 1, setter => 1, generator => 1 },
    'Ruby'       => { method => 1, singletonMethod => 1 },
    'Lua'        => { function => 1 },
    'PHP'        => { function => 1 },
    'Perl'       => { subroutine => 1 },
    'Kotlin'     => { method => 1 },
    'Scala'      => { method => 1, function => 1 },
    'Swift'      => { method => 1, function => 1 },
    'Haskell'    => { function => 1 },
    'OCaml'      => { val => 1, function => 1 },
);
# fallback for any language not listed above
my %default_ok = (
    function => 1, method => 1, func => 1, fn => 1, subroutine => 1,
);

# ---- Pass A: read all tags from JSON ---------------------------------------
my @raw_tags;
while (my $line = <$tfh>) {
    chomp $line;
    next unless $line =~ /^\{/;
    my $obj = eval { $json->decode($line) };
    next unless $obj && (($obj->{_type} // '') eq 'tag');
    push @raw_tags, $obj;
}
close $tfh;

# ---- Pass B: filter, group by file, dedupe ---------------------------------
my (%file_defs, %func_to_files, %rtype, %lang_of, %seen_def);

for my $t (@raw_tags) {
    my $name = $t->{name};
    my $file = $t->{path};
    my $kind = $t->{kind} // '';
    my $lang = $t->{language} // '';
    next unless defined $name && defined $file && $name ne '' && $file ne '';

    # ctags fabricates names like __anon0566b84d0102 for unnamed entities
    # (lambdas, anonymous structs/unions). Drop them.
    next if $name =~ /^__anon\w*$/;

    my $allow = $ok_kinds_per_lang{$lang} // \%default_ok;
    next unless $allow->{$kind};

    my $key = "${file}${SEP}${name}";
    next if $seen_def{$key}++;   # first definition wins

    my $start = $t->{line} // 0;
    my $end   = $t->{end}  // 0;

    # typeref looks like "typename:int"; strip the prefix
    my $tref = $t->{typeref} // '';
    $tref =~ s/^typename:\s*//;
    $tref =~ s/^\s+|\s+$//g;
    # Languages like Rust embed the return type inside the signature as
    # "(args) -> Type". Pull it out when typeref is missing.
    if ($tref eq '') {
        my $sig = $t->{signature} // '';
        if ($sig =~ /->\s*(.+?)\s*$/) {
            $tref = $1;
        }
    }
    if ($tref eq '') {
        $tref = ($lang eq 'C' || $lang eq 'C++') ? 'void' : '-';
    }

    push @{$file_defs{$file}}, {
        name => $name,
        line => $start,
        end  => $end,
        key  => $key,
    };
    push @{$func_to_files{$name}}, $file
        unless grep { $_ eq $file } @{$func_to_files{$name} // []};

    $rtype{$key}    = $tref;
    $lang_of{$file} = $lang;
}

my %all_known = map { $_ => 1 } keys %func_to_files;

# ---- Pass C: read sources, fix end lines, scan bodies ----------------------
my (%calls, %freq, %linerange);
my $total_lines = 0;

for my $file (sort keys %file_defs) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;
    my $nlines = scalar @lines;
    $total_lines += $nlines;

    # sort defs by line so we can patch missing end values
    my @sorted = sort { $a->{line} <=> $b->{line} } @{$file_defs{$file}};
    for my $i (0 .. $#sorted) {
        my $d = $sorted[$i];
        if (!$d->{end} || $d->{end} < $d->{line}) {
            if ($i < $#sorted) {
                $d->{end} = $sorted[$i+1]->{line} - 1;
            } else {
                $d->{end} = $nlines;
            }
        }
        $d->{end} = $nlines    if $d->{end} > $nlines;
        $d->{end} = $d->{line} if $d->{end} < $d->{line};
    }

    my $lang = $lang_of{$file} // '';

    for my $d (@sorted) {
        my ($s, $e) = ($d->{line}, $d->{end});
        next if $s <= 0 || $s > $nlines;

        $linerange{$d->{key}} = "${s}-${e}";

        my $body = join('', @lines[$s-1 .. $e-1]);

        # strip comments and strings - best effort, not language-perfect
        $body =~ s{//[^\n]*}{}g;
        $body =~ s{/\*.*?\*/}{}gs;
        if ($lang eq 'Python' || $lang eq 'Ruby' || $lang eq 'Perl' || $lang eq 'Sh') {
            $body =~ s{\#[^\n]*}{}g;
        }
        $body =~ s{"(?:[^"\\]|\\.)*"}{""}gs;
        $body =~ s{'(?:[^'\\]|\\.)*'}{''}gs;

        my $caller_key  = $d->{key};
        my $caller_name = $d->{name};

        # Skip identifiers preceded by '.' or '>' (i.e. obj.foo() / ptr->foo()).
        # This works uniformly for C/C++/Rust/Go/Java/Py/JS - '::' qualified
        # calls (e.g. Foo::bar()) are still counted.
        while ($body =~ /(?<![>.])\b([A-Za-z_]\w*)\s*\(/g) {
            my $callee = $1;
            next unless $all_known{$callee};
            next if $callee eq $caller_name;

            # resolve: prefer same-file def, else first file that defines it
            my $cf_ref = $func_to_files{$callee} // [];
            my $callee_file = (grep { $_ eq $file } @$cf_ref)
                                ? $file
                                : $cf_ref->[0];
            next unless defined $callee_file;

            my $callee_key = "${callee_file}${SEP}${callee}";
            push @{$calls{$caller_key}}, $callee_key;
            $freq{$callee_key} = ($freq{$callee_key} // 0) + 1;
        }
    }
}

# ---- Emit -----------------------------------------------------------------
print "CALLS\n";
for my $file (sort keys %file_defs) {
    my @sorted = sort { $a->{line} <=> $b->{line} } @{$file_defs{$file}};
    for my $d (@sorted) {
        printf "%s\t%s\n", $d->{key}, join(' ', @{$calls{$d->{key}} // []});
    }
}
print "---\n";

print "TYPES\n";
for my $file (sort keys %file_defs) {
    my @sorted = sort { $a->{line} <=> $b->{line} } @{$file_defs{$file}};
    for my $d (@sorted) {
        printf "%s\t%s\n", $d->{key}, $rtype{$d->{key}} // '-';
    }
}
print "---\n";

print "FREQ\n";
for my $file (sort keys %file_defs) {
    my @sorted = sort { $a->{line} <=> $b->{line} } @{$file_defs{$file}};
    for my $d (@sorted) {
        printf "%s\t%d\n", $d->{key}, $freq{$d->{key}} // 0;
    }
}
print "---\n";

print "LINES\n";
for my $file (sort keys %file_defs) {
    my @sorted = sort { $a->{line} <=> $b->{line} } @{$file_defs{$file}};
    for my $d (@sorted) {
        printf "%s\t%s\n", $d->{key}, $linerange{$d->{key}} // '0-0';
    }
}
print "---\n";

print "LINESREAD\n";
print "$total_lines\n";
print "---\n";
PERL
)

[[ -z "$_PERL_OUT" ]] && { printf 'No functions found in specified files.\n' >&2; exit 1; }

# =============================================================================
# Load perl output into bash assoc arrays
# =============================================================================
declare -A CALLS=() RTYPE=() FREQ=() LINE_RANGE=()
declare -a ALL_FUNCS=()
_SEC=""
_LINES_READ=0

while IFS= read -r _line; do
  case "$_line" in
    CALLS|TYPES|FREQ|LINES|LINESREAD) _SEC="$_line"; continue ;;
    ---) _SEC=""; continue ;;
    "") continue ;;
  esac
  case "$_SEC" in
    CALLS)
      IFS=$'\t' read -r _KEY _REST <<< "$_line"
      CALLS[$_KEY]="${_REST:-}"
      ALL_FUNCS+=("$_KEY")
      ;;
    TYPES)
      IFS=$'\t' read -r _KEY _V <<< "$_line"
      RTYPE[$_KEY]="${_V:--}"
      ;;
    FREQ)
      IFS=$'\t' read -r _KEY _V <<< "$_line"
      FREQ[$_KEY]="${_V:-0}"
      ;;
    LINES)
      IFS=$'\t' read -r _KEY _V <<< "$_line"
      LINE_RANGE[$_KEY]="${_V:-0-0}"
      ;;
    LINESREAD)
      _LINES_READ="$_line"
      ;;
  esac
done <<< "$_PERL_OUT"

[[ ${#ALL_FUNCS[@]} -eq 0 ]] && { printf 'No functions found.\n' >&2; exit 1; }
_T_BACKEND_END=$(_ts_ms)

# =============================================================================
# Reachable set (when -f is given)
# =============================================================================
declare -a VISIBLE_FUNCS=()
_ROOT_KEY=""

if [[ -n "$_ROOT_FUNC" ]]; then
  if [[ "$_ROOT_FUNC" == *"${_SEP}"* ]]; then
    _ROOT_KEY="$_ROOT_FUNC"
  else
    for _K in "${ALL_FUNCS[@]}"; do
      if [[ "$(_kfunc "$_K")" == "$_ROOT_FUNC" ]]; then
        _ROOT_KEY="$_K"; break
      fi
    done
  fi
  [[ -z "$_ROOT_KEY" ]] && { printf 'ERROR: function "%s" not found.\n' "$_ROOT_FUNC" >&2; exit 1; }

  declare -A _REACHED=()
  declare -a _QUEUE=("$_ROOT_KEY")
  _REACHED[$_ROOT_KEY]=1
  while [[ ${#_QUEUE[@]} -gt 0 ]]; do
    _H="${_QUEUE[0]}"; _QUEUE=("${_QUEUE[@]:1}")
    for _C in ${CALLS[$_H]:-}; do
      [[ -z "${_REACHED[$_C]:-}" ]] && { _REACHED[$_C]=1; _QUEUE+=("$_C"); }
    done
  done
  for _K in "${ALL_FUNCS[@]}"; do
    [[ -n "${_REACHED[$_K]:-}" ]] && VISIBLE_FUNCS+=("$_K")
  done
else
  VISIBLE_FUNCS=("${ALL_FUNCS[@]}")
fi

# =============================================================================
# 256-color map
# =============================================================================
declare -A FUNC_COLOR=()
if [[ $_USE_COLOR -eq 1 ]]; then
  declare -A _SNAME=()
  declare -a _UNAMES=()
  for _K in "${VISIBLE_FUNCS[@]}"; do
    _N=$(_kfunc "$_K")
    if [[ -z "${_SNAME[$_N]:-}" ]]; then _UNAMES+=("$_N"); _SNAME[$_N]=1; fi
  done
  mapfile -t _SORTED < <(printf '%s\n' "${_UNAMES[@]}" | sort)
  _NF=${#_SORTED[@]}
  for (( _ci=0; _ci<_NF; _ci++ )); do
    (( _NF == 1 )) && _C=125 || _C=$(( 40 + 170 * _ci / (_NF - 1) ))
    FUNC_COLOR["${_SORTED[$_ci]}"]=$_C
  done
fi

_GREY=244

_color() {  # funcname  use_color
  if [[ ${2:-0} -eq 1 && -n "${FUNC_COLOR[$1]:-}" ]]; then
    printf '\033[38;5;%dm%s\033[0m' "${FUNC_COLOR[$1]}" "$1"
  else
    printf '%s' "$1"
  fi
}
_grey() {
  if [[ ${2:-0} -eq 1 ]]; then
    printf '\033[38;5;%dm%s\033[0m' "$_GREY" "$1"
  else
    printf '%s' "$1"
  fi
}
_seen_marker() {
  if [[ ${2:-0} -eq 1 && -n "${FUNC_COLOR[$1]:-}" ]]; then
    printf '  [\033[38;5;%dmseen\033[0m]' "${FUNC_COLOR[$1]}"
  else
    printf '  [seen]'
  fi
}

_uniq_calls_raw() {
  local _raw="${CALLS[$1]:-}"
  [[ -z "$_raw" ]] && return
  local -A _sw=(); local _out="" _w
  for _w in $_raw; do
    [[ -n "${_sw[$_w]:-}" ]] && continue
    _sw[$_w]=1; [[ -n "$_out" ]] && _out+=" "; _out+="$_w"
  done
  printf '%s' "$_out"
}

_uniq_calls_names() {
  local _raw; _raw=$(_uniq_calls_raw "$1")
  [[ -z "$_raw" ]] && return
  local _out="" _ck
  for _ck in $_raw; do
    local _fn; _fn=$(_kfunc "$_ck")
    [[ -n "$_out" ]] && _out+=" "; _out+="$_fn"
  done
  printf '%s' "$_out"
}

# =============================================================================
# Root detection
# =============================================================================
declare -A _IS_CALLEE=()
for _K in "${ALL_FUNCS[@]}"; do
  for _CK in ${CALLS[$_K]:-}; do _IS_CALLEE[$_CK]=1; done
done

declare -a ROOTS=()
if [[ -n "$_ROOT_KEY" ]]; then
  ROOTS=("$_ROOT_KEY")
else
  for _K in "${ALL_FUNCS[@]}"; do
    [[ -z "${_IS_CALLEE[$_K]:-}" ]] && ROOTS+=("$_K")
  done
  [[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("${ALL_FUNCS[@]}")
fi

# =============================================================================
# Tree emitter
# =============================================================================
declare -A _SEEN_SUB=()

_emit() {
  local _key=$1 _pre=$2 _cont=$3 _depth=$4 _vis=$5 _col=${6:-0}
  local _fn _children _marker _ann _lr

  _fn=$(_kfunc "$_key")
  _children="${CALLS[$_key]:-}"
  _marker=""; _ann=""

  # Line range annotation (always shown when available)
  _lr="${LINE_RANGE[$_key]:-}"

  if [[ $_MULTI -eq 1 ]]; then
    local _bn; _bn=$(_kbase "$_key")
    _ann="  [${_bn}${_lr:+:L${_lr}}]"
  elif [[ -n "$_lr" ]]; then
    _ann="  [L${_lr}]"
  fi

  if [[ ":${_vis}:" == *":${_key}:"* ]]; then
    _marker="  [cycle]"
  elif [[ $_SEE_ALL -eq 0 && -n "$_children" && -n "${_SEEN_SUB[$_key]:-}" ]]; then
    _marker="$(_seen_marker "$_fn" "$_col")"
  fi

  printf '%s%s()%s  %s%s\n' \
    "$_pre" \
    "$(_color "$_fn" "$_col")" \
    "$(_grey "$_ann" "$_col")" \
    "$(_grey "-> ${RTYPE[$_key]:-?}" "$_col")" \
    "$_marker"

  [[ -n "$_marker" || "$_depth" -ge "$_MAX_DEPTH" ]] && return
  [[ -z "$_children" ]] && return

  _SEEN_SUB[$_key]=1
  local _vis2="${_vis}:${_key}"
  local -a _arr; read -ra _arr <<< "$_children"
  local _n=${#_arr[@]} _i
  for (( _i=0; _i<_n; _i++ )); do
    if (( _i == _n-1 )); then
      _emit "${_arr[$_i]}" "${_cont}└── " "${_cont}    " $(( _depth+1 )) "$_vis2" "$_col"
    else
      _emit "${_arr[$_i]}" "${_cont}├── " "${_cont}│   " $(( _depth+1 )) "$_vis2" "$_col"
    fi
  done
}

# =============================================================================
# Summary table
# =============================================================================
_print_table() {
  local _col=${1:-0}

  _calls_field() {
    local _raw; _raw=$(_uniq_calls_names "$1"); [[ -z "$_raw" ]] && _raw="----"
    if [[ $_col -eq 0 ]]; then printf '%s' "$_raw"; return; fi
    if [[ "$_raw" == "----" ]]; then _grey "----" 1; return; fi
    local _out="" _w
    for _w in $_raw; do _out+="${_out:+ }$(_color "$_w" 1)"; done
    printf '%s' "$_out"
  }

  printf '\n'
  if [[ $_MULTI -eq 1 ]]; then
    printf '  %-28s  %-22s  %6s  %-40s  %-22s  %s\n' \
      "function" "file" "called" "calls" "return type" "lines"
    printf '  %s  %s  %s  %s  %s  %s\n' \
      "────────────────────────────" "──────────────────────" \
      "──────" "────────────────────────────────────────" \
      "──────────────────────" "───────────"
  else
    printf '  %-28s  %6s  %-40s  %-22s  %s\n' \
      "function" "called" "calls" "return type" "lines"
    printf '  %s  %s  %s  %s  %s\n' \
      "────────────────────────────" "──────" \
      "────────────────────────────────────────" \
      "──────────────────────" "───────────"
  fi

  local _k _fn _bn _raw _pf _pd _pb _lr _lrdisp
  for _k in "${VISIBLE_FUNCS[@]}"; do
    _fn=$(_kfunc "$_k")
    _raw=$(_uniq_calls_names "$_k"); [[ -z "$_raw" ]] && _raw="----"
    _lr="${LINE_RANGE[$_k]:-}"; _lrdisp="${_lr:-—}"
    _pf=$(( 28 - ${#_fn} ));   (( _pf < 0 )) && _pf=0
    _pd=$(( 40 - ${#_raw} ));  (( _pd < 0 )) && _pd=0

    if [[ $_MULTI -eq 1 ]]; then
      _bn=$(_kbase "$_k")
      _pb=$(( 22 - ${#_bn} )); (( _pb < 0 )) && _pb=0
      printf '  %s%*s  %s%*s  %6s  %s%*s  %-22s  %s\n' \
        "$(_color "$_fn" "$_col")" "$_pf" "" \
        "$(_grey "$_bn"  "$_col")" "$_pb" "" \
        "${FREQ[$_k]:-0}" \
        "$(_calls_field "$_k")" "$_pd" "" \
        "${RTYPE[$_k]:-?}" \
        "$_lrdisp"
    else
      printf '  %s%*s  %6s  %s%*s  %-22s  %s\n' \
        "$(_color "$_fn" "$_col")" "$_pf" "" \
        "${FREQ[$_k]:-0}" \
        "$(_calls_field "$_k")" "$_pd" "" \
        "${RTYPE[$_k]:-?}" \
        "$_lrdisp"
    fi
  done
  printf '\n'
}

# =============================================================================
# ASCII renderer
# =============================================================================
_print_ascii() {
  local _col=${1:-0}
  _SEEN_SUB=()
  printf '\n  %s  (depth=%s)\n\n' "$_TITLE" "$_MAX_DEPTH"
  local _r
  for _r in "${ROOTS[@]}"; do
    _emit "$_r" "" "" 0 "" "$_col"
    printf '\n'
  done
  _print_table "$_col"
}

# =============================================================================
# Mermaid writer
# =============================================================================
_write_mermaid() {
  local _out_file=$1
  local _k _ck _f _bn _sid _fn _fid _kf _kb _ks _kn _kni _cf _cb _cs _cn _cni _eid
  declare -A _fmap=() _eseen=()

  {
    # Theme init directive must appear before the graph declaration
    case "$_OUT_THEME" in
      dark)  printf '%%%%{init: {"theme": "dark"}}%%%%\n' ;;
      light) printf '%%%%{init: {"theme": "default"}}%%%%\n' ;;
    esac

    printf 'flowchart TD\n'
    if [[ $_MULTI -eq 1 ]]; then
      for _k in "${ALL_FUNCS[@]}"; do
        _f=$(_kfile "$_k"); _fmap[$_f]+=" $_k"
      done
      for _f in $(printf '%s\n' "${!_fmap[@]}" | sort); do
        _bn="${_f##*/}"; _sid="${_bn//[^A-Za-z0-9_]/_}"
        printf '  subgraph %s["%s"]\n' "$_sid" "$_bn"
        for _k in ${_fmap[$_f]}; do
          _fn=$(_kfunc "$_k")
          _fid=$(_mmd_id "$_fn")
          printf '    %s_%s["%s %s()"]\n' "$_sid" "$_fid" "${RTYPE[$_k]:-void}" "$_fn"
        done
        printf '  end\n'
      done
    else
      for _k in "${ALL_FUNCS[@]}"; do
        _fn=$(_kfunc "$_k")
        _fid=$(_mmd_id "$_fn")
        printf '  %s["%s %s()"]\n' "$_fid" "${RTYPE[$_k]:-void}" "$_fn"
      done
    fi

    printf '\n'
    for _k in "${ALL_FUNCS[@]}"; do
      for _ck in ${CALLS[$_k]:-}; do
        _eid="${_k}->${_ck}"
        [[ -n "${_eseen[$_eid]:-}" ]] && continue
        _eseen[$_eid]=1
        if [[ $_MULTI -eq 1 ]]; then
          _kf=$(_kfile "$_k");  _kb="${_kf##*/}"; _ks="${_kb//[^A-Za-z0-9_]/_}"; _kni=$(_mmd_id "$(_kfunc "$_k")")
          _cf=$(_kfile "$_ck"); _cb="${_cf##*/}"; _cs="${_cb//[^A-Za-z0-9_]/_}"; _cni=$(_mmd_id "$(_kfunc "$_ck")")
          printf '  %s_%s --> %s_%s\n' "$_ks" "$_kni" "$_cs" "$_cni"
        else
          _kni=$(_mmd_id "$(_kfunc "$_k")")
          _cni=$(_mmd_id "$(_kfunc "$_ck")")
          printf '  %s --> %s\n' "$_kni" "$_cni"
        fi
      done
    done
  } > "$_out_file"
}

# =============================================================================
# DOT writer
# =============================================================================
_write_dot() {
  local _out_file=$1
  local _k _ck _f _bn _fn _ci _eid
  declare -A _fmap=() _eseen=()

  # Theme colors
  local _bg_color="#ffffff"
  local _node_fill="#f5f5f5"
  local _font_color="black"
  local _edge_color="#333333"
  local _cluster_fill="#eeeeee"
  local _cluster_font="black"

  case "$_OUT_THEME" in
    dark)
      _bg_color="#1e1e1e"
      _node_fill="#2d2d2d"
      _font_color="white"
      _edge_color="#aaaaaa"
      _cluster_fill="#2a2a2a"
      _cluster_font="white"
      ;;
    light)
      # explicit light values (same as defaults but explicit)
      _bg_color="#ffffff"
      _node_fill="#f5f5f5"
      _font_color="black"
      _edge_color="#333333"
      _cluster_fill="#eeeeee"
      _cluster_font="black"
      ;;
  esac

  {
    printf 'digraph callgraph {\n'
    printf '    graph [label="%s" labelloc=t fontname="Courier" fontsize=14 bgcolor="%s" fontcolor="%s"];\n' \
      "$_TITLE" "$_bg_color" "$_font_color"
    printf '    node  [shape=box fontname="Courier" style=filled fillcolor="%s" fontcolor="%s"];\n' \
      "$_node_fill" "$_font_color"
    printf '    edge  [fontname="Courier" fontsize=10 color="%s" fontcolor="%s"];\n' \
      "$_edge_color" "$_font_color"
    printf '    rankdir=LR;\n\n'

    if [[ $_MULTI -eq 1 ]]; then
      for _k in "${ALL_FUNCS[@]}"; do
        _f=$(_kfile "$_k"); _fmap[$_f]+=" $_k"
      done
      _ci=0
      for _f in $(printf '%s\n' "${!_fmap[@]}" | sort); do
        _bn="${_f##*/}"
        printf '    subgraph cluster_%d {\n' "$_ci"
        printf '        label="%s"; style=filled; fillcolor="%s"; fontcolor="%s";\n' \
          "$_bn" "$_cluster_fill" "$_cluster_font"
        for _k in ${_fmap[$_f]}; do
          _fn=$(_kfunc "$_k")
          printf '        "%s" [label="%s\\n%s()\\ncalled: %s\\nL%s"];\n' \
            "$_k" "${RTYPE[$_k]:-void}" "$_fn" "${FREQ[$_k]:-0}" "${LINE_RANGE[$_k]:-?}"
        done
        printf '    }\n\n'
        _ci=$(( _ci + 1 ))
      done
    else
      for _k in "${ALL_FUNCS[@]}"; do
        _fn=$(_kfunc "$_k")
        printf '    "%s" [label="%s\\n%s()\\ncalled: %s\\nL%s"];\n' \
          "$_fn" "${RTYPE[$_k]:-void}" "$_fn" "${FREQ[$_k]:-0}" "${LINE_RANGE[$_k]:-?}"
      done
    fi

    printf '\n'
    for _k in "${ALL_FUNCS[@]}"; do
      for _ck in ${CALLS[$_k]:-}; do
        _eid="${_k}->${_ck}"
        [[ -n "${_eseen[$_eid]:-}" ]] && continue
        _eseen[$_eid]=1
        if [[ $_MULTI -eq 1 ]]; then
          printf '    "%s" -> "%s";\n' "$_k" "$_ck"
        else
          printf '    "%s" -> "%s";\n' "$(_kfunc "$_k")" "$(_kfunc "$_ck")"
        fi
      done
    done
    printf '}\n'
  } > "$_out_file"
}

# =============================================================================
# Performance footer (only when -p)
# =============================================================================
_LINES_CLI=0
_LINES_FILE=0

_print_timing() {
  [[ $_SHOW_PERF -eq 1 ]] || return 0

  local _t_graph=$(( _T_BACKEND_END - _T_START      ))
  local _t_print=$(( _T_PRINT_END   - _T_PRINT_START ))
  local _t_file=$((  _T_END         - _T_PRINT_END   ))
  local _t_total=$(( _T_END         - _T_START       ))
  local _W=8

  printf '\n'
  printf '  %-8s  %*s ms\n' "mapping" "$_W" "$_t_graph"
  printf '  %-8s  %*s ms\n' "print"   "$_W" "$_t_print"
  if [[ -n "$_OUT_TXT$_OUT_MMD$_OUT_DOT" ]]; then
    printf '  %-8s  %*s ms\n' "file"  "$_W" "$_t_file"
  fi
  printf '  %s\n' "$(printf '%0.s─' {1..22})"
  printf '  %-8s  %*s ms\n' "total"   "$_W" "$_t_total"

  printf '\n'
  printf '  %-8s  %*s lines (src)\n' "read"  "$_W" "$_LINES_READ"
  if [[ $_NO_CLI -eq 0 ]]; then
    printf '  %-8s  %*s lines (cli)\n' "write" "$_W" "$_LINES_CLI"
  else
    printf '  %-8s  %*s lines (cli, suppressed by -t)\n' "write" "$_W" 0
  fi
  if [[ -n "$_OUT_TXT$_OUT_MMD$_OUT_DOT" ]]; then
    printf '            %*s lines (file)\n' "$_W" "$_LINES_FILE"
  fi
  printf '\n'
}

# =============================================================================
# Terminal output (skipped if -t)
# =============================================================================
_T_PRINT_START=$(_ts_ms)
if [[ $_NO_CLI -eq 0 ]]; then
  _TMP_CLI=$(mktemp)
  _print_ascii "$_USE_COLOR" > "$_TMP_CLI"
  _LINES_CLI=$(wc -l < "$_TMP_CLI")
  _T_PRINT_END=$(_ts_ms)
  cat "$_TMP_CLI"
  rm -f "$_TMP_CLI"
else
  _T_PRINT_END=$(_ts_ms)
fi

# =============================================================================
# File outputs
# =============================================================================
if [[ -n "$_OUT_TXT" ]]; then
  _print_ascii 0 > "$_OUT_TXT"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_TXT") ))
  printf '  -> plain text  : %s\n' "$_OUT_TXT"
fi

if [[ -n "$_OUT_MMD" ]]; then
  _write_mermaid "$_OUT_MMD"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_MMD") ))
  printf '  -> Mermaid     : %s\n' "$_OUT_MMD"
fi

if [[ -n "$_OUT_DOT" ]]; then
  _write_dot "$_OUT_DOT"
  _LINES_FILE=$(( _LINES_FILE + $(wc -l < "$_OUT_DOT") ))
  printf '  -> DOT         : %s  (render: dot -Tsvg -o graph.svg %s)\n' "$_OUT_DOT" "$_OUT_DOT"
fi

_T_END=$(_ts_ms)
_print_timing
