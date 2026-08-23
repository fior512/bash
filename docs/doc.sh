#!/bin/bash
# doc - unified x86/SIMD/C++ documentation tool
#
# Data sources (auto-downloaded to DATADIR on first use):
#   x86reference.xml - instruction encoding, flags, groups   [ref.x86asm.net]
#   intrinsics.xml    - Intel SIMD intrinsics + pseudocode    [intel.com CDN]
#   uops.xml          - latency/throughput/ports, per microarch [uops.info]
#
# Usage: doc [--arch <arch>] <category> <query>. Run "doc help" for details.

# Resolve the true path of this script (follow symlinks)
_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_SELF_DIR="$(cd "$(dirname "$_SELF")" && pwd)"

# Data lives next to the script in a 'data/' subdirectory.
# Override with DATADIR env var if needed: DATADIR=/custom/path doc asm mov
DATADIR="${DATADIR:-$_SELF_DIR/data}"
X86XML="$DATADIR/x86reference.xml"
IXML="$DATADIR/intrinsics.xml"
UXML="$DATADIR/uops.xml"

# Default arch: auto-detect from /proc/cpuinfo, else ZEN4
_detect_arch() {
    if [ ! -f /proc/cpuinfo ]; then echo "ZEN4"; return; fi
    local model
    model=$(grep -m1 "model name" /proc/cpuinfo | tr '[:upper:]' '[:lower:]')
    case "$model" in
        *"zen 5"*|*"ryzen"*" 9"*"9"[0-9][0-9][0-9]*) echo "ZEN5" ;;
        *"zen 4"*|*"ryzen"*" 7"[0-9][0-9][0-9]*|*"ryzen"*" 9"*"7"[0-9][0-9][0-9]*) echo "ZEN4" ;;
        *"zen 3"*|*"ryzen"*" 5"[0-9][0-9][0-9]*) echo "ZEN3" ;;
        *"zen 2"*) echo "ZEN2" ;;
        *"emerald rapids"*|*"sapphire rapids"*) echo "EMR" ;;
        *"meteor lake"*) echo "MTL-P" ;;
        *"raptor lake"*|*"alder lake"*) echo "ADL-P" ;;
        *"rocket lake"*) echo "RKL" ;;
        *"tiger lake"*) echo "TGL" ;;
        *"ice lake"*) echo "ICL" ;;
        *"skylake"*) echo "SKL" ;;
        *"haswell"*) echo "HSW" ;;
        *"broadwell"*) echo "BDW" ;;
        *) echo "ZEN4" ;;
    esac
}
ARCH="${DOC_ARCH:-$(_detect_arch)}"

# ─── terminal width ──────────────────────────────────────────────────────────
# Used to scale the simd concept/family/decomposition views to the actual
# console instead of a fixed 80 columns. Falls back to 80 when not a tty
# (piped/redirected output) or when the terminal size can't be queried.
if [ -t 1 ]; then
    TERM_COLS="${COLUMNS:-$(tput cols 2>/dev/null)}"
fi
[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=80
[ "$TERM_COLS" -lt 60 ] && TERM_COLS=60

# ─── colours ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    CH=$'\e[1;36m'   # bold cyan    – headers / labels
    CK=$'\e[1;33m'   # bold yellow  – keys / mnemonics
    CV=$'\e[0;32m'   # green        – values
    CP=$'\e[0;35m'   # magenta      – perf numbers
    CD=$'\e[2m'      # dim          – secondary
    CR=$'\e[0m'      # reset
    SEP="${CD}$(printf '─%.0s' {1..60})${CR}"
    DSEP="${CD}$(printf '═%.0s' {1..60})${CR}"
else
    CH=''; CK=''; CV=''; CP=''; CD=''; CR=''
    SEP="$(printf '─%.0s' {1..60})"
    DSEP="$(printf '═%.0s' {1..60})"
fi

# ─── arch friendly names ─────────────────────────────────────────────────────
arch_name() {
    case "$1" in
        ZEN5)  echo "AMD Zen 5" ;;
        ZEN4)  echo "AMD Zen 4 (Ryzen 7000)" ;;
        ZEN3)  echo "AMD Zen 3 (Ryzen 5000)" ;;
        ZEN2)  echo "AMD Zen 2 (Ryzen 3000)" ;;
        "ZEN+") echo "AMD Zen+" ;;
        EMR)   echo "Intel Emerald Rapids" ;;
        MTL-P) echo "Intel Meteor Lake" ;;
        ADL-P) echo "Intel Alder Lake" ;;
        RKL)   echo "Intel Rocket Lake" ;;
        TGL)   echo "Intel Tiger Lake" ;;
        ICL)   echo "Intel Ice Lake" ;;
        SKX)   echo "Intel Skylake-X" ;;
        SKL)   echo "Intel Skylake" ;;
        KBL)   echo "Intel Kaby Lake" ;;
        CFL)   echo "Intel Coffee Lake" ;;
        HSW)   echo "Intel Haswell" ;;
        BDW)   echo "Intel Broadwell" ;;
        IVB)   echo "Intel Ivy Bridge" ;;
        SNB)   echo "Intel Sandy Bridge" ;;
        *)     echo "$1" ;;
    esac
}

# ─── help ────────────────────────────────────────────────────────────────────
usage() {
    local aname
    aname=$(arch_name "$ARCH")
    cat <<EOF
${CH}NAME${CR}
    doc — x86/SIMD/C++ documentation tool

${CH}SYNOPSIS${CR}
    ${CK}doc${CR} [${CK}--arch${CR} <arch>] <category> <query>
    ${CK}doc update${CR}          download / refresh all data files
    ${CK}doc arch${CR}            show detected CPU arch + all valid --arch values

${CH}GLOBAL OPTIONS${CR}
    ${CK}--arch${CR} <arch>   Override microarchitecture for perf data
                   (default: auto-detected → ${CV}${ARCH}${CR} = ${CV}${aname}${CR})
                   Can also be set via env:  ${CK}export DOC_ARCH=ZEN4${CR}

${CH}CATEGORIES${CR}
    ${CK}asm${CR}   <mnemonic>     x86 instruction encoding + flags + perf
                   ${CD}Examples:  doc asm mov      doc asm imul   doc asm vaddps${CR}
                   ${CD}           doc --arch SKL asm mulps${CR}

    ${CK}asm reg${CR} <name>        Register reference
                   ${CD}Examples:  doc asm reg rax    doc asm reg rsp    doc asm reg rflags${CR}
                   ${CD}           doc asm reg xmm    doc asm reg mxcsr  doc asm reg list${CR}

    ${CK}asm size${CR} <keyword>    Memory transfer size / PTR keyword reference
                   ${CD}Examples:  doc asm size qword   doc asm size dword   doc asm size list${CR}

    ${CK}simd${CR}  <query>        SIMD instruction or C intrinsic lookup.
                   Query can be a mnemonic (VADDPS), an intrinsic (_mm256_add_ps),
                   a bare vector/suffix token (mm512, epi8), or an op/concept
                   word (load, fmadd, reciprocal). Op words match by name first,
                   then category, then definition text, and print a vector/func/
                   suffix breakdown -- definitions are derived from the naming
                   grammar or mined live from the matched intrinsics'
                   descriptions, not a static glossary. A bare suffix/vector
                   token instead shows it grouped with its sibling widths
                   (epi8/16/32/64/64x, mm/mm256/mm512, ...).
                   ${CD}Examples:  doc simd vaddps            (by asm mnemonic)${CR}
                   ${CD}           doc simd _mm256_add_ps     (by intrinsic name)${CR}
                   ${CD}           doc simd load              (op: name-first breakdown)${CR}
                   ${CD}           doc simd epi8              (suffix family: epi8/16/32/64x/...)${CR}
                   ${CD}           doc simd reciprocal        (definition-text fallback)${CR}
                   ${CD}           doc simd list avx2         (list all AVX2 intrinsics)${CR}
                   ${CD}           doc simd list avx512 load  (list AVX-512 Load ops)${CR}

    ${CK}simd vec${CR} <topic>      Vectorization concept overviews
                   ${CD}Examples:  doc simd vec intro      doc simd vec avx2    doc simd vec avx512${CR}
                   ${CD}           doc simd vec fma        doc simd vec gather  doc simd vec alignment${CR}
                   ${CD}           doc simd vec prefetch   doc simd vec intrinsics${CR}

    ${CK}cpp${CR}   <symbol>       C++ standard library (requires cppman)
                   ${CD}Examples:  doc cpp std::vector   doc cpp std::sort${CR}

${CH}PERF DATA${CR}
    When viewing asm/simd results, performance data is shown for
    ${CV}${ARCH}${CR} (${CV}${aname}${CR}).

    Columns:  Lat = latency (cycles)
              TP  = throughput (cycles per instruction, lower = faster)
              μops = micro-ops issued to scheduler
              Ports = execution units used

    Valid --arch values (from uops.info):
      ${CV}Intel:${CR}  SNB IVB HSW BDW SKL SKX KBL CFL RKL TGL ICL ADL-P MTL-P EMR
      ${CV}AMD:${CR}    ZEN+ ZEN2 ZEN3 ZEN4 ZEN5

${CH}DATA FILES${CR}
    Location: ${CV}<dir where doc lives>/data/${CR}
      x86reference.xml  — instruction encoding     [~500 KB, static]
      intrinsics.xml    — Intel intrinsics guide   [~7 MB, yearly]
      uops.xml          — perf data (all μarchs)   [~140 MB, monthly]

    Data always lives next to the script — no PATH changes needed.
    Override with: ${CK}DATADIR=/other/path doc asm mov${CR}

    Run ${CK}doc update${CR} to download/refresh all three.
    Individual files can be refreshed with ${CK}doc update asm${CR}, ${CK}doc update simd${CR},
    or ${CK}doc update perf${CR}.

${CH}ENVIRONMENT${CR}
    ${CK}DOC_ARCH${CR}     Default microarchitecture (overrides auto-detect)
    ${CK}DATADIR${CR}      Override data directory (default: ~/.local/share/x86doc)

${CH}EXAMPLES${CR}
    doc asm mov                        # MOV encoding, flags, ZEN4 perf
    doc --arch SKL asm mulps           # MULPS perf on Skylake specifically
    doc asm reg rsp                    # RSP: role, alignment rules, ABI notes
    doc asm reg xmm                    # XMM0-15: lanes, calling convention
    doc asm reg list                   # all registers at a glance
    doc asm size qword                 # QWORD PTR: zero-extend rules, usage
    doc asm size list                  # all transfer sizes at a glance
    doc simd vaddps                    # VADDPS: encoding + intrinsics + perf
    doc simd _mm256_fmadd_ps           # FMA intrinsic: sig + pseudocode + perf
    doc simd list avx2 arithmetic      # list all AVX2 arithmetic intrinsics
    doc simd vec avx2                  # AVX2 instruction cheatsheet
    doc simd vec alignment             # VZEROUPPER + alignment rules
    doc arch                           # show detected arch + all valid values
EOF
    exit 1
}

# ─── update / download ───────────────────────────────────────────────────────
do_update() {
    local target="${1:-all}"
    mkdir -p "$DATADIR"

    dl() {
        local label="$1" url="$2" dest="$3"
        printf "${CH}Downloading${CR} %s ...\n" "$label"
        if curl -fsSL --progress-bar -o "${dest}.tmp" "$url"; then
            mv "${dest}.tmp" "$dest"
            printf "  ${CV}OK${CR} → %s  (%s)\n" "$dest" "$(du -sh "$dest" | cut -f1)"
        else
            rm -f "${dest}.tmp"
            printf "  ${CK}FAILED${CR}: %s\n" "$url" >&2
            return 1
        fi
    }

    case "$target" in
        asm|all)
            dl "x86reference.xml (instruction encoding)" \
               "http://ref.x86asm.net/x86reference.xml" "$X86XML" ;;
    esac
    case "$target" in
        simd|all)
            dl "intrinsics.xml (Intel intrinsics guide)" \
               "https://www.intel.com/content/dam/develop/public/us/en/include/intrinsics-guide/data-latest.xml" \
               "$IXML" ;;
    esac
    case "$target" in
        perf|all)
            dl "uops.xml (latency/throughput, ~140 MB)" \
               "https://uops.info/instructions.xml" "$UXML" ;;
    esac
}

need_file() {
    local file="$1" hint="$2"
    if [ ! -f "$file" ]; then
        printf "${CK}Missing:${CR} %s\nRun: ${CV}doc update %s${CR}\n" "$file" "$hint" >&2
        exit 1
    fi
}

# ─── show arch info ──────────────────────────────────────────────────────────
do_arch() {
    printf "${CH}Detected arch:${CR} ${CV}%s${CR} (%s)\n\n" "$ARCH" "$(arch_name "$ARCH")"
    printf "${CH}Intel architectures (--arch):${CR}\n"
    printf "  SNB  = Sandy Bridge      IVB  = Ivy Bridge\n"
    printf "  HSW  = Haswell           BDW  = Broadwell\n"
    printf "  SKL  = Skylake           SKX  = Skylake-X / Cascade Lake\n"
    printf "  KBL  = Kaby Lake         CFL  = Coffee Lake\n"
    printf "  RKL  = Rocket Lake       TGL  = Tiger Lake\n"
    printf "  ICL  = Ice Lake          ADL-P= Alder Lake (P-core)\n"
    printf "  MTL-P= Meteor Lake       EMR  = Emerald Rapids\n"
    printf "  ARL-P= Arrow Lake\n\n"
    printf "${CH}AMD architectures (--arch):${CR}\n"
    printf "  ZEN+ = Zen+ (Ryzen 2000)  ZEN2 = Zen 2 (Ryzen 3000)\n"
    printf "  ZEN3 = Zen 3 (Ryzen 5000) ZEN4 = Zen 4 (Ryzen 7000)\n"
    printf "  ZEN5 = Zen 5 (Ryzen 9000)\n\n"
    printf "${CH}Override permanently:${CR}\n"
    printf "  export DOC_ARCH=ZEN4   # add to ~/.bashrc\n"
}

# ─── decode_syntax (operand notation) ────────────────────────────────────────
decode_syntax() {
    awk -F ' ' '
    function decode(a, t,   op) {
        if      (a=="E")   op="[r/m]"
        else if (a=="G")   op="reg"
        else if (a=="I")   op="imm"
        else if (a=="J")   op="rel"
        else if (a=="M")   op="mem"
        else if (a=="R")   op="reg"
        else if (a=="V")   op="xmm"
        else if (a=="W")   op="xmm/mem"
        else if (a=="AL")  op="al"
        else if (a=="AX")  op="ax"
        else if (a=="EAX") op="eax"
        else if (a=="RAX") op="rax"
        else if (a=="rAX") op="eax/rax"
        else               op=a
        if      (t=="b")   op="byte ptr " op
        else if (t=="w")   op="word ptr " op
        else if (t=="d")   op="dword ptr " op
        else if (t=="v")   op="word/dword ptr " op
        else if (t=="q")   op="qword ptr " op
        else if (t=="vqp") op="word/dword/qword ptr " op
        else if (t=="ss")  op=op "_ss"
        else if (t=="sd")  op=op "_sd"
        else if (t=="ps")  op=op "_ps"
        else if (t=="pd")  op=op "_pd"
        else if (t!="")    op=op "_" t
        return op
    }
    /^Syntax:/ {
        printf "Syntax: %s", $2
        for (i=3; i<=NF; i++) {
            split($i, parts, ":")
            op = decode(parts[2], parts[3])
            if (i == 3) printf " %s", op
            else        printf ", %s", op
        }
        printf "\n"; next
    }
    { print }
    '
}

# ─── group_entries ───────────────────────────────────────────────────────────
group_entries() {
    awk '
    function reg(key) { if (!(key in known)) { known[key]=1; order[++n]=key } }
    function reset_rec() { rm=""; rb=""; rsn=0; rxn=0; delete rsy; delete rx }
    function commit(   k,i) {
        if (rm=="") { reset_rec(); return }
        k=rm SUBSEP rb; reg(k); gm[k]=rm; gb[k]=rb
        for (i=1;i<=rsn;i++) if (!((k,rsy[i]) in sseen)) { sseen[k,rsy[i]]=1; gs[k,++gsn[k]]=rsy[i] }
        for (i=1;i<=rxn;i++) if (!((k,rx[i])  in xseen)) { xseen[k,rx[i]] =1; gx[k,++gxn[k]]=rx[i]  }
        reset_rec()
    }
    /^━/          { sep=$0; commit(); next }
    /^Mnemonic: / { rm=substr($0,11); next }
    /^Brief: /    { rb=substr($0,8);  next }
    /^Syntax: /   { rsy[++rsn]=substr($0,9); next }
                  { rx[++rxn]=$0 }
    END {
        commit()
        for (i=1;i<=n;i++) {
            k=order[i]; print "Mnemonic: " gm[k]
            if (gb[k]!="") print "Brief: " gb[k]
            for (j=1;j<=gsn[k];j++) printf (j==1?"Syntax: %s\n":"        %s\n"), gs[k,j]
            for (j=1;j<=gxn[k];j++) print gx[k,j]
            print sep
        }
    }
    '
}

# ─── uops perf lookup ────────────────────────────────────────────────────────
# Outputs a formatted perf block for a given mnemonic + arch.
uops_perf() {
    local mnem="${1^^}" arch="$2"
    [ ! -f "$UXML" ] && return
    # Collect all iforms for this mnemonic on this arch, deduplicated by form
    xmlstarlet sel --novalid -t \
        -m "//instruction[@iclass='${mnem}']/architecture[@name='${arch}']/measurement" \
        -o "PERF|" \
        -v "../../@string" -o "|" \
        -v "@TP_loop" -o "|" \
        -v "@uops" -o "|" \
        -v "@ports" -o "|" \
        -m "latency[@start_op='2' or @start_op='1'][1]" \
            -v "@cycles" \
        -b \
        -n \
        "$UXML" 2>/dev/null | sort -u | \
    awk -F'|' -v arch="$arch" -v aname="$(arch_name "$arch")" -v CP="$CP" -v CH="$CH" -v CV="$CV" -v CD="$CD" -v CR="$CR" '
    BEGIN { n=0 }
    /^PERF\|/ {
        iform=$2; tp=$3; uops=$4; ports=$5; lat=$6
        # clean up port notation
        gsub(/[0-9]+\*/, "", ports)
        row[n++] = sprintf("  %-36s  %s%4s%s  %s%4s%s  %s%-2s%s  %s%s%s",
            iform,
            CP, (lat==""?"?":lat), CR,
            CP, tp,  CR,
            CV, uops, CR,
            CD, ports, CR)
    }
    END {
        if (n==0) exit
        printf "%s  Performance on %s%s%s (%s):%s\n", CH, CV, arch, CH, aname, CR
        printf "%s  %-36s  %4s  %4s  %-4s  %s%s\n", CD, "Form", "Lat", "TP", "μops", "Ports", CR
        for (i=0;i<n;i++) print row[i]
    }
    '
}

# ─── x86doc ──────────────────────────────────────────────────────────────────
x86doc() {
    local mnemonic="${1^^}"
    need_file "$X86XML" "asm"

    local hits
    hits=$(xmlstarlet sel --novalid -t \
        -m "//entry[syntax/mnem='$mnemonic']" -o "1" -n "$X86XML" 2>/dev/null | wc -l)

    if [ "$hits" -eq 0 ]; then
        printf "${CK}No exact match for '%s'.${CR}\n" "$mnemonic"
        printf "${CD}Fuzzy candidates:${CR}\n"
        xmlstarlet sel --novalid -t \
            -m "//entry/syntax/mnem[starts-with(.,'$mnemonic')]" \
            -v "." -n "$X86XML" 2>/dev/null | sort -u | head -20 | sed 's/^/  /'
        return 1
    fi

    {
    xmlstarlet sel --novalid -t \
        -m "//entry[syntax/mnem='$mnemonic']" \
        -o "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -n \
        -o "Mnemonic: " -v "(syntax/mnem)[1]" -n \
        -if "note/brief"    -o "Brief: "    -v "note/brief"  -n -fi \
        -m "syntax" \
            -o "Syntax: " -v "mnem" \
            -m "dst" -o " dst:" -v "a" -o ":" -v "t" -b \
            -m "src" -o " src:" -v "a" -o ":" -v "t" -b \
            -n \
        -b \
        -if "proc_start"             -o "Introduced: CPU gen "  -v "proc_start"  -n -fi \
        -if "proc_end"               -o "Removed in: CPU gen "  -v "proc_end"    -n -fi \
        -if "grp1 or grp2 or grp3"  -o "Category: " \
            -v "concat(grp1,', ',grp2,', ',grp3)"               -n -fi \
        -o "Encoding attributes:" -n \
        -if "@direction" -o "  direction = " -v "@direction" -n -fi \
        -if "@op_size"   -o "  op_size   = " -v "@op_size"   -n -fi \
        -if "@r"         -o "  r         = " -v "@r"         -n -fi \
        -if "@lock"      -o "  lock      = " -v "@lock"      -n -fi \
        -if "@mode"      -o "  mode      = " -v "@mode"      -n -fi \
        -if "@attr"      -o "  attr      = " -v "@attr"      -n -fi \
        -if "modif_f[string-length()>0]"  -o "Modified flags:  " -v "modif_f" -n -fi \
        -if "def_f[string-length()>0]"    -o "Defined flags:   " -v "def_f"   -n -fi \
        -if "undef_f[string-length()>0]"  -o "Undefined flags: " -v "undef_f" -n -fi \
        -if "f_vals[string-length()>0]"   -o "Flag values:     " -v "f_vals"  -n -fi \
        -if "note[not(brief)]"            -o "Note: "            -v "note"     -n -fi \
        -o "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -n \
        "$X86XML" 2>/dev/null | sed "s#$X86XML##g" | decode_syntax | group_entries
    uops_perf "$mnemonic" "$ARCH"
    } | less -RF
}

# ─── simd concept: dynamic token decoding ──────────────────────────────────
# No static per-token glossary. Parse width/sign from the token itself,
# cross-check against the XML's return types. Irregular tokens (ph, bf16,
# op words like "load") fall back: mine first sentence of a matching
# intrinsic's <description>.

_simd_is_suffix() {
    [[ "$1" =~ ^(ep[iu][0-9]+x?|pi[0-9]+|si[0-9]+|mask[0-9]+|[iu][0-9]+|p[sd]|s[sd]|ph|bf16)$ ]]
}

_simd_is_vector() {
    [[ "$1" =~ ^mm[0-9]*$ ]]
}

_simd_mine_def() {
    local tok="$1" desc
    desc=$(xmlstarlet sel --novalid -t \
        -m "(//intrinsic[contains(@name,'_${tok}')]/description)[1]" -v "." "$IXML" 2>/dev/null)
    [ -z "$desc" ] && desc=$(xmlstarlet sel --novalid -t \
        -m "(//intrinsic[contains(@name,'${tok}')]/description)[1]" -v "." "$IXML" 2>/dev/null)
    desc="${desc%%.*}."
    desc="${desc//\"/}"
    printf "%s" "${desc:-(no description found)}"
}

# Mine from one exact @name, not a dataset-wide substring search --
# keeps the mined text on-topic.
_simd_mine_named() {
    local name="$1" desc
    desc=$(xmlstarlet sel --novalid -t \
        -m "//intrinsic[@name='${name}']/description" -v "." "$IXML" 2>/dev/null)
    desc="${desc%%.*}."
    desc="${desc//\"/}"
    printf "%s" "${desc:-(no description found)}"
}

# Scale a column budget to $TERM_COLS instead of a fixed 80.
# $1 = line overhead (label/padding chars, calibrated at 80 cols).
# $2 = floor, so narrow terminals don't collapse to nothing.
_simd_budget() {
    local overhead="$1" min="${2:-20}"
    local b=$((TERM_COLS - overhead))
    [ "$b" -lt "$min" ] && b="$min"
    printf "%d" "$b"
}

# Hard-cap a string to $2 visible chars (ellipsis on truncation). Keeps
# mined description text from blowing past the console width.
_simd_trunc() {
    local text="$1" max="$2"
    if [ "${#text}" -gt "$max" ]; then
        printf "%s…" "${text:0:$((max > 1 ? max - 1 : 0))}"
    else
        printf "%s" "$text"
    fi
}

# Join a comma list up to $2 chars, summarize the rest as "(+N more)".
# Full list still shown, one per line, in the section below.
_simd_join_trunc() {
    local csv="$1" max="$2"
    local -a items
    IFS=',' read -ra items <<< "$csv"
    # reserve room for the " (+N more)" trailer so the final line never
    # overflows $max once the trailer is appended
    local budget=$((max - 12))
    local out="" n=0 it cand
    for it in "${items[@]}"; do
        cand="${out}${out:+,}${it}"
        if [ "${#cand}" -gt "$budget" ]; then
            printf "%s (+%d more)" "$out" "$(( ${#items[@]} - n ))"
            return
        fi
        out="$cand"; n=$((n + 1))
    done
    printf "%s" "$out"
}

# Only hardcode in this file: ~10 root morphemes of Intel's naming grammar
# (mm/ep/i/u/si/pi/mask/p/s/x). Fixed vocabulary, not per-value data --
# every width/sign/variant built from them (epi128, si256) is still derived.
# Verified against Intel's C++ Intrinsic Reference. Re-verify before editing
# a root -- one wrong root poisons every token built on it. Bit us once
# already with "si".
_simd_token_def() {
    local tok="$1"
    case "$tok" in
        "(scalar)") printf "no vector prefix (GPR/mask arg)" ;;
        "(base)")   printf "no op suffix beyond mask/vector" ;;
        mm|mm[0-9]*)
            local width tech
            width=$(xmlstarlet sel --novalid -t \
                -m "//intrinsic[starts-with(@name,'_${tok}_')]/return[starts-with(@type,'__m') and not(contains(@type,'mask'))]" \
                -v "@type" -n "$IXML" 2>/dev/null | grep -oE '[0-9]+' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
            [ -z "$width" ] && width="128"
            local techs_present pref
            techs_present=$(xmlstarlet sel --novalid -t \
                -m "//intrinsic[starts-with(@name,'_${tok}_')]" -v "@tech" -n "$IXML" 2>/dev/null | sort -u)
            for pref in SSE_ALL AVX_ALL AVX-512 MMX SVML AMX Other; do
                if grep -qxF "$pref" <<< "$techs_present"; then tech="$pref"; break; fi
            done
            printf "%s-bit vector%s" "$width" "${tech:+ (tech=$tech)}"
            ;;
        ep[iu][0-9]*|ep[iu][0-9]*x)
            local sign=${tok:2:1} rest=${tok:3} variant=""
            [[ "$rest" == *x ]] && { variant=" (long-long/imm64 overload)"; rest="${rest%x}"; }
            [ "$sign" = "i" ] && sign="signed" || sign="unsigned"
            printf "packed %s %s-bit integers%s" "$sign" "$rest" "$variant"
            ;;
        pi[0-9]*)
            printf "packed %s-bit integers (MMX)" "${tok#pi}"
            ;;
        si[0-9]*)
            local w="${tok#si}"
            if [ "$w" -ge 128 ]; then
                printf "signed integer, %s-bit vector (opaque, unspecified elements)" "$w"
            else
                printf "signed integer, %s-bit (opaque, unspecified elements)" "$w"
            fi
            ;;
        mask[0-9]*)
            printf "%s-bit mask register (__mmask%s)" "${tok#mask}" "${tok#mask}"
            ;;
        p[sd])
            [ "${tok#p}" = "s" ] && printf "packed single-precision float" || printf "packed double-precision float"
            ;;
        s[sd])
            [ "${tok#s}" = "s" ] && printf "scalar single-precision float" || printf "scalar double-precision float"
            ;;
        [iu][0-9]*)
            local sign=${tok:0:1}
            [ "$sign" = "i" ] && sign="signed" || sign="unsigned"
            printf "%s %s-bit scalar integer" "$sign" "${tok:1}"
            ;;
        *)
            _simd_mine_def "$tok"
            ;;
    esac
}

# Split a family token into its morphemes for the "tok = a + b + c" line.
# Same rules as _simd_token_def, surfaced piece by piece.
_simd_morphs() {
    local tok="$1" kind="$2"
    case "$kind" in
        ep)
            local sign=${tok:2:1} rest=${tok:3}
            if [[ "$rest" == *x ]]; then
                printf "ep + %s + %s + x" "$sign" "${rest%x}"
            else
                printf "ep + %s + %s" "$sign" "$rest"
            fi
            ;;
        pi)    printf "pi + %s" "${tok#pi}" ;;
        si)    printf "si + %s" "${tok#si}" ;;
        mask)  printf "mask + %s" "${tok#mask}" ;;
        iu)    printf "%s + %s" "${tok:0:1}" "${tok:1}" ;;
        float) printf "%s + %s" "${tok:0:1}" "${tok:1}" ;;
        mm)
            local w="${tok#mm}"
            [ -z "$w" ] && printf "mm  (128 implied)" || printf "mm + %s" "$w"
            ;;
        *) printf "%s" "$tok" ;;
    esac
}

# Colored fixed-width cell: pad plain text first, wrap in color after --
# keeps escape codes out of the %-Ns width count, grid stays aligned.
_simd_cell() {
    local text="$1" width="$2" color="${3:-$CV}"
    printf "${color}%-${width}s${CR}" "$text"
}

# Bare suffix/vector token ("epi8", "mm512"): group with siblings
# (epi8/16/32/64/64x, epu8/16/32/64, ...) instead of a flat intrinsic list.
_simd_family() {
    local tok="$1"
    local pattern label kind
    case "$tok" in
        ep[iu][0-9]*|ep[iu][0-9]*x) pattern='ep[iu][0-9]+x?$'; label="ep*  (extended-packed integer element type)"; kind="ep" ;;
        pi[0-9]*)       pattern='pi[0-9]+$';       label="pi*  (packed integer, MMX)"; kind="pi" ;;
        si[0-9]*)       pattern='si[0-9]+$';       label="si*  (generic integer vector width)"; kind="si" ;;
        mask[0-9]*)     pattern='mask[0-9]+$';     label="mask*  (mask register width)"; kind="mask" ;;
        [iu][0-9]*)     pattern='[iu][0-9]+$';     label="i*/u*  (scalar integer sign/width)"; kind="iu" ;;
        p[sd]|s[sd])    pattern='[ps][sd]$';       label="ps/pd/ss/sd  (float precision, packed vs scalar)"; kind="float" ;;
        mm|mm[0-9]*)    pattern='mm[0-9]*$';       label="mm*  (vector width)"; kind="mm" ;;
        *)              pattern="${tok}\$";        label="$tok"; kind="" ;;
    esac

    local names siblings
    names=$(xmlstarlet sel --novalid -t -m "//intrinsic" -v "@name" -n "$IXML" 2>/dev/null)
    if [ "$kind" = "mm" ]; then
        siblings=$(grep -oE "^_(${pattern})" <<< "$names" | sed 's/^_//' | sort -Vu)
    else
        siblings=$(grep -oE "_(${pattern})" <<< "$names" | sed 's/^_//' | sort -Vu)
    fi
    [ -z "$siblings" ] && siblings="$tok"

    printf "${CH}Suffix family: %s${CR}\n\n" "$label"

    printf "  ${CK}morphology${CR}\n"
    case "$kind" in
        ep)
            printf "    ${CV}ep${CR}        ${CD}extended packed (element-wise operand)${CR}\n"
            printf "    ${CV}i / u${CR}     ${CD}signed / unsigned integer${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}element width in bits${CR}\n"
            printf "    ${CV}x${CR}         ${CD}long-long / imm64-arg overload (same width, alt C signature)${CR}\n"
            ;;
        pi)
            printf "    ${CV}pi${CR}        ${CD}packed integer (MMX, 64-bit register)${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}element width in bits${CR}\n"
            ;;
        si)
            printf "    ${CV}si${CR}        ${CD}signed integer -- opaque vector, element width${CR}\n"
            printf "              ${CD}unspecified (used for casts/logic/generic loads,${CR}\n"
            printf "              ${CD}not per-element math)${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}width in bits of the whole vector (>=128), or a${CR}\n"
            printf "              ${CD}scalar integer width (<128)${CR}\n"
            ;;
        mask)
            printf "    ${CV}mask${CR}      ${CD}mask register (__mmaskN, one bit per lane)${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}number of mask bits${CR}\n"
            ;;
        iu)
            printf "    ${CV}i / u${CR}     ${CD}signed / unsigned${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}scalar integer width in bits${CR}\n"
            ;;
        float)
            printf "    ${CV}p / s${CR} (1st letter)   ${CD}packed (multiple elements) / scalar${CR}\n"
            printf "                         ${CD}(one element, rest of vector untouched)${CR}\n"
            printf "    ${CV}s / d${CR} (2nd letter)   ${CD}single- / double-precision IEEE-754${CR}\n"
            ;;
        mm)
            printf "    ${CV}mm${CR}        ${CD}vector register (\"mm\" traces back to MMX,${CR}\n"
            printf "              ${CD}Intel's original \"MultiMedia eXtension\" regs)${CR}\n"
            printf "    ${CV}<N>${CR}       ${CD}vector width in bits (omitted = 128, i.e. SSE)${CR}\n"
            ;;
    esac

    local qdef qmorph
    qdef=$(_simd_token_def "$tok")
    qmorph=$(_simd_morphs "$tok" "$kind")
    printf "\n  ${CK}%s${CR} = ${CV}%s${CR}\n" "$tok" "$qmorph"
    printf "  → ${CD}%s${CR}\n" "$(_simd_trunc "$qdef" "$(_simd_budget 4)")"

    # 2-axis grid for families with real sign/precision structure; a flat
    # width list for the rest (they're fully explained by the legend above).
    case "$kind" in
        ep)
            local -a widths=()
            local s w
            while IFS= read -r s; do
                w="${s:3}"
                [[ " ${widths[*]-} " == *" $w "* ]] || widths+=("$w")
            done <<< "$siblings"
            IFS=$'\n' widths=($(printf '%s\n' "${widths[@]}" | sort -V)); unset IFS

            printf "\n  ${CK}by sign / width${CR}\n"
            printf "    %-10s" ""
            for w in "${widths[@]}"; do _simd_cell "$w" 8 "$CD"; done
            printf "\n    %-10s" "signed"
            for w in "${widths[@]}"; do
                if grep -qxF "epi${w}" <<< "$siblings"; then _simd_cell "epi${w}" 8
                else _simd_cell "-" 8 "$CD"; fi
            done
            printf "\n    %-10s" "unsigned"
            for w in "${widths[@]}"; do
                if grep -qxF "epu${w}" <<< "$siblings"; then _simd_cell "epu${w}" 8
                else _simd_cell "-" 8 "$CD"; fi
            done
            printf "\n"
            ;;
        iu)
            local -a widths=()
            local s w
            while IFS= read -r s; do
                w="${s:1}"
                [[ " ${widths[*]-} " == *" $w "* ]] || widths+=("$w")
            done <<< "$siblings"
            IFS=$'\n' widths=($(printf '%s\n' "${widths[@]}" | sort -V)); unset IFS

            printf "\n  ${CK}by sign / width${CR}\n"
            printf "    %-10s" ""
            for w in "${widths[@]}"; do _simd_cell "$w" 8 "$CD"; done
            printf "\n    %-10s" "signed"
            for w in "${widths[@]}"; do
                if grep -qxF "i${w}" <<< "$siblings"; then _simd_cell "i${w}" 8
                else _simd_cell "-" 8 "$CD"; fi
            done
            printf "\n    %-10s" "unsigned"
            for w in "${widths[@]}"; do
                if grep -qxF "u${w}" <<< "$siblings"; then _simd_cell "u${w}" 8
                else _simd_cell "-" 8 "$CD"; fi
            done
            printf "\n"
            ;;
        float)
            printf "\n  ${CK}by form / precision${CR}\n"
            printf "    %-10s" ""; _simd_cell "single" 8 "$CD"; _simd_cell "double" 8 "$CD"; printf "\n"
            printf "    %-10s" "packed"; _simd_cell "ps" 8; _simd_cell "pd" 8; printf "\n"
            printf "    %-10s" "scalar"; _simd_cell "ss" 8; _simd_cell "sd" 8; printf "\n"
            ;;
        *)
            printf "\n  ${CK}by width${CR}\n"
            awk '{ match($0, /^[a-zA-Z]+/); p=substr($0,RSTART,RLENGTH); d=substr($0,RLENGTH+1);
                   g[p] = g[p] (g[p]=="" ? "" : ", ") (d=="" ? "-" : d) }
                 END { for (p in g) printf "    %-6s : %s\n", p, g[p] }' <<< "$siblings" | sort \
                | while IFS= read -r row; do
                    printf "    ${CV}%s${CR}\n" "${row#    }"
                  done
            ;;
    esac

    local example
    example=$(xmlstarlet sel --novalid -t -m "(//intrinsic[contains(@name,'_${tok}')])[1]" -v "@name" -n "$IXML" 2>/dev/null)
    [ -n "$example" ] && printf "\n  ${CD}example:${CR} ${CV}%s${CR}\n" "$example"
    printf "\n${CD}More: 'doc simd list <tech>'  or  'doc simd load' (op breakdown)${CR}\n"
}

# Decompose a set of intrinsic names into vector/func/suffix axes and print
# a delimited cheatsheet. Reads "name|tech|category" lines on stdin.
_simd_concept() {
    local query="$1" mode="$2" lc="$3"
    local raw
    raw=$(awk -F'|' '
    {
        name=$1; tech=$2; cat=$3
        techs[tech]=1; cats[cat]=1; catcount[cat]++
        count++

        nm = name
        sub(/^_/, "", nm)
        n = split(nm, parts, "_")
        i = 2
        vector = parts[1]
        if (vector !~ /^mm(256|512)?$/) { vector = "(scalar)"; i = 1 }
        mask = ""
        if (parts[i]=="mask" || parts[i]=="maskz") { mask = parts[i]; i++ }
        suffix = ""
        opend = n
        if (i <= n) {
            last = parts[n]
            if (last ~ /^(ep[iu][0-9]+x?|pi[0-9]+|si[0-9]+|mask[0-9]+|[iu][0-9]+|p[sd]|s[sd]|ph|bf16)$/) { suffix = last; opend = n - 1 }
        }
        optype = ""
        for (j=i; j<=opend; j++) optype = optype (optype=="" ? "" : "_") parts[j]
        if (optype == "") optype = "(base)"
        if (mask != "") optype = mask "_" optype

        vectors[vector]=1
        types[optype]=1
        if (!(optype in typeex) || length(name) < length(typeex[optype])) typeex[optype] = name
        if (suffix != "") {
            suffixes[suffix]=1
            if (!(suffix in suffex) || length(name) < length(suffex[suffix])) suffex[suffix] = name
        }

        score = length(name) - (index(name,"512") ? 1000 : 0)
        if (pattern == "" || score < bestscore) {
            bestscore = score; pattern = name
            pvector = vector; ptype = optype; psuffix = (suffix=="" ? "-" : suffix)
        }
    }
    END {
        printf "COUNT\t%d\n", count
        printf "TECHS\t";    first=1; for (k in techs)    { printf "%s%s", (first?"":","), k; first=0 }; printf "\n"
        printf "CATS\t";     first=1; for (k in cats)     { printf "%s%s", (first?"":","), k; first=0 }; printf "\n"
        bestcat=""; bestcatn=0
        for (k in catcount) { if (catcount[k] > bestcatn) { bestcatn = catcount[k]; bestcat = k } }
        printf "BESTCAT\t%s\n", bestcat
        printf "VECTORS\t";  first=1; for (k in vectors)  { printf "%s%s", (first?"":","), k; first=0 }; printf "\n"
        printf "TYPES\t";    first=1; for (k in types)    { printf "%s%s", (first?"":","), k; first=0 }; printf "\n"
        printf "SUFFIXES\t"; first=1; for (k in suffixes) { printf "%s%s", (first?"":","), k; first=0 }; printf "\n"
        printf "TYPEEX\t";   first=1; for (k in typeex)   { printf "%s%s=%s", (first?"":";"), k, typeex[k]; first=0 }; printf "\n"
        printf "SUFFEX\t";   first=1; for (k in suffex)   { printf "%s%s=%s", (first?"":";"), k, suffex[k]; first=0 }; printf "\n"
        printf "PATTERN\t%s\n", pattern
        printf "PVECTOR\t%s\n", pvector
        printf "PTYPE\t%s\n", ptype
        printf "PSUFFIX\t%s\n", psuffix
    }
    ')

    local cnt="" techs="" cats="" bestcat="" vectors="" types="" suffixes="" pattern="" pvector="" ptype="" psuffix="" typeex_raw="" suffex_raw=""
    while IFS=$'\t' read -r key val; do
        case "$key" in
            COUNT)    cnt="$val" ;;
            TECHS)    techs="$val" ;;
            CATS)     cats="$val" ;;
            BESTCAT)  bestcat="$val" ;;
            VECTORS)  vectors="$val" ;;
            TYPES)    types="$val" ;;
            SUFFIXES) suffixes="$val" ;;
            TYPEEX)   typeex_raw="$val" ;;
            SUFFEX)   suffex_raw="$val" ;;
            PATTERN)  pattern="$val" ;;
            PVECTOR)  pvector="$val" ;;
            PTYPE)    ptype="$val" ;;
            PSUFFIX)  psuffix="$val" ;;
        esac
    done <<< "$raw"

    vectors=$(tr ',' '\n' <<< "$vectors" | sort -V | paste -sd,)
    types=$(tr ',' '\n' <<< "$types" | sort | paste -sd,)
    suffixes=$(tr ',' '\n' <<< "$suffixes" | sort | paste -sd,)

    local -A TYPE_EXAMPLE SUFF_EXAMPLE
    local pair k v
    IFS=';' read -ra pair <<< "$typeex_raw"
    for k in "${pair[@]}"; do
        [ -z "$k" ] && continue
        TYPE_EXAMPLE["${k%%=*}"]="${k#*=}"
    done
    IFS=';' read -ra pair <<< "$suffex_raw"
    for k in "${pair[@]}"; do
        [ -z "$k" ] && continue
        SUFF_EXAMPLE["${k%%=*}"]="${k#*=}"
    done

    local mode_label
    case "$mode" in
        name)       mode_label="name match" ;;
        category)   mode_label="category match" ;;
        definition) mode_label="definition match" ;;
    esac

    local header_prefix="${query^^}  (${cnt} intrinsics, ${mode_label}, tech="
    printf "${CH}%s${CR}  (%s intrinsics, %s, tech=%s)\n\n" "${query^^}" "$cnt" "$mode_label" \
        "$(_simd_join_trunc "$techs" "$(_simd_budget $((${#header_prefix} + 1)) 15)")"
    printf "  ${CK}vector${CR} : %s\n" "$(_simd_join_trunc "$vectors" "$(_simd_budget 12)")"
    printf "  ${CK}func${CR}   : %s\n" "$(_simd_join_trunc "$types" "$(_simd_budget 12)")"
    printf "  ${CK}suffix${CR} : %s\n" "$(_simd_join_trunc "$suffixes" "$(_simd_budget 12)")"

    local -a vtoks ttoks stoks
    IFS=',' read -ra vtoks <<< "$vectors"
    IFS=',' read -ra ttoks <<< "$types"
    IFS=',' read -ra stoks <<< "$suffixes"

    local t def ex

    printf "\n  ${CH}vector${CR}\n"
    for t in "${vtoks[@]}"; do
        [ -z "$t" ] && continue
        def=$(_simd_token_def "$t")
        printf "    ${CV}%-12s${CR} ${CD}%s${CR}\n" "$t" "$(_simd_trunc "$def" "$(_simd_budget 18)")"
    done

    # Collapse mask_/maskz_ variants of the same base op into one row --
    # they differ only by the writemask modifier, not by what they do.
    printf "\n  ${CH}func${CR}  ${CD}(mask/maskz = writemask variants also exist)${CR}\n"
    local -A CORE_MASK CORE_MASKZ CORE_EX
    local -a core_order=()
    for t in "${ttoks[@]}"; do
        [ -z "$t" ] && continue
        local core="$t" tag=""
        case "$t" in
            mask_*)  core="${t#mask_}"; tag="mask" ;;
            maskz_*) core="${t#maskz_}"; tag="maskz" ;;
        esac
        [[ " ${core_order[*]-} " == *" $core "* ]] || core_order+=("$core")
        case "$tag" in
            mask)  CORE_MASK[$core]=1 ;;
            maskz) CORE_MASKZ[$core]=1 ;;
        esac
        if [ -z "${CORE_EX[$core]:-}" ] || [ -z "$tag" ]; then
            CORE_EX[$core]="${TYPE_EXAMPLE[$t]:-}"
        fi
    done
    local core flags
    for core in "${core_order[@]}"; do
        flags=""
        [ -n "${CORE_MASK[$core]:-}" ]  && flags+=" +mask"
        [ -n "${CORE_MASKZ[$core]:-}" ] && flags+=" +maskz"
        ex="${CORE_EX[$core]:-}"
        if [ -n "$ex" ]; then
            def=$(_simd_mine_named "$ex")
        else
            def=$(_simd_token_def "$core")
        fi
        printf "    ${CV}%s${CR}%s\n" "$core" "$flags"
        printf "      ${CD}%s${CR}\n" "$(_simd_trunc "$def" "$(_simd_budget 6)")"
    done

    printf "\n  ${CH}suffix${CR}\n"
    for t in "${stoks[@]}"; do
        [ -z "$t" ] && continue
        if _simd_is_suffix "$t" && [ "$t" != "ph" ] && [ "$t" != "bf16" ]; then
            def=$(_simd_token_def "$t")
        else
            ex="${SUFF_EXAMPLE[$t]:-}"
            if [ -n "$ex" ]; then
                def=$(_simd_mine_named "$ex")
            else
                def=$(_simd_token_def "$t")
            fi
        fi
        printf "    ${CV}%-12s${CR} ${CD}%s${CR}\n" "$t" "$(_simd_trunc "$def" "$(_simd_budget 18)")"
    done

    printf "\n  ${CD}naming pattern:${CR} _<vector>_[mask|maskz_]<func>_<suffix>\n"
    printf "  ${CD}example:${CR}        ${CV}%s${CR}\n" "$pattern"
    printf "                  ${CK}vector${CR}=${CV}%s${CR}  ${CK}func${CR}=${CV}%s${CR}  ${CK}suffix${CR}=${CV}%s${CR}\n" \
        "$pvector" "$(_simd_trunc "$ptype" "$(_simd_budget 50 15)")" "$psuffix"

    if [ "$mode" = "name" ]; then
        local rel
        rel=$(xmlstarlet sel --novalid -t \
            -m "//intrinsic[contains(translate(description,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${lc}')][not(contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${lc}'))]" \
            -v "@name" -o "  [" -v "category[1]" -o "]" -n "$IXML" 2>/dev/null | sort -u | head -8)
        if [ -n "$rel" ]; then
            printf "\n${CH}Related (by definition, not literally named '%s'):${CR}\n" "$query"
            sed -E "s/^(_[a-zA-Z0-9_]+)(  \[.*\])$/${CV}\1${CR}${CD}\2${CR}/" <<< "$rel" | sed 's/^/  /'
        fi
    fi

    printf "\n${CD}More: 'doc simd list <tech> %s'${CR}\n" "$(_simd_trunc "${bestcat:-${cats%%,*}}" "$(_simd_budget 40)")"
}

# ─── simd doc ────────────────────────────────────────────────────────────────
simd_doc() {
    need_file "$IXML" "simd"
    local query="$1"
    local upper="${query^^}"

    # ── list mode: doc simd list <tech> [category] ────────────────────────
    if [ "$upper" = "LIST" ]; then
        local tech="${2^^}" cat_filter="${3}"
        # normalise tech aliases
        case "$tech" in
            AVX2)    tech="AVX_ALL" ;;  # AVX2 lives under AVX_ALL in this XML
            AVX)     tech="AVX_ALL" ;;
            SSE*)    tech="SSE_ALL" ;;
            AVX512*|AVX-512*) tech="AVX-512" ;;
        esac
        printf "${CH}Intrinsics [tech=%s%s]:${CR}\n" "$tech" \
               "${cat_filter:+ category~$cat_filter}"
        xmlstarlet sel --novalid -t \
            -m "//intrinsic[@tech='${tech}']${cat_filter:+[contains(translate(category,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${cat_filter,,}')]}" \
            -v "@name" -o "  " -v "category[1]" -o "  [" -v "CPUID" -o "]" -n \
            "$IXML" 2>/dev/null | sort | less -RF
        return
    fi

    # ── lookup by intrinsic name (starts with _mm) ────────────────────────
    if [[ "$query" == _mm* ]]; then
        local result
        result=$(xmlstarlet sel --novalid -t \
            -m "//intrinsic[@name='${query}']" \
            -o "FOUND" -n "$IXML" 2>/dev/null | wc -l)
        if [ "$result" -eq 0 ]; then
            printf "${CK}No exact match for '%s'.${CR}\nFuzzy matches:\n" "$query"
            xmlstarlet sel --novalid -t \
                -m "//intrinsic[contains(@name,'${query}')]" \
                -v "@name" -n "$IXML" 2>/dev/null | head -20 | sed 's/^/  /'
            return 1
        fi
        { _print_intrinsic "$query"; _simd_decompose_name "$query"; } | less -RF
        return
    fi

    # ── lookup by asm mnemonic: find intrinsics that map to it ───────────
    local by_asm
    by_asm=$(xmlstarlet sel --novalid -t \
        -m "//intrinsic[instruction/@name='${upper}']" \
        -v "@name" -n "$IXML" 2>/dev/null | head -5)

    if [ -n "$by_asm" ]; then
        # also show the asm encoding block from x86reference if available
        if [ -f "$X86XML" ]; then
            local hits
            hits=$(xmlstarlet sel --novalid -t \
                -m "//entry[syntax/mnem='$upper']" -o "1" -n "$X86XML" 2>/dev/null | wc -l)
            [ "$hits" -gt 0 ] && {
                xmlstarlet sel --novalid -t \
                    -m "//entry[syntax/mnem='$upper']" \
                    -o "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -n \
                    -o "Mnemonic: " -v "(syntax/mnem)[1]" -n \
                    -if "note/brief" -o "Brief: " -v "note/brief" -n -fi \
                    -m "syntax" -o "Syntax: " -v "mnem" \
                        -m "dst" -o " dst:" -v "a" -o ":" -v "t" -b \
                        -m "src" -o " src:" -v "a" -o ":" -v "t" -b -n -b \
                    -if "modif_f[string-length()>0]" -o "Modified flags: " -v "modif_f" -n -fi \
                    -o "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -n \
                    "$X86XML" 2>/dev/null | sed "s#$X86XML##g" | decode_syntax | group_entries
            }
        fi
        {
        while IFS= read -r iname; do
            _print_intrinsic "$iname"
        done <<< "$by_asm"
        uops_perf "$upper" "$ARCH"
        } | less -RF
        return
    fi

    # ── exact-token lookup: bare vector-width or element-suffix token ────
    local lc="${query,,}"
    if _simd_is_suffix "$lc" || _simd_is_vector "$lc"; then
        { _simd_family "$lc"; } | less -RF
        return
    fi

    # ── concept search: name (primary), then category, then definition ──
    local matches label
    matches=$(xmlstarlet sel --novalid -t \
        -m "//intrinsic[contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${lc}')]" \
        -v "@name" -o "|" -v "@tech" -o "|" -v "category[1]" -n "$IXML" 2>/dev/null)
    label="name"

    if [ -z "$matches" ]; then
        matches=$(xmlstarlet sel --novalid -t \
            -m "//intrinsic[contains(translate(category,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${lc}')]" \
            -v "@name" -o "|" -v "@tech" -o "|" -v "category[1]" -n "$IXML" 2>/dev/null)
        label="category"
    fi

    if [ -z "$matches" ]; then
        matches=$(xmlstarlet sel --novalid -t \
            -m "//intrinsic[contains(translate(description,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'${lc}')]" \
            -v "@name" -o "|" -v "@tech" -o "|" -v "category[1]" -n "$IXML" 2>/dev/null)
        label="definition"
    fi

    if [ -z "$matches" ]; then
        printf "${CK}No match for '%s'.${CR}\n" "$query"
        printf "Try:  doc simd list avx2\n      doc simd list avx512\n"
        return 1
    fi

    local count
    count=$(echo "$matches" | wc -l)
    if [ "$count" -eq 1 ]; then
        local single_name
        single_name=$(cut -d'|' -f1 <<< "$matches")
        { _print_intrinsic "$single_name"; _simd_decompose_name "$single_name"; } | less -RF
        return
    fi

    { _simd_concept "$query" "$label" "$lc" <<< "$matches"; } | less -RF
}

_print_intrinsic() {
    local name="$1"
    # xmlstarlet -o serializes as XML text: mangles raw ESC (0x1B) into
    # U+FFFD. Never embed ANSI color in a -o/-v template. Emit plain text
    # with a sentinel separator, colorize after in bash instead.
    local raw
    raw=$(xmlstarlet sel --novalid -t \
        -m "//intrinsic[@name='${name}']" \
        -o "@@SEP@@" -n \
        -o "Intrinsic  : " -v "@name" -n \
        -o "Tech       : " -v "@tech" -o "  CPUID: " -v "CPUID" -n \
        -o "Header     : " -v "header" -n \
        -o "Category   : " -v "category[1]" -n \
        -o "Return     : " -v "return/@type" -n \
        -m "parameter" -o "Param      : " -v "@type" -o "  " -v "@varname" -n -b \
        -o "ASM        : " -m "instruction" -v "@name" -o "  " -b -n \
        -o "Description: " -v "description" -n \
        -o "Operation  :" -n \
        -v "operation" -n \
        -o "@@SEP@@" -n \
        "$IXML" 2>/dev/null)

    local line
    while IFS= read -r line; do
        case "$line" in
            "@@SEP@@") printf "%s\n" "$SEP" ;;
            Intrinsic\ *)  printf "${CK}%s${CR}${CV}%s${CR}\n" "${line%%:*}:" "${line#*:}" ;;
            Category\ *)   printf "${CK}%s${CR}${CV}%s${CR}\n" "${line%%:*}:" "${line#*:}" ;;
            Tech\ *)
                local rest techval cpuval
                rest="${line#*: }"
                techval="${rest%%  CPUID:*}"
                cpuval="${rest##*CPUID: }"
                printf "${CK}Tech${CR}       : ${CV}%s${CR}  ${CK}CPUID${CR}: ${CV}%s${CR}\n" "$techval" "$cpuval"
                ;;
            ASM\ *)        printf "${CK}%s${CR}${CP}%s${CR}\n" "${line%%:*}:" "${line#*:}" ;;
            Header\ *|Return\ *|Param\ *|Operation\ *)
                printf "${CK}%s${CR}%s\n" "${line%%:*}:" "${line#*:}" ;;
            Description*)
                local label val labelw wfirst wline
                label="${line%%:*}:"
                val="${line#*: }"
                labelw=$((${#label} + 1))
                wfirst=1
                while IFS= read -r wline; do
                    if [ "$wfirst" -eq 1 ]; then
                        printf "${CK}%s${CR} %s\n" "$label" "$wline"
                        wfirst=0
                    else
                        printf "%*s%s\n" "$labelw" "" "$wline"
                    fi
                done < <(fold -s -w "$(_simd_budget "$labelw" 30)" <<< "$val")
                ;;
            *)
                while IFS= read -r wline; do
                    printf "${CD}%s${CR}\n" "$wline"
                done < <(fold -s -w "$TERM_COLS" <<< "$line")
                ;;
        esac
    done <<< "$raw"
}

# Same vector/func/suffix split as the concept breakdown, for one exact
# name -- "doc simd _mm_store_si128" gets the same treatment as "doc simd
# load" or "doc simd si128".
_simd_decompose_name() {
    local name="$1"
    local nm="${name#_}"
    local -a parts
    IFS='_' read -ra parts <<< "$nm"
    local n=${#parts[@]}
    local i=1 vector="${parts[0]}"
    if [[ ! "$vector" =~ ^mm(256|512)?$ ]]; then
        vector="(scalar)"
        i=0
    fi
    local mask=""
    if [ "${parts[$i]:-}" = "mask" ] || [ "${parts[$i]:-}" = "maskz" ]; then
        mask="${parts[$i]}"
        i=$((i + 1))
    fi
    local suffix="" opend=$((n - 1))
    if [ "$i" -le $((n - 1)) ]; then
        local last="${parts[$((n - 1))]}"
        _simd_is_suffix "$last" && { suffix="$last"; opend=$((n - 2)); }
    fi
    local optype="" j
    for ((j = i; j <= opend; j++)); do
        optype+="${optype:+_}${parts[$j]}"
    done
    [ -z "$optype" ] && optype="(base)"
    [ -n "$mask" ] && optype="${mask}_${optype}"

    printf "\n${CH}Decomposition${CR}\n"
    printf "  ${CK}vector${CR} : ${CV}%-10s${CR} ${CD}%s${CR}\n" \
        "$vector" "$(_simd_trunc "$(_simd_token_def "$vector")" "$(_simd_budget 30)")"
    printf "  ${CK}func${CR}   : ${CV}%-10s${CR} ${CD}%s${CR}\n" \
        "$(_simd_trunc "$optype" 10)" "$(_simd_trunc "$(_simd_mine_named "$name")" "$(_simd_budget 30)")"
    if [ -n "$suffix" ]; then
        printf "  ${CK}suffix${CR} : ${CV}%-10s${CR} ${CD}%s${CR}\n" \
            "$suffix" "$(_simd_trunc "$(_simd_token_def "$suffix")" "$(_simd_budget 30)")"
    fi
}

# ─── reg_doc ─────────────────────────────────────────────────────────────────
reg_doc() {
    local query="${1,,}"
    {
    case "$query" in
    rax|eax|ax|ah|al)
        cat <<'EOF'
━━━  RAX / EAX / AX / AH / AL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Accumulator
Widths
  RAX      64-bit   bits 63:0
  EAX      32-bit   bits 31:0  → writing EAX ZERO-EXTENDS RAX[63:32]
  AX       16-bit   bits 15:0  → write does NOT zero-extend upper bits
  AH        8-bit   bits 15:8  → inaccessible when REX prefix present
  AL        8-bit   bits  7:0
Implicit uses
  MUL/IMUL (64×64→128) : low 64 bits → RAX, high 64 bits → RDX
  DIV/IDIV             : RDX:RAX is the 128-bit dividend
  LODS / STOS / SCAS   : AL/AX/EAX/RAX is the accumulator
  CPUID                : leaf number in EAX on entry; results in EAX/EBX/ECX/EDX
  CMPXCHG              : comparand in AL/AX/EAX/RAX
  IN / OUT             : AL/AX/EAX for 8/16/32-bit I/O
  syscall (Linux)      : syscall number in RAX; return value in RAX
Calling convention (System V AMD64 — Linux/macOS/BSD)
  • Integer / pointer return value                (caller-saved)
  • 2nd return register for 128-bit returns: RDX:RAX
Calling convention (Windows x64)
  • Integer return value                          (volatile)
SIMD note : float/double return value is in XMM0, NOT RAX
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rbx|ebx|bx|bh|bl)
        cat <<'EOF'
━━━  RBX / EBX / BX / BH / BL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Base register (no fixed hardware role in x86-64)
Calling convention (System V AMD64)
  • Callee-saved (non-volatile) — MUST be preserved across CALL
Calling convention (Windows x64)
  • Callee-saved (non-volatile)
Common use : Saved loop counter / pointer across function calls
             CPUID: EBX is output register (CPU brand, feature bits)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rcx|ecx|cx|ch|cl)
        cat <<'EOF'
━━━  RCX / ECX / CX / CH / CL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Counter register
Implicit uses
  LOOP / LOOPE / LOOPNE   : decrements CX/ECX/RCX, branches if ≠ 0
  REP / REPE / REPNE      : iteration count in CX/ECX/RCX
  SHL/SHR/SAL/SAR/ROL/ROR : shift/rotate count in CL (low 8 bits)
  SHLD / SHRD             : shift count in CL
  SYSCALL                 : RCX ← return address (clobbered!)
Calling convention (System V AMD64)
  • 4th integer/pointer argument                  (caller-saved)
Calling convention (Windows x64)
  • 1st integer/pointer argument   ← different!   (volatile)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rdx|edx|dx|dh|dl)
        cat <<'EOF'
━━━  RDX / EDX / DX / DH / DL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Data register
Implicit uses
  MUL/IMUL (64×64→128) : high 64 bits → RDX
  DIV/IDIV             : RDX:RAX is 128-bit dividend; RDX ← remainder
  CQO                  : sign-extends RAX into RDX:RAX (64-bit)
  CDQ                  : sign-extends EAX into EDX:EAX (32-bit)
  IN/OUT dx, …         : DX = 16-bit I/O port address
  CPUID                : output register (feature flags)
Calling convention (System V AMD64)
  • 3rd integer/pointer argument                  (caller-saved)
  • 2nd return register (128-bit returns: RDX:RAX)
Calling convention (Windows x64)
  • 2nd integer/pointer argument   ← different!   (volatile)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rsi|esi|si|sil)
        cat <<'EOF'
━━━  RSI / ESI / SI / SIL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Source Index
Implicit uses
  MOVS / CMPS / LODS : source pointer (DS:[RSI]), auto-increments
Calling convention (System V AMD64)
  • 2nd integer/pointer argument                  (caller-saved)
Calling convention (Windows x64)
  • NOT an argument register                      (callee-saved!)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rdi|edi|di|dil)
        cat <<'EOF'
━━━  RDI / EDI / DI / DIL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Destination Index
Implicit uses
  MOVS / STOS / CMPS / SCAS : destination pointer (ES:[RDI]), auto-increments
Calling convention (System V AMD64)
  • 1st integer/pointer argument ("this" in C++ methods)  (caller-saved)
Calling convention (Windows x64)
  • NOT an argument register                              (callee-saved!)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rsp|esp|sp|spl)
        cat <<'EOF'
━━━  RSP / ESP / SP / SPL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Stack Pointer — always points to top of stack (lowest used addr)
Rules
  • Stack grows DOWNWARD — PUSH decrements RSP, POP increments
  • Alignment: RSP must be 16-byte aligned BEFORE a CALL instruction
    → inside callee prologue RSP % 16 == 8 (CALL pushed 8-byte return addr)
    → allocate stack space in multiples of 16: SUB RSP, 32
  • Red zone (System V): 128 bytes below RSP may be used by leaf functions
    without adjusting RSP (kernel/interrupt handlers must NOT use this)
  • Windows x64: caller must allocate 32-byte shadow space above ret addr
Implicit uses
  PUSH / POP    : RSP ±8
  CALL / RET    : push/pop RIP via RSP
  ENTER / LEAVE : manage RSP/RBP frame
Encoding note: RSP as ModRM base requires SIB byte (no [RSP] without it)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rbp|ebp|bp|bpl)
        cat <<'EOF'
━━━  RBP / EBP / BP / BPL  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Role       : Base Pointer / Frame Pointer
Calling convention
  • Callee-saved in BOTH System V and Windows x64
  • Frame pointer pattern (when -fno-omit-frame-pointer):
      push rbp        ; save caller's RBP
      mov  rbp, rsp   ; set frame base
      ...
      pop  rbp; ret
  • Omitting (-fomit-frame-pointer) frees RBP as general register;
    stack unwinding then uses .eh_frame / DWARF CFI instead
Implicit uses
  ENTER / LEAVE : set/restore RBP automatically
Encoding note: RBP as ModRM base requires disp8/disp32 (no zero-disp form)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    r8|r9|r10|r11|r12|r13|r14|r15| \
    r8d|r9d|r10d|r11d|r12d|r13d|r14d|r15d| \
    r8w|r9w|r10w|r11w|r12w|r13w|r14w|r15w| \
    r8b|r9b|r10b|r11b|r12b|r13b|r14b|r15b)
        cat <<'EOF'
━━━  R8 – R15  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Widths (example R8):
  R8    64-bit   full
  R8D   32-bit   low dword  → write ZERO-EXTENDS to 64 bits
  R8W   16-bit   low word   → write does NOT zero-extend
  R8B    8-bit   low byte

Calling convention (System V AMD64)
  R8,R9    – 5th, 6th integer arguments       (caller-saved)
  R10      – scratch / static chain pointer   (caller-saved)
  R11      – scratch                          (caller-saved)
  R12–R15  – callee-saved (non-volatile)

Calling convention (Windows x64)
  R8,R9    – 3rd, 4th integer arguments       (volatile)
  R10,R11  – volatile
  R12–R15  – non-volatile (callee-saved)

Encoding: all R8–R15 require REX prefix (1 extra byte per instruction)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    xmm|xmm[0-9]|xmm1[0-5])
        cat <<'EOF'
━━━  XMM0 – XMM15  (128-bit SSE registers)  ━━━━━━━━━━━━━━━━━━━━━━
Width      : 128 bits = 16 bytes = LOW 128 bits of YMM/ZMM
Lane layouts (all fit in one XMM)
  float32×4   _ps  (packed single)      ADDPS, MULPS, SQRTPS
  float64×2   _pd  (packed double)      ADDPD, MULPD
  float32×1   _ss  (scalar single)      ADDSS, SQRTSS
  float64×1   _sd  (scalar double)      ADDSD
  int8×16       PCMPEQB, PSHUFB, PADDB
  int16×8       PADDW, PMULLW, PCMPEQW
  int32×4       PADDD, PMULD, BLENDPS
  int64×2       PADDQ, PCMPEQQ
VEX hazard: Writing XMM via legacy SSE (no VEX) PRESERVES YMM upper bits
            → can cause "dirty upper" stall when mixing with AVX code
            Writing via VEX (VMOVAPS xmm0,…) ZEROES YMM/ZMM upper bits
Calling convention (System V AMD64)
  XMM0      – 1st FP argument AND FP return value
  XMM1–7    – 2nd–8th FP arguments
  XMM0–7    – caller-saved (volatile)
  XMM8–15   – caller-saved (volatile)   ← unlike Windows!
Calling convention (Windows x64)
  XMM0      – 1st FP argument / FP return
  XMM1–3    – 2nd–4th FP arguments
  XMM4–5    – volatile
  XMM6–15   – non-volatile (callee must save/restore with MOVDQA)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    ymm|ymm[0-9]|ymm1[0-5])
        cat <<'EOF'
━━━  YMM0 – YMM15  (256-bit AVX registers)  ━━━━━━━━━━━━━━━━━━━━━━
Width      : 256 bits = 32 bytes; YMM low 128 bits = XMM
Lane layouts
  float32×8   VADDPS ymm, ymm, ymm
  float64×4   VMULPD ymm, ymm, ymm
  int8×32     VPSHUFB, VPCMPEQB  (AVX2)
  int16×16    VPADDW, VPMULLW    (AVX2)
  int32×8     VPADDD, VPMULD     (AVX2)
  int64×4     VPADDQ, VPCMPEQQ   (AVX2)
VZEROUPPER  : MUST call before returning from AVX code to non-VEX code
              Failure causes ~70-150 cycle serialization penalty on Intel HSW/BDW
              AMD Zen: no such penalty (no dirty-upper state machine)
              Still good practice for portability
Availability: Intel Sandy Bridge (AVX float only) / Haswell (AVX2 integer)
              AMD Zen 1+ (AVX), Zen 2+ (AVX2 full width — Zen 1 split 256→2×128)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    zmm|zmm[0-9]|zmm[1-2][0-9]|zmm3[01])
        cat <<'EOF'
━━━  ZMM0 – ZMM31  (512-bit AVX-512 registers)  ━━━━━━━━━━━━━━━━━━
Width      : 512 bits = 64 bytes = one cache line on most modern CPUs
32 registers: ZMM0–31  (ZMM0–15 alias XMM/YMM; ZMM16–31 have no XMM/YMM alias)
Lane layouts
  float32×16 / float64×8 / int8×64 / int16×32 / int32×16 / int64×8
AVX-512 new features vs AVX2
  • Opmask registers k0–k7 for per-element masking / zeroing
      VADDPS zmm0 {k1},    zmm1, zmm2   ; merge-mask
      VADDPS zmm0 {k1}{z}, zmm1, zmm2   ; zero-mask
  • Embedded broadcast  [mem]{1to16}
  • Embedded rounding   {rn-sae} {rd-sae} {ru-sae} {rz-sae}
  • VPTERNLOGD (3-input ternary logic), VPCOMPRESSD, VPEXPANDD
Availability
  Intel: Skylake-X (2017), Ice Lake (2019), Tiger Lake, Alder Lake-P/H,
         Sapphire Rapids, Emerald Rapids
  AMD  : Zen 4 (Ryzen 7000 / 2022) ← your CPU has this!
         Zen 5 (Ryzen 9000 / 2024)
  NOT  : Alder Lake desktop (i9-12900K etc), Zen 1/2/3
Freq throttle (Intel only): first ZMM use may drop turbo ("license level 2")
  AMD Zen 4/5: no such throttling — full AVX-512 at full clock
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    rip|eip|ip)
        cat <<'EOF'
━━━  RIP  (Instruction Pointer)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Purpose    : Points to the NEXT instruction to execute
Direct write: impossible; only via JMP/CALL/RET/SYSCALL/SYSRET/IRET
RIP-relative addressing (x86-64 key feature)
  MOV rax, [rip + disp32]   ; access data ± 2 GB from current PC
  Used by: all PIC code (shared libs), GOT/PLT, string literals
  Assembler syntax (NASM):  mov rax, [rel myvar]
  Range: ±2 GB from the END of the instruction (not start)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    eflags|rflags|flags)
        cat <<'EOF'
━━━  RFLAGS / EFLAGS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Bit  Flag  Meaning / Set when
  0   CF   Carry — unsigned overflow, borrow, or bit shifted out
  2   PF   Parity — low byte of result has even number of 1 bits
  4   AF   Auxiliary carry — carry from bit 3 to 4 (BCD use)
  6   ZF   Zero — result == 0
  7   SF   Sign — result MSB == 1 (negative in two's complement)
  8   TF   Trap — single-step debug mode
  9   IF   Interrupt Enable — 1 = accept maskable interrupts
 10   DF   Direction — 0 = string ops increment SI/DI, 1 = decrement
 11   OF   Overflow — signed arithmetic overflow
 12-13 IOPL I/O privilege level
 16   RF   Resume — suppresses debug fault on next instruction
 18   AC   Alignment check (requires CR0.AM=1)
 21   ID   CPUID supported (can toggle this bit)

Common Jcc conditions
  JE/JZ    ZF=1    JNE/JNZ  ZF=0
  JL/JNGE  SF≠OF   JGE/JNL  SF=OF
  JB/JC    CF=1    JAE/JNC  CF=0
  JO       OF=1    JS       SF=1
  JP       PF=1    JNP      PF=0

Instructions that SET flags      : CMP TEST ADD SUB AND OR XOR INC DEC
Instructions that PRESERVE flags : MOV LEA PUSH POP XCHG
Instructions with PARTIAL effect : MUL sets CF/OF; SF/ZF/PF/AF undefined
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    mxcsr)
        cat <<'EOF'
━━━  MXCSR  (SSE Control/Status Register, 32-bit)  ━━━━━━━━━━━━━━━
Access     : LDMXCSR [mem32]  (load)  /  STMXCSR [mem32]  (store)
Bit  Name   Meaning
  0   IE    Invalid Op exception flag
  1   DE    Denormal exception flag
  2   ZE    Divide-by-zero exception flag
  3   OE    Overflow exception flag
  4   UE    Underflow exception flag
  5   PE    Precision (inexact) exception flag
  6   DAZ   Denormals Are Zero — treat subnormal inputs as +0.0
  7   IM    Invalid Op exception Mask (1 = suppress)
  8   DM    Denormal Mask
  9   ZM    Divide-by-zero Mask
 10   OM    Overflow Mask
 11   UM    Underflow Mask
 12   PM    Precision Mask
13-14 RC    Rounding Control: 00=nearest 01=down 10=up 11=truncate
 15   FZ    Flush to Zero — SSE underflows → +0.0 (no subnormal output)

Default    : 0x1F80  (all exceptions masked, round-to-nearest)
Performance: Set DAZ|FZ (0x8040 | 0x1F80 = 0x9FC0) for max FP speed
             when subnormals are acceptable (ML/audio/graphics)
             _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON)   // C intrinsic
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    k0|k1|k2|k3|k4|k5|k6|k7)
        cat <<'EOF'
━━━  k0 – k7  (AVX-512 Opmask Registers, 64-bit)  ━━━━━━━━━━━━━━━
Width  : 64 bits; effective bits = number of elements in the operation
         (64 for byte/int8, 32 for word/int16, 16 for dword/float32 …)
k0     : hardwired ALL-ONES — encoding k0 as writemask = no masking
Purpose: Per-element masking in AVX-512 instructions
  Merge-mask: VADDPS zmm0 {k1},    zmm1, zmm2  ; inactive lanes unchanged
  Zero-mask:  VADDPS zmm0 {k1}{z}, zmm1, zmm2  ; inactive lanes = 0
Manipulation
  KMOVB/W/D/Q  kN, reg/mem        ; move opmask ↔ GP / memory
  KANDW        kN, kA, kB         ; AND
  KORW         kN, kA, kB         ; OR
  KXORW        kN, kA, kB         ; XOR
  KNOTW        kN, kA             ; NOT
  KSHIFTLW/RW  kN, kA, imm8       ; shift
  KTESTW       kA, kB             ; ZF=1 if AND==0
  KORTESTW     kA, kB             ; CF=1 if OR==all-ones
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    list|all|"")
        cat <<'EOF'
━━━  x86-64 Register Summary  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
General-purpose (64/32/16/8-bit)        ABI role (System V / Windows x64)
  RAX EAX AX AL/AH   Accumulator        Return value / return value
  RBX EBX BX BL/BH   Base               Callee-saved / callee-saved
  RCX ECX CX CL/CH   Counter            4th arg / 1st arg
  RDX EDX DX DL/DH   Data               3rd arg / 2nd arg
  RSI ESI SI SIL      Source index       2nd arg / callee-saved
  RDI EDI DI DIL      Dest index         1st arg / callee-saved
  RSP ESP SP SPL      Stack pointer      (special — never clobber)
  RBP EBP BP BPL      Frame pointer      Callee-saved / callee-saved
  R8  R8D  R8W  R8B  Extra              5th arg / 3rd arg
  R9  R9D  R9W  R9B                     6th arg / 4th arg
  R10 R10D R10W R10B                    Caller-saved / volatile
  R11 R11D R11W R11B                    Caller-saved / volatile
  R12–R15 (D/W/B)                       Callee-saved / callee-saved

Special
  RIP               Instruction pointer (RIP-relative addressing)
  RFLAGS            Status flags: CF ZF SF OF PF AF DF IF

SIMD                                    Calling convention
  XMM0–15  128-bit  SSE baseline        XMM0 = FP return; XMM0-7 args (SysV)
  YMM0–15  256-bit  AVX/AVX2            = XMM + upper 128 bits
  ZMM0–31  512-bit  AVX-512             ZMM16–31 have no XMM/YMM alias
  k0–k7    64-bit   AVX-512 opmask      k0 = always-1 (not writable as mask)

FP / legacy (avoid in new code)
  ST(0)–ST(7)   80-bit x87 stack registers
  MM0–MM7       64-bit MMX (alias to x87 mantissa)

Control/debug
  CR0–CR8       Control registers (paging, protection, FPU control)
  DR0–DR7       Debug registers (hardware breakpoints/watchpoints)
  MXCSR         SSE control/status (rounding, DAZ/FZ, exception masks)

  doc reg <name>  for details on any register above
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    *)  printf "Unknown register: '%s'\nTry: doc reg list\n" "$1"; return 1 ;;
    esac
    } | less -RF
}

# ─── size_doc ─────────────────────────────────────────────────────────────────
size_doc() {
    local kw="${1,,}"
    {
    case "$kw" in
    byte|8|b)       cat <<'EOF'
━━━  BYTE  (8-bit)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 1 byte = 8 bits
Registers : AL BL CL DL  SIL DIL SPL BPL  R8B–R15B
PTR syntax: BYTE PTR [addr]   ; Intel / MASM
            byte [addr]       ; NASM
Ops
  MOV   AL,  BYTE PTR [rsi]
  MOVZX EAX, BYTE PTR [rsi]  ; zero-extend → 32 bits (and implicitly 64)
  MOVSX EAX, BYTE PTR [rsi]  ; sign-extend → 32 bits
  MOVSX RAX, BYTE PTR [rsi]  ; sign-extend → 64 bits
  CMP   BYTE PTR [rdi], 0
  ADD   BYTE PTR [mem], 1    ; 8-bit read-modify-write
Ranges  : unsigned 0–255   signed -128–127
Notes   : Writing AL does NOT zero-extend RAX (unlike writing EAX)
          AH is inaccessible when a REX prefix is present
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    word|16|w)      cat <<'EOF'
━━━  WORD  (16-bit)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 2 bytes = 16 bits
Registers : AX BX CX DX  SI DI SP BP  R8W–R15W
PTR syntax: WORD PTR [addr]  /  word [addr]  (NASM)
Ops
  MOV   AX,  WORD PTR [rsi]
  MOVZX EAX, WORD PTR [rsi]  ; zero-extend to 32/64 bits
  MOVSX EAX, WORD PTR [rsi]  ; sign-extend to 32 bits
  MOVSX RAX, WORD PTR [rsi]  ; sign-extend to 64 bits
Prefix    : 66h operand-size override selects 16-bit in 32/64-bit mode
            (extra byte; avoid in hot loops — can stall some decoders)
Use cases : UTF-16 chars, network fields, RGB565 pixels, PCM 16-bit audio
Ranges    : unsigned 0–65535   signed -32768–32767
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    dword|32|d)     cat <<'EOF'
━━━  DWORD  (32-bit / double-word)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 4 bytes = 32 bits
Registers : EAX EBX ECX EDX  ESI EDI ESP EBP  R8D–R15D
PTR syntax: DWORD PTR [addr]  /  dword [addr]  (NASM)
Zero-extend rule (critical!)
  Writing a 32-bit register ALWAYS zero-extends the full 64-bit register.
  MOV EAX, [rsi]  →  RAX[63:32] = 0 automatically. No MOVZX needed.
Ops
  MOV  EAX, DWORD PTR [rsi]  ; implicit zero-extend into RAX
  MOVSX RAX, DWORD PTR [rsi] ; sign-extend 32→64
  MOV  DWORD PTR [rdi], 0
  VMOVD xmm0, eax            ; 32-bit scalar → XMM lane 0
  VPBROADCASTD ymm0, eax     ; broadcast int32 to all 8 lanes
Use cases : Loop indices, pixel values (RGBA8888), IPv4 addresses
Ranges    : unsigned 0–4294967295   signed -2147483648–2147483647
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    qword|64|q)     cat <<'EOF'
━━━  QWORD  (64-bit / quad-word)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 8 bytes = 64 bits
Registers : RAX RBX RCX RDX  RSI RDI RSP RBP  R8–R15
PTR syntax: QWORD PTR [addr]  /  qword [addr]  (NASM)
Ops
  MOV  RAX, QWORD PTR [rsi]
  MOV  QWORD PTR [rdi], rax
  MOVQ xmm0, rax             ; integer 64-bit → XMM lane 0
  MOVQ xmm0, QWORD PTR [mem] ; load 64 bits into XMM low half
  MOVSD xmm0, QWORD PTR [mem]; load double into XMM scalar
  VPBROADCASTQ ymm0, [mem]   ; broadcast float64/int64 to all 4 lanes
Use cases : Pointers (all 64-bit pointers), counters, double-prec FP,
            file sizes, timestamps, hash values
Ranges    : unsigned 0–18446744073709551615   signed ±9.2×10¹⁸
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    xmmword|oword|128) cat <<'EOF'
━━━  XMMWORD  (128-bit)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 16 bytes = 128 bits
Registers : XMM0–XMM15
PTR syntax: XMMWORD PTR [addr]  /  oword [addr]  (NASM)
Alignment : 16-byte boundary required for *A variants (MOVAPS, MOVDQA)
            unaligned faults at runtime — use alignas(16) / .align 16
Ops
  MOVAPS  xmm0, [aligned16]   ; aligned float32×4
  MOVUPS  xmm0, [any]         ; unaligned (same speed if data aligned on modern CPUs)
  MOVDQA  xmm0, [aligned16]   ; aligned integer
  MOVDQU  xmm0, [any]         ; unaligned integer
  VMOVDQA xmm0, [aligned16]   ; VEX-encoded → zeroes YMM upper bits
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    ymmword|256)    cat <<'EOF'
━━━  YMMWORD  (256-bit)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 32 bytes = 256 bits
Registers : YMM0–YMM15
PTR syntax: YMMWORD PTR [addr]  /  yword [addr]  (NASM)
Alignment : 32-byte for *A variants  →  alignas(32) / .align 32
Ops
  VMOVAPS ymm0, [aligned32]
  VMOVUPS ymm0, [any]
  VMOVDQA ymm0, [aligned32]
  VMOVDQU ymm0, [any]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    zmmword|512)    cat <<'EOF'
━━━  ZMMWORD  (512-bit)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Size      : 64 bytes = 512 bits = one cache line
Registers : ZMM0–ZMM31
PTR syntax: ZMMWORD PTR [addr]  /  zword [addr]  (NASM)
Alignment : 64-byte for *A variants  →  alignas(64) / .align 64
Ops
  VMOVAPS zmm0, [aligned64]
  VMOVUPS zmm0, [any]
  VMOVDQA64 zmm0, [aligned64]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    ptr|list|all|"") cat <<'EOF'
━━━  x86 Memory Transfer Sizes  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Keyword        Bits  Bytes  Registers         Align  NASM
──────────────────────────────────────────────────────────────────
BYTE PTR          8      1  AL/BL/R8B…           1  byte
WORD PTR         16      2  AX/BX/R8W…           2  word
DWORD PTR        32      4  EAX/EBX/R8D…         4  dword
QWORD PTR        64      8  RAX/RBX/R8…          8  qword
TBYTE PTR        80     10  ST(0)–ST(7)          16  tword  (x87)
XMMWORD PTR     128     16  XMM0–15             16  oword  (SSE)
YMMWORD PTR     256     32  YMM0–15             32  yword  (AVX)
ZMMWORD PTR     512     64  ZMM0–31             64  zword  (AVX-512)

Zero-extend rules (critical for correctness)
  8-bit  write → NO  zero-extension of enclosing register
  16-bit write → NO  zero-extension
  32-bit write → YES zero-extends bits 63:32 automatically
  64-bit write → full 64-bit register set

doc size <keyword>  for details on any row
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    *)  printf "Unknown size: '%s'\nTry: doc size list\n" "$1"; return 1 ;;
    esac
    } | less -RF
}

# ─── vec_doc ──────────────────────────────────────────────────────────────────
vec_doc() {
    local topic="${1,,}"
    {
    case "$topic" in
    intro|overview|"") cat <<'EOF'
━━━  x86 Vectorization Overview  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ISA Timeline
  MMX      1997   64-bit integer only (aliased x87 — avoid)
  SSE      1999  128-bit XMM0–7, float32 scalar+packed
  SSE2     2001  128-bit + float64 + int8/16/32/64 packed (x86-64 baseline)
  SSE3     2004  LDDQU HADD HSUB MOVSLDUP
  SSSE3    2007  PSHUFB PMULHRSW PALIGNR
  SSE4.1   2007  BLENDPS DPPS INSERTPS PMULLD
  SSE4.2   2008  PCMPESTRI string ops, CRC32, POPCNT
  AVX      2011  256-bit YMM0–15, float32/64 only, VEX prefix, 3-operand
  AVX2     2013  256-bit integer, VGATHER, VPERMD, VPBROADCAST
  FMA3     2013  fused multiply-add VFMADD*/VFMSUB* (1 rounding step)
  AVX-512F 2016  512-bit ZMM0–31, opmask k0–k7, EVEX prefix
  AVX-512BW/DQ/VL/VNNI/VBMI…  (subsets)
  AVX-VNNI 2021  int8/16 dot product on XMM/YMM (Alder Lake, Zen4)
  AVX10.1  2024  convergence ISA (unified AVX-512 subset)
  ✓ Your Ryzen 7000 (Zen4) supports: SSE* AVX AVX2 FMA3 AVX-512F/BW/DQ/VL/VNNI

Subtopics
  doc vec sse        SSE/SSE2 instruction cheatsheet
  doc vec avx        AVX/AVX2 cheatsheet
  doc vec avx512     AVX-512 cheatsheet
  doc vec fma        FMA3 patterns
  doc vec gather     gather/scatter
  doc vec alignment  alignment rules + VZEROUPPER
  doc vec prefetch   software prefetch
  doc vec intrinsics finding intrinsics + naming convention
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    sse*) cat <<'EOF'
━━━  SSE / SSE2 / SSE3 / SSE4 Cheatsheet  ━━━━━━━━━━━━━━━━━━━━━━━
Registers  : XMM0–15  (128-bit)
Types:  _ps float32×4  _pd float64×2  _ss float32×1  _sd float64×1
        _epi8×16  _epi16×8  _epi32×4  _epi64×2
Float ops   : ADDPS SUBPS MULPS DIVPS SQRTPS RCPPS RSQRTPS MINPS MAXPS
              CMPPS (predicate imm8)  ANDPS ORPS XORPS ANDNPS
Integer ops : PADDB/W/D/Q  PSUBB/W/D/Q  PMULLW PMULHW
              PCMPEQB/W/D  PCMPGTB/W/D
              PAND POR PXOR PANDN
              PSHUFB (SSSE3)  PSHUFD  PUNPCKLBW/WD/DQ  PUNPCKHBW/WD/DQ
              PBLENDW (SSE4.1)  PINSRD/Q (SSE4.1)  PEXTRD/Q (SSE4.1)
              PMULLD int32×4 (SSE4.1)
Load/store  : MOVAPS/MOVUPS  MOVDQA/MOVDQU  MOVD/MOVQ  MOVNTPS/MOVNTDQ
Convert     : CVTDQ2PS/CVTPS2DQ  CVTSI2SS  CVTTPS2DQ (truncate)
              CVTSD2SS  CVTSS2SD
String ops  : PCMPESTRI/PCMPISTR* (SSE4.2)  CRC32 (SSE4.2)
Tips
  RCPPS/RSQRTPS are ~12-bit approximations; refine with Newton-Raphson
  CVTTPS2DQ truncates; CVTPS2DQ rounds (per MXCSR.RC)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    avx|avx2) cat <<'EOF'
━━━  AVX / AVX2 Cheatsheet  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Registers  : YMM0–15  (256-bit)  /  XMM0–15  (128-bit via VEX)
3-operand  : VADDPS ymm0, ymm1, ymm2  ; ymm0=ymm1+ymm2  (non-destructive)
VZEROUPPER : call before returning to non-VEX code (Intel only penalty;
             AMD Zen has no dirty-upper state, but good practice)
Float256   : VADDPS VSUBPS VMULPS VDIVPS VSQRTPS VMINPS VMAXPS
             VBLENDPS VBLENDVPS VPERMILPS VPERM2F128
             VINSERTF128  VEXTRACTF128
             VBROADCASTSS/SD  (scalar → all lanes)
Int256 (AVX2)
  VPADDB/W/D/Q  VPSUBB/W/D/Q  VPMULLW VPMULLD
  VPAND VPOR VPXOR
  VPCMPEQB/W/D/Q  VPCMPGTB/W/D/Q
  VPSHUFB VPSHUFD  VPBLENDD
  VPERMD VPERMPS  (cross-lane permute — higher latency)
  VPBROADCASTB/W/D/Q  (broadcast element → all lanes)
  VINSERTI128 VEXTRACTI128
  VGATHERDPS/VGATHERQPS/VPGATHERDD…  (gather — see doc vec gather)
Conversion  : VCVTDQ2PS VCVTPS2DQ  (int32↔float32, 8 elements)
              VCVTPD2DQ VCVTDQ2PD  (float64↔int32, lane narrowing/widening)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    avx512|avx-512) cat <<'EOF'
━━━  AVX-512 Cheatsheet  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Registers  : ZMM0–31 (512-bit) + k0–k7 (opmask)
Prefix     : EVEX (4 bytes mandatory)
EVEX features
  1. Opmask  VADDPS zmm0 {k1}, zmm1, zmm2     ; merge-mask
             VADDPS zmm0 {k1}{z}, zmm1, zmm2  ; zero-mask
  2. Broadcast  VADDPS zmm0, zmm1, [mem]{1to16}
  3. Rounding   VADDPS zmm0, zmm1, zmm2 {rn-sae}
Key new instructions
  VPTERNLOGD zmm, zmm, zmm, imm8   ; 3-input ternary bitwise
  VPERMI2PS  zmm, zmm, zmm         ; cross-register permute
  VPCOMPRESSD zmm {k1}, zmm        ; compress masked lanes
  VPEXPANDD   zmm {k1}, zmm        ; expand to masked lanes
  VPDPBUSD    zmm, zmm, zmm        ; int8 dot product (VNNI)
Zen4 AVX-512 notes
  ✓ Full AVX-512F/BW/DQ/VL/VNNI — no frequency throttling
  ✓ EVEX instructions are native width (not micro-op pairs like early Intel)
  Port usage: FP01 FP23 FP45 (float/int units)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    fma|fma3) cat <<'EOF'
━━━  FMA3  (Fused Multiply-Add)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Available  : Intel Haswell+ / AMD Piledriver+ (Zen always)
Width      : XMM (128) / YMM (256) / ZMM (512)
Types      : _PS _PD (packed) / _SS _SD (scalar)
Variants   : 132  dst = dst * src2 + src3
             213  dst = src2 * dst + src3    ← most natural
             231  dst = src2 * src3 + dst    ← accumulator form
Names
  VFMADD*   a*b + c    VFMSUB*   a*b - c
  VFNMADD*  -a*b + c   VFNMSUB*  -a*b - c
Examples
  VFMADD213PS ymm0, ymm1, ymm2  ; ymm0 = ymm1*ymm0 + ymm2
  VFMADD231PS ymm0, ymm1, [rsi] ; ymm0 += ymm1 * [mem]  (accumulate)
Zen4 perf   : 2 FMA units → 2 VFMADDPS/cycle (YMM=16 FLOPs/cycle, ZMM=32)
Precision   : ONE rounding (vs TWO for separate MUL+ADD) → more accurate
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    gather|scatter) cat <<'EOF'
━━━  Gather / Scatter  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Gather: load from non-contiguous addresses stored in a SIMD register
Scatter (AVX-512 only): store to non-contiguous addresses
AVX2 gather (legacy — tricky self-mask)
  VGATHERDPS xmm1, [base + xmm2*scale], xmm3  ; xmm3=mask (modified!)
  Initialize mask to all-ones; hardware clears bits as elements load
AVX-512 gather (k-mask — cleaner)
  VGATHERDPS zmm0 {k1}, [base + zmm2*4]  ; k1 cleared per element
  Init k1 = 0xFFFF before loop; after: k1==0 means done
AVX-512 scatter
  VSCATTERDPS [base + zmm_idx*4] {k1}, zmm0
Performance
  Each element = potential cache miss; latency ~20–40 cycles
  Sequential loads beat gather when stride ≤ 2× vector width
  AoS → SoA restructuring often eliminates the need entirely
  Zen4 gather throughput: measurably better than Skylake
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    alignment|align|vzeroupper) cat <<'EOF'
━━━  Alignment + VZEROUPPER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Alignment requirements
  XMM  16-byte for MOVAPS/MOVDQA  (fault at runtime if unaligned data)
  YMM  32-byte for VMOVAPS/VMOVDQA
  ZMM  64-byte for VMOVAPS/VMOVDQA64
Modern rule: *U/*DQU variants have identical speed to *A when data IS
aligned (Nehalem+). Use VMOVDQU freely; use VMOVDQA when alignment is
guaranteed (documents intent, catches bugs early).

C alignment
  alignas(32) float buf[256];             // stack
  float* p = aligned_alloc(32, n*4);     // heap
  // or: posix_memalign(&p, 32, n*4)

VZEROUPPER
  Problem: legacy SSE write to XMM leaves YMM upper 128 bits "dirty"
  On Intel SNB/IVB/HSW/BDW: mixing VEX and non-VEX on dirty regs = stall
  Fix: VZEROUPPER before any call site that may use legacy SSE
  AMD Zen: no dirty-upper machine (no penalty) — but still good practice
  VZEROALL: zeros full YMM (slower); use only when entering a fresh AVX kernel

Non-temporal stores
  VMOVNTPS [aligned], ymm  ; bypass L1/L2, goes to write-combine buffer
  SFENCE required after NT stores before other threads can observe
  Alignment: 32-byte (YMM) or 64-byte (ZMM) mandatory
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    prefetch) cat <<'EOF'
━━━  Software Prefetch  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PREFETCHT0  [addr]  → L1 + L2 + L3
PREFETCHT1  [addr]  → L2 + L3
PREFETCHT2  [addr]  → L3 only
PREFETCHNTA [addr]  → L1 only, minimal cache pollution
PREFETCHW   [addr]  → prefetch for write (takes exclusive ownership)

Rule of thumb: prefetch N iterations ahead where
  N ≈ L3_latency_cycles / loop_body_cycles
  Zen4: L3 ~40 cycles; if loop body = 4 cycles → prefetch 10 ahead

C intrinsic: __builtin_prefetch(ptr, rw, locality)
  rw:        0=read, 1=write
  locality:  0=NTA, 1=T2, 2=T1, 3=T0

When NOT to bother
  HW prefetcher handles regular strides well (stride 1 always, stride 2+
  usually). SW prefetch helps for: irregular access, pointer chasing,
  random-ish indexed access with bounded working set.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    intrinsics|intel) cat <<'EOF'
━━━  Intel Intrinsics Reference  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Online    : https://www.intel.com/content/www/us/en/docs/intrinsics-guide/
            (filter by ISA, data type, operation)
Naming    : _mm<width>_<op>_<type>
  width   : (blank)=128 XMM   256=YMM   512=ZMM
  op      : add sub mul div sqrt load store set blend permute ...
  type    : ps=float32  pd=float64
            epi8/16/32/64=signed int  epu8/16/32=unsigned int  si128=raw
Examples
  __m128  _mm_add_ps(__m128 a, __m128 b)
  __m256  _mm256_add_ps(__m256 a, __m256 b)
  __m512  _mm512_add_ps(__m512 a, __m512 b)
  __m256i _mm256_add_epi32(__m256i a, __m256i b)
  __m256  _mm256_fmadd_ps(__m256 a, __m256 b, __m256 c)
  __m512  _mm512_mask_add_ps(__m512 src, __mmask16 k, __m512 a, __m512 b)
Header    : #include <immintrin.h>   // covers all: SSE* AVX* FMA AVX-512
Compiler flags
  GCC/Clang: -mavx2 -mfma -mavx512f -mavx512vl -mavx512bw -mavx512dq
             -march=znver4   // tune for Zen 4 (enables all supported ISAs)
  MSVC:      /arch:AVX2  (no fine-grained control for AVX-512 on MSVC)
Runtime detect
  __builtin_cpu_supports("avx2")
  __builtin_cpu_supports("avx512f")
Perf references
  uops.info      https://uops.info          (latency/throughput, Zen4 included)
  Agner Fog      https://agner.org/optimize (PDFs, authoritative)
  godbolt.org    compiler output + analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        ;;
    *)
        printf "Unknown vec topic: '%s'\n" "$1"
        printf "Topics: intro  sse  avx  avx2  avx512  fma  gather  alignment  prefetch  intrinsics\n"
        return 1
        ;;
    esac
    } | less -RF
}

# ─── dispatch ────────────────────────────────────────────────────────────────
# parse --arch
while [[ "$1" == --* ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

[ $# -lt 1 ] && usage

case "$1" in
    help|--help|-h)  usage ;;
    update)          do_update "${2:-all}" ;;
    arch)            do_arch ;;
    asm)
        [ $# -lt 2 ] && usage
        case "${2,,}" in
            # sub-commands
            reg)                          reg_doc "${3:-list}" ;;
            size)                         size_doc "${3:-list}" ;;
            # register names → reg_doc
            rax|eax|ax|ah|al|             rbx|ebx|bx|bh|bl|             rcx|ecx|cx|ch|cl|             rdx|edx|dx|dh|dl|             rsi|esi|si|sil|             rdi|edi|di|dil|             rsp|esp|sp|spl|             rbp|ebp|bp|bpl|             r8|r9|r10|r11|r12|r13|r14|r15|             r8d|r9d|r10d|r11d|r12d|r13d|r14d|r15d|             r8w|r9w|r10w|r11w|r12w|r13w|r14w|r15w|             r8b|r9b|r10b|r11b|r12b|r13b|r14b|r15b|             rip|eip|ip|rflags|eflags|flags|mxcsr|             xmm|ymm|zmm|             xmm[0-9]|xmm1[0-5]|             ymm[0-9]|ymm1[0-5]|             zmm[0-9]|zmm1[0-9]|zmm2[0-9]|zmm3[01]|             k0|k1|k2|k3|k4|k5|k6|k7|             mm0|mm1|mm2|mm3|mm4|mm5|mm6|mm7|             st|"st(0)"|"st(1)"|"st(2)"|"st(3)"|"st(4)"|"st(5)"|"st(6)"|"st(7)"|             cr0|cr2|cr3|cr4|cr8|dr0|dr1|dr2|dr3|dr6|dr7|             list|all)                     reg_doc "${2,,}" ;;
            # size keywords → size_doc
            byte|word|dword|qword|             xmmword|ymmword|zmmword|             oword|tbyte|tword|ptr|             8|16|32|64|128|256|512)       size_doc "${2,,}" ;;
            # everything else → instruction lookup
            *)                            x86doc "$2" ;;
        esac
        ;;
    simd)
        [ $# -lt 2 ] && usage
        case "$2" in
            vec)     vec_doc "${3:-intro}" ;;
            *)       simd_doc "$2" "$3" "$4" ;;
        esac
        ;;
    cpp)             [ $# -lt 2 ] && usage; cppman "$2" ;;
    *)               printf "Unknown category: '%s'\n" "$1"; usage ;;
esac

