#!/usr/bin/env bash
#
# watchcub - one-command system tuning + run-condition logging for benchmarks
# ----------------------------------------------------------------------------
#   sudo ./watchcub.sh status                  show current settings (read-only)
#   ./watchcub.sh cpu                          topology: cache/NUMA layout (read-only)
#   ./watchcub.sh core                         per-thread usage/freq/governor snapshot (read-only)
#   sudo ./watchcub.sh bench   [flags]         save state + apply perf profile
#   sudo ./watchcub.sh verify  [flags]         pre-flight: fit to benchmark?
#   sudo ./watchcub.sh run [flags] -- CMD...   run CMD, sample, log + report
#   sudo ./watchcub.sh restore                 revert everything saved
#   ./watchcub.sh profile new [path]           write an editable profile file
#   ./watchcub.sh profile show [flags]         print the effective config
#   sudo ./watchcub.sh trace-unlock|trace-lock loosen/retighten perf sysctls
#
# Config precedence (highest wins):
#   CLI flags  >  profile file  >  WATCHCUB_<KEY> env vars  >  built-in defaults
# Profile file: --profile PATH | -p PATH, or $WATCHCUB_PROFILE. Never
# auto-loaded; no file given = built-in defaults.
#
# Flags (each maps to a profile key of the same name; --profile picks the file):
#   --turbo=keep|off       --pinfreq=on|off      --pinfreq-target=max|<kHz>
#   --cstate=hold|keep     --smt=keep|off        --thp=always|never|keep
#   --thp-defrag=never|always|madvise|keep
#   --governor=<gov>|keep  --epp=<epp>|keep
#   --swappiness=<n>|keep  --numa-balancing=<n>|keep
#   --aslr=<0|1|2>|keep    --nmi-watchdog=<n>|keep
#   --drop-caches=on|off
#   --nvidia-persist=on|off|keep  --nvidia-clock=max|keep
#   --amdgpu-perf=<level>|keep    --rocm-perf=<level>|keep
#   --temp-warn=<C>       --mem-max=<pct>       --load-max=<frac>
#   --swap-max=<kB>        --dirty-max=<kB>      --freq-dip=<frac>
#   --sample=<sec>         --logs=<dir>          --state=<dir>
#   --profile=<file> | -p <file>
#   --paranoid=<N>       (trace-unlock only) set perf_event_paranoid instead of default -1
#
# Pure bash + /proc + /sys, everything feature-detected. Handles intel_pstate,
# amd-pstate(-epp), acpi-cpufreq. AMD: no thermal_throttle counters, so
# throttling = hwmon temp + freq-dip check; min-freq pin reads
# scaling_max_freq AFTER the boost decision.
set -u

CPU_SYS=/sys/devices/system/cpu

# ===================================================== configuration ========
# keys + defaults + docs; every key here works as a flag/env var
CFG_KEYS=(TURBO PINFREQ PINFREQ_TARGET CSTATE SMT THP THP_DEFRAG GOVERNOR EPP
          SWAPPINESS NUMA_BALANCING ASLR NMI_WATCHDOG DROP_CACHES
          NVIDIA_PERSIST NVIDIA_CLOCK AMDGPU_PERF ROCM_PERF
          TEMP_WARN MEM_MAX LOAD_MAX SWAP_MAX DIRTY_MAX FREQ_DIP SAMPLE LOGS STATE)
# subset apply_bench() actually writes - the only keys a profile file may
# set; 'profile new' generates from this, keep in sync with apply_bench()
BENCH_KEYS=(TURBO PINFREQ PINFREQ_TARGET CSTATE SMT THP THP_DEFRAG GOVERNOR EPP
            SWAPPINESS NUMA_BALANCING ASLR NMI_WATCHDOG DROP_CACHES
            NVIDIA_PERSIST NVIDIA_CLOCK AMDGPU_PERF ROCM_PERF STATE)
declare -A CFG=(
  [TURBO]=keep   [PINFREQ]=on   [PINFREQ_TARGET]=max   [CSTATE]=hold  [SMT]=keep
  [THP]=always   [THP_DEFRAG]=never
  [GOVERNOR]=performance [EPP]=performance
  [SWAPPINESS]=1 [NUMA_BALANCING]=0 [ASLR]=0 [NMI_WATCHDOG]=0
  [DROP_CACHES]=on
  [NVIDIA_PERSIST]=on [NVIDIA_CLOCK]=max [AMDGPU_PERF]=high [ROCM_PERF]=high
  [TEMP_WARN]=65 [MEM_MAX]=40   [LOAD_MAX]=0.05
  [SWAP_MAX]=65536 [DIRTY_MAX]=102400 [FREQ_DIP]=0.97 [SAMPLE]=0.5
  [LOGS]=/var/tmp/watchcub-logs [STATE]=/var/tmp/watchcub-state
)
declare -A CFG_DOC=(
  [TURBO]="keep = full boost clocks (highest perf). off = fixed base clock (max reproducibility)"
  [PINFREQ]="on = floor ALL cores at PINFREQ_TARGET (all-core throughput). off = idle cores idle (max single-core boost)"
  [PINFREQ_TARGET]="max = pin to scaling_max_freq, or a kHz number. Used only when PINFREQ=on"
  [CSTATE]="hold = block deep C-states (lowest wake latency). keep = allow CC6 (frees single-core boost budget on Zen)"
  [SMT]="keep = leave hyperthreading as-is. off = disable SMT for the session"
  [THP]="always | never | keep. Transparent hugepages mode"
  [THP_DEFRAG]="never | always | madvise | keep. Transparent hugepages defrag mode"
  [GOVERNOR]="cpufreq governor for every policy, or keep to leave as-is"
  [EPP]="energy_performance_preference for every policy, or keep to leave as-is"
  [SWAPPINESS]="vm.swappiness value, or keep to leave as-is"
  [NUMA_BALANCING]="kernel.numa_balancing value, or keep to leave as-is"
  [ASLR]="kernel.randomize_va_space value (0/1/2), or keep to leave as-is"
  [NMI_WATCHDOG]="kernel.nmi_watchdog value, or keep to leave as-is"
  [DROP_CACHES]="on = drop page cache once before bench. off = leave cache as-is"
  [NVIDIA_PERSIST]="on|off|keep. NVIDIA persistence mode (nvidia-smi -pm)"
  [NVIDIA_CLOCK]="max = lock SM+mem clocks to their max. keep = leave clocks as-is"
  [AMDGPU_PERF]="value for power_dpm_force_performance_level (e.g. high, auto), or keep"
  [ROCM_PERF]="value for rocm-smi --setperflevel (e.g. high, auto), or keep"
  [TEMP_WARN]="C. verify/run warn when hottest sensor reaches this"
  [MEM_MAX]="percent. verify warns when used RAM exceeds this"
  [LOAD_MAX]="fraction of nproc. verify warns when 1-min load exceeds this"
  [SWAP_MAX]="kB. verify warns when swap in use exceeds this"
  [DIRTY_MAX]="kB. verify warns when dirty pages exceed this"
  [FREQ_DIP]="fraction. run warns when benchmark core dips below this x its max"
  [SAMPLE]="seconds. freq/temp sampling interval during run"
  [LOGS]="dir. run log output directory (--logs=DIR / WATCHCUB_LOGS)"
  [STATE]="dir. bench state save directory (--state=DIR / WATCHCUB_STATE)"
)
STATE_DIR="${WATCHCUB_STATE:-/var/tmp/watchcub-state}"
LOG_ROOT="${WATCHCUB_LOGS:-/var/tmp/watchcub-logs}"
PROFILE_FILE="${WATCHCUB_PROFILE:-}"
PROFILE_SOURCE="defaults"

cfg_valid() {  # <key> <value> - enum validation, numbers pass through
    case "$1" in
      TURBO)   case "$2" in keep|off) return 0;; esac;;
      PINFREQ) case "$2" in on|off) return 0;; esac;;
      CSTATE)  case "$2" in hold|keep) return 0;; esac;;
      SMT)     case "$2" in keep|off) return 0;; esac;;
      THP)     case "$2" in always|never|keep) return 0;; esac;;
      THP_DEFRAG) case "$2" in never|always|madvise|keep) return 0;; esac;;
      DROP_CACHES) case "$2" in on|off) return 0;; esac;;
      NVIDIA_PERSIST) case "$2" in on|off|keep) return 0;; esac;;
      *)       return 0;;
    esac; return 1
}
cfg_set() {  # <key> <value> <origin>
    cfg_valid "$1" "$2" || { echo "Invalid value '$2' for $1 ($3)" >&2; exit 1; }
    CFG[$1]=$2
}
apply_env() { local k v
    for k in "${CFG_KEYS[@]}"; do v="WATCHCUB_$k"
        [ -n "${!v:-}" ] && cfg_set "$k" "${!v}" "env $v"; done; }
load_profile() {  # <file>
    [ -r "$1" ] || { echo "Profile file not readable: $1" >&2; exit 1; }
    PROFILE_SOURCE="$1"
    local line k v
    while IFS= read -r line; do
        line="${line%%#*}"                       # strip comments
        line="$(echo "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        k=${line%%=*}; v=${line#*=}
        case " ${BENCH_KEYS[*]} " in *" $k "*) cfg_set "$k" "$v" "profile $1";;
            *) echo "Not a bench setting: '$k' in $1 (ignored - use a flag or WATCHCUB_$k instead)" >&2;; esac
    done < "$1"
}
finalize_cfg() {
    apply_env
    [ -n "$PROFILE_FILE" ] && load_profile "$PROFILE_FILE"
    local k; for k in "${!CLI_CFG[@]}"; do cfg_set "$k" "${CLI_CFG[$k]}" "flag"; done
    LOG_ROOT=${CFG[LOGS]}; STATE_DIR=${CFG[STATE]}
    # short names used in the script body
    TURBO_MODE=${CFG[TURBO]};   PINFREQ_MODE=${CFG[PINFREQ]}
    CSTATE_MODE=${CFG[CSTATE]}; SMT_MODE=${CFG[SMT]}; THP_MODE=${CFG[THP]}
    GOVERNOR_MODE=${CFG[GOVERNOR]}; EPP_MODE=${CFG[EPP]}
    PINFREQ_TARGET_VAL=${CFG[PINFREQ_TARGET]}; THP_DEFRAG_MODE=${CFG[THP_DEFRAG]}
    SWAPPINESS_VAL=${CFG[SWAPPINESS]}; NUMA_BALANCING_VAL=${CFG[NUMA_BALANCING]}
    ASLR_VAL=${CFG[ASLR]}; NMI_WATCHDOG_VAL=${CFG[NMI_WATCHDOG]}
    DROP_CACHES_MODE=${CFG[DROP_CACHES]}
    NVIDIA_PERSIST_MODE=${CFG[NVIDIA_PERSIST]}; NVIDIA_CLOCK_MODE=${CFG[NVIDIA_CLOCK]}
    AMDGPU_PERF_VAL=${CFG[AMDGPU_PERF]}; ROCM_PERF_VAL=${CFG[ROCM_PERF]}
    TEMP_WARN_C=${CFG[TEMP_WARN]}; TEMP_WARN=$(( TEMP_WARN_C * 1000 ))
    MEM_MAX_USED_PCT=${CFG[MEM_MAX]}; LOAD_MAX_FRAC=${CFG[LOAD_MAX]}
    SWAP_MAX_KB=${CFG[SWAP_MAX]};     DIRTY_MAX_KB=${CFG[DIRTY_MAX]}
    FREQ_DIP_FRAC=${CFG[FREQ_DIP]};   SAMPLE_INT=${CFG[SAMPLE]}
}
cfg_summary() { local k s=""
    for k in "${CFG_KEYS[@]}"; do s+="$k=${CFG[$k]} "; done; echo "$s(source: $PROFILE_SOURCE)"; }

# ============================================================ helpers =======
log()  { printf '  %-44s %s\n' "$1" "$2"; }
info() { printf '\n== %s ==\n' "$1"; }
pass() { printf '  [ OK ] %s\n' "$1"; }
warnl(){ printf '  [WARN] %s\n' "$1"; WARNS=$((WARNS+1)); }
have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "Needs root; use sudo." >&2; exit 1; }; }
rd()   { cat "$1" 2>/dev/null; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

action_log() { mkdir -p "$LOG_ROOT"
    exec > >(tee -a "$LOG_ROOT/actions.log") 2>&1
    printf '\n#### %s :: %s ####\n' "$(ts)" "$1"; }

save_write() {  # <file> <value> <key>  - returns 0 if written, 1 if rejected/absent
    local f=$1 val=$2 key=$3
    [ -e "$f" ] || return 1
    [ -r "$f" ] && [ ! -e "$STATE_DIR/$key" ] && cat "$f" > "$STATE_DIR/$key" 2>/dev/null
    if echo "$val" > "$f" 2>/dev/null; then log "$f" "-> $val"; return 0
    else log "$f" "-> $val FAILED (kernel rejected write)"; return 1; fi
}
restore_write() {  # <file> <key>
    local f=$1 key=$2
    [ -e "$STATE_DIR/$key" ] && [ -e "$f" ] || return 0
    local v; v=$(cat "$STATE_DIR/$key")
    echo "$v" > "$f" 2>/dev/null && log "$f" "-> $v (restored)"
    rm -f "$STATE_DIR/$key"
}
sctl_path()      { echo "/proc/sys/$(echo "$1" | tr '.' '/')"; }
save_sysctl()    { save_write "$(sctl_path "$1")" "$2" "sysctl_${1//./_}"; }
restore_sysctl() { restore_write "$(sctl_path "$1")" "sysctl_${1//./_}"; }
for_each_policy()     { local p; for p in "$CPU_SYS"/cpufreq/policy*; do
                          [ -d "$p" ] && save_write "$p/$1" "$2" "$(basename "$p")_$1"; done; }
restore_each_policy() { local p; for p in "$CPU_SYS"/cpufreq/policy*; do
                          [ -d "$p" ] && restore_write "$p/$1" "$(basename "$p")_$1"; done; }

# Intel-only throttle counters; returns "" on AMD/ARM (callers must handle)
throttle_total() { local t=0 f
    for f in "$CPU_SYS"/cpu[0-9]*/thermal_throttle/*_throttle_count; do
        [ -e "$f" ] || { echo ""; return; }; t=$((t + $(rd "$f"))); done
    echo "$t"; }
# Hottest sensor across hwmon (k10temp Tctl on Zen) and thermal zones, in mC
max_temp() { local m=0 f v
    for f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do
        v=$(rd "$f") || continue
        [ -n "$v" ] && [ "$v" -gt "$m" ] 2>/dev/null && m=$v; done
    echo "$m"; }
vmstat_val()   { awk -v k="$1" '$1==k{print $2}' /proc/vmstat 2>/dev/null || echo 0; }
stat_val()     { awk -v k="$1" '$1==k{print $2}' /proc/stat  2>/dev/null || echo 0; }
steal_jiffies(){ awk '/^cpu /{print $9+0}' /proc/stat 2>/dev/null || echo 0; }

# ============================================================ status =========
show_status() {
    info "CPU"
    grep -m1 'model name' /proc/cpuinfo | sed 's/.*: /  /'
    log "Online CPUs"    "$(rd "$CPU_SYS/online")"
    log "SMT control"    "$(rd "$CPU_SYS/smt/control")"
    log "cpufreq driver" "$(rd "$CPU_SYS/cpufreq/policy0/scaling_driver")"
    [ -e "$CPU_SYS/amd_pstate/status" ] && log "amd_pstate mode" "$(rd "$CPU_SYS/amd_pstate/status")"
    [ -e "$CPU_SYS/amd_pstate/prefcore" ] && log "amd_pstate prefcore" "$(rd "$CPU_SYS/amd_pstate/prefcore")"
    local p
    for p in "$CPU_SYS"/cpufreq/policy*; do [ -d "$p" ] || continue
        printf '  %-10s gov=%-11s cur=%-9s range=[%s..%s] boost=%s epp=%s\n' \
          "$(basename "$p")" "$(rd "$p/scaling_governor")" "$(rd "$p/scaling_cur_freq")" \
          "$(rd "$p/scaling_min_freq")" "$(rd "$p/scaling_max_freq")" \
          "$(rd "$p/boost" || echo -)" \
          "$(rd "$p/energy_performance_preference" || echo -)"; done
    info "Turbo / boost (global)"
    [ -e "$CPU_SYS/intel_pstate/no_turbo" ] && log "intel_pstate no_turbo" "$(rd "$CPU_SYS/intel_pstate/no_turbo")"
    [ -e "$CPU_SYS/cpufreq/boost" ]         && log "cpufreq boost"         "$(rd "$CPU_SYS/cpufreq/boost")"
    info "Kernel / memory"
    for k in vm.swappiness kernel.numa_balancing kernel.randomize_va_space kernel.nmi_watchdog; do
        log "$k" "$(rd "$(sctl_path "$k")" || echo n/a)"; done
    log "THP enabled" "$(rd /sys/kernel/mm/transparent_hugepage/enabled)"
    log "THP defrag"  "$(rd /sys/kernel/mm/transparent_hugepage/defrag)"
    info "Tracing sysctls"
    for k in kernel.perf_event_paranoid kernel.kptr_restrict kernel.yama.ptrace_scope; do
        log "$k" "$(rd "$(sctl_path "$k")" || echo n/a)"; done
    info "Thermal"
    log "hottest sensor" "$(( $(max_temp) / 1000 ))C"
    if have nvidia-smi; then
        info "NVIDIA GPU"
        nvidia-smi --query-gpu=index,name,persistence_mode,clocks.sm,power.limit \
            --format=csv,noheader 2>/dev/null | sed 's/^/  /'
    fi
    local c
    for c in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$c" ] && { info "AMD GPU"; log "$c" "$(rd "$c")"; }; done
}

# Static layout: sockets/cores/cache/NUMA. Doesn't change while the box is
# up, so no sampling - lscpu/numactl if present, /proc/cpuinfo fallback.
show_cpu() {
    info "CPU topology"
    if have lscpu; then lscpu
    else grep -E 'model name|physical id|siblings|cpu cores|core id' /proc/cpuinfo | sort -u
    fi
    if [ -d "$CPU_SYS/cpu0/cache" ]; then
        info "Cache (cpu0)"
        local c
        for c in "$CPU_SYS"/cpu0/cache/index*; do [ -d "$c" ] || continue
            printf '  L%-2s %-10s size=%-8s line=%sB ways=%-4s sets=%-6s shared_cpu_list=%s\n' \
              "$(rd "$c/level")" "$(rd "$c/type")" "$(rd "$c/size")" \
              "$(rd "$c/coherency_line_size")" "$(rd "$c/ways_of_associativity")" \
              "$(rd "$c/number_of_sets")" "$(rd "$c/shared_cpu_list")"; done
    fi
    if have numactl; then info "NUMA"; numactl -H; fi
}

# Live per-thread state: usage% (one SAMPLE_INT-wide /proc/stat delta per
# logical CPU), current freq + governor (per-cpu cpufreq, not per-policy -
# SMT siblings can differ). Temp/power are package-wide, not per-thread -
# no CPU exposes either at hardware-thread granularity - so they're printed
# once below the table instead of faked into a per-row column.
irq_totals() {  # per-CPU column sums from /proc/interrupts, "cpuN total" per line
    awk -v ncpu="$1" 'NR==1{next} NF>ncpu{ for(i=2;i<=ncpu+1;i++){ if ($i ~ /^[0-9]+$/) sum[i-2]+=$i } }
        END{ for (c in sum) print c, sum[c] }' /proc/interrupts
}

# Path to the deepest cpuidle state dir for one cpu - highest state* index,
# picked by numeric comparison (no ls|sort fork: this runs per-core, twice
# per sample, and forking a pipeline 2*ncpu times measurably stretches the
# window the %-of-window calculations below assume).
deepest_state_dir() {  # <cpu>
    local d best="" bestn=-1 n
    for d in "$CPU_SYS/cpu$1"/cpuidle/state*; do
        [ -d "$d" ] || continue
        n=${d##*state}
        [ "$n" -gt "$bestn" ] && { bestn=$n; best=$d; }
    done
    echo "$best"
}
# Deepest state's residency time (usec) for every cpu. Callers diff two
# snapshots against the *actual* elapsed wall-clock time, not the nominal
# sample interval - see show_core's elapsed/t_start/t_end.
deep_idle_totals() {  # <ncpu>
    local i d t
    for ((i = 0; i < $1; i++)); do
        d=$(deepest_state_dir "$i")
        [ -n "$d" ] && { t=$(rd "$d/time"); [ -n "$t" ] && echo "$i $t"; }
    done
}

show_core() {
    info "Per-thread state (${SAMPLE_INT}s sample)"
    local ncpu; ncpu=$(nproc 2>/dev/null || echo 0)
    [ "$ncpu" -gt 0 ] || { echo "no CPUs found" >&2; return 1; }

    local rapl="" f
    for f in /sys/class/powercap/*/energy_uj; do [ -r "$f" ] && { rapl="$f"; break; }; done
    # Name/latency of the deepest cpuidle state, for the column header -
    # same state index deep_idle_totals reads, assumed uniform across cores.
    local deepdir deepname="" deeplat=""
    deepdir=$(deepest_state_dir 0)
    [ -n "$deepdir" ] && { deepname=$(rd "$deepdir/name"); deeplat=$(rd "$deepdir/latency"); }

    local line tag cpu rest fields tot i
    # tot/idle: /proc/stat -> usage%. wait/ctxsw: /proc/schedstat fields 8/9
    # (run_delay ns = time spent queued waiting for this cpu; pcount =
    # timeslices handed out, used as the context-switch proxy - schedstat's
    # own sched_count field reads 0 on this kernel, apparently unpopulated)
    # - direct scheduler-contention signals, distinct from usage% (a core
    # can read 0% busy and still be where the scheduler keeps parking and
    # waking short-lived threads). irq: per-cpu interrupt count from
    # /proc/interrupts. deep: residency in the deepest C-state - high
    # deep-idle% on an otherwise "quiet" core means pinning a benchmark
    # there pays the ${deeplat:-?}us wake latency on every wakeup, which is
    # exactly what watchcub bench --cstate=hold exists to avoid.
    declare -A tot0 idle0 tot1 idle1 wait0 wait1 ctxsw0 ctxsw1 irq0 irq1 deep0 deep1 sib
    local p0=0 p1=0
    local t_start t_end elapsed
    t_start=$(date +%s.%N)
    [ -n "$rapl" ] && p0=$(rd "$rapl")
    while read -r line; do
        tag=${line%% *}
        case "$tag" in
          cpu[0-9]*)
            cpu=${tag#cpu}; rest=${line#* }; read -r -a fields <<< "$rest"
            tot=0; for i in "${fields[@]}"; do tot=$((tot+i)); done
            tot0[$cpu]=$tot; idle0[$cpu]=$(( fields[3] + fields[4] ));;
        esac
    done < /proc/stat
    while read -r line; do
        tag=${line%% *}
        case "$tag" in
          cpu[0-9]*)
            cpu=${tag#cpu}; rest=${line#* }; read -r -a fields <<< "$rest"
            ctxsw0[$cpu]=${fields[8]:-0}; wait0[$cpu]=${fields[7]:-0};;
        esac
    done < /proc/schedstat
    while read -r cpu tot; do irq0[$cpu]=$tot; done < <(irq_totals "$ncpu")
    while read -r cpu t; do deep0[$cpu]=$t; done < <(deep_idle_totals "$ncpu")

    sleep "$SAMPLE_INT"

    [ -n "$rapl" ] && p1=$(rd "$rapl")
    while read -r line; do
        tag=${line%% *}
        case "$tag" in
          cpu[0-9]*)
            cpu=${tag#cpu}; rest=${line#* }; read -r -a fields <<< "$rest"
            tot=0; for i in "${fields[@]}"; do tot=$((tot+i)); done
            tot1[$cpu]=$tot; idle1[$cpu]=$(( fields[3] + fields[4] ));;
        esac
    done < /proc/stat
    while read -r line; do
        tag=${line%% *}
        case "$tag" in
          cpu[0-9]*)
            cpu=${tag#cpu}; rest=${line#* }; read -r -a fields <<< "$rest"
            ctxsw1[$cpu]=${fields[8]:-0}; wait1[$cpu]=${fields[7]:-0};;
        esac
    done < /proc/schedstat
    while read -r cpu tot; do irq1[$cpu]=$tot; done < <(irq_totals "$ncpu")
    while read -r cpu t; do deep1[$cpu]=$t; done < <(deep_idle_totals "$ncpu")
    t_end=$(date +%s.%N)
    elapsed=$(awk -v a="$t_start" -v b="$t_end" 'BEGIN{printf "%.6f", b-a}')

    for ((i = 0; i < ncpu; i++)); do
        sib[$i]=$(rd "$CPU_SYS/cpu$i/topology/thread_siblings_list")
    done

    # IRQ/s, CTXSW/s and DEEP-IDLE% below are computed against this, not the
    # nominal SAMPLE_INT above - per-core sampling itself takes real time.
    log "actual sample window" "${elapsed}s (nominal: ${SAMPLE_INT}s)"
    printf '  %-6s %7s %9s %9s  %-10s %8s %9s %8s %11s  %s\n' \
        CPU "USAGE%" "FREQ" "MAXFREQ" GOVERNOR "IRQ/s" "WAIT(ms)" "CTXSW/s" "DEEP-IDLE%" "SMT SIBLING"
    for ((i = 0; i < ncpu; i++)); do
        local busy="-" dt di freq="-" maxfreq="-" gov="-" irqs="-" waitms="-" ctxsws="-" deeppct="-" sibother
        if [ -n "${tot0[$i]:-}" ] && [ -n "${tot1[$i]:-}" ]; then
            dt=$(( tot1[$i] - tot0[$i] )); di=$(( idle1[$i] - idle0[$i] ))
            [ "$dt" -gt 0 ] && busy=$(awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%.1f", (dt-di)*100/dt}')
        fi
        [ -e "$CPU_SYS/cpu$i/cpufreq/scaling_cur_freq" ] && freq=$(( $(rd "$CPU_SYS/cpu$i/cpufreq/scaling_cur_freq") / 1000 ))
        [ -e "$CPU_SYS/cpu$i/cpufreq/scaling_max_freq" ] && maxfreq=$(( $(rd "$CPU_SYS/cpu$i/cpufreq/scaling_max_freq") / 1000 ))
        [ -e "$CPU_SYS/cpu$i/cpufreq/scaling_governor" ] && gov=$(rd "$CPU_SYS/cpu$i/cpufreq/scaling_governor")
        [ -n "${irq0[$i]:-}" ] && [ -n "${irq1[$i]:-}" ] &&
            irqs=$(awk -v a="${irq0[$i]}" -v b="${irq1[$i]}" -v s="$elapsed" 'BEGIN{printf "%.0f", (b-a)/s}')
        [ -n "${wait0[$i]:-}" ] && [ -n "${wait1[$i]:-}" ] &&
            waitms=$(awk -v a="${wait0[$i]}" -v b="${wait1[$i]}" 'BEGIN{printf "%.1f", (b-a)/1000000}')
        [ -n "${ctxsw0[$i]:-}" ] && [ -n "${ctxsw1[$i]:-}" ] &&
            ctxsws=$(awk -v a="${ctxsw0[$i]}" -v b="${ctxsw1[$i]}" -v s="$elapsed" 'BEGIN{printf "%.0f", (b-a)/s}')
        [ -n "${deep0[$i]:-}" ] && [ -n "${deep1[$i]:-}" ] &&
            deeppct=$(awk -v a="${deep0[$i]}" -v b="${deep1[$i]}" -v s="$elapsed" 'BEGIN{printf "%.1f", (b-a)/(s*1000000)*100}')
        sibother=$(echo "${sib[$i]:-$i}" | tr ',' '\n' | grep -v "^$i\$" | paste -sd, -)
        printf '  cpu%-3s %6s%% %8sM %8sM  %-10s %8s %9s %8s %11s  %s\n' \
            "$i" "$busy" "$freq" "$maxfreq" "$gov" "$irqs" "$waitms" "$ctxsws" "$deeppct" "${sibother:--}"
    done

    echo
    [ -n "$deepname" ] && log "deepest C-state on this cpu" "$deepname (${deeplat}us exit latency) - DEEP-IDLE% is time spent there"
    log "hottest sensor (package-wide, not per-thread)" "$(( $(max_temp) / 1000 ))C"
    if [ -n "$rapl" ] && [ "${p1:-0}" -ge "${p0:-0}" ] 2>/dev/null; then
        log "package power (package-wide, not per-thread)" \
            "$(awk -v a="$p0" -v b="$p1" -v s="$SAMPLE_INT" 'BEGIN{printf "%.1fW", (b-a)/1000000/s}')"
    fi
}

# Full machine snapshot for run documentation
write_sysinfo() {  # <outfile>
    { echo "# watchcub sysinfo  $(ts)"
      echo "## uname";      uname -a
      echo "## os-release"; rd /etc/os-release
      echo "## cmdline";    rd /proc/cmdline
      echo "## cpu";        have lscpu && lscpu || grep -E 'model name|siblings|cpu cores|MHz|cache' /proc/cpuinfo | sort -u
      echo "## numa";       have numactl && numactl -H || echo "numactl not installed"
      echo "## meminfo";    head -20 /proc/meminfo
      echo "## config $(cfg_summary)"
      echo "## settings";   show_status
    } > "$1" 2>&1
}

# =========================================================== profile =========
# One line each: CPU model, RAM total, GPU(s), kernel version. Best-effort -
# missing tools/files print "unknown", never abort profile generation.
hw_summary() {
    local cpu ram gpu kernel
    cpu=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: *//')
    ram=$(awk '/MemTotal/{printf "%.1f GB", $2/1024/1024}' /proc/meminfo)
    if have lspci; then
        gpu=$(lspci | grep -iE 'vga|3d controller' | sed -E 's/^[0-9a-f:.]+ [^:]+: //' | awk '{printf "%s%s", (NR>1?"; ":""), $0}')
    fi
    kernel=$(uname -r)
    printf 'CPU: %s\nRAM: %s\nGPU: %s\nKERNEL: %s\n' \
        "${cpu:-unknown}" "${ram:-unknown}" "${gpu:-unknown}" "${kernel:-unknown}"
}

profile_new() {
    local path="${1:-./watchcub.profile}"
    [ -e "$path" ] && { echo "Refusing to overwrite existing $path" >&2; exit 1; }
    { echo "# watchcub profile. Generated $(ts)."
      hw_summary | sed 's/^/# /'
      echo "#"
      echo "# Format: KEY=VALUE. # starts a comment."
      echo "# Not auto-loaded. Pass it: watchcub bench -p $path"
      echo "# Covers every setting bench can change. Edit any value below."
      echo "# Same keys as the CLI flags. This file replaces the bench preset."
      local k
      for k in "${BENCH_KEYS[@]}"; do
          printf '\n# %s\n%s=%s\n' "${CFG_DOC[$k]}" "$k" "${CFG[$k]}"
      done
    } > "$path"
    echo "Wrote $path - edit it, then: sudo ./watchcub.sh bench -p $path"
}
profile_show() {
    info "Effective configuration"
    local k
    for k in "${CFG_KEYS[@]}"; do
        case "$k" in
          LOGS)  log "log dir"   "${CFG[$k]}";;
          STATE) log "state dir" "${CFG[$k]}";;
          *)     log "$k" "${CFG[$k]}";;
        esac
    done
    log "config source" "$PROFILE_SOURCE"
}

# ============================================================ bench ==========
apply_bench() {
    need_root
    action_log "bench $(cfg_summary)"
    [ -e "$STATE_DIR/.bench-active" ] && { echo "bench already applied; restore first."; exit 1; }
    mkdir -p "$STATE_DIR"; : > "$STATE_DIR/.bench-active"
    cfg_summary > "$STATE_DIR/profile"

    info "CPU governor & EPP"
    if [ "$GOVERNOR_MODE" = keep ]; then log "scaling_governor" "kept as-is"
    else for_each_policy scaling_governor "$GOVERNOR_MODE"; fi
    if [ "$EPP_MODE" = keep ]; then log "energy_performance_preference" "kept as-is"
    else for_each_policy energy_performance_preference "$EPP_MODE"; fi

    info "Turbo/boost (mode: $TURBO_MODE)"
    if [ "$TURBO_MODE" = off ]; then
        # global knob first; per-policy boost (amd-pstate >=6.11) only if no
        # global knob worked - per-policy files may be read-only slaves
        local global_ok=1
        save_write "$CPU_SYS/intel_pstate/no_turbo" 1 intel_no_turbo && global_ok=0
        save_write "$CPU_SYS/cpufreq/boost"          0 cpufreq_boost  && global_ok=0
        [ "$global_ok" -ne 0 ] && for_each_policy boost 0
    else
        log "turbo/boost" "kept ON - full boost clocks (highest performance)"
    fi

    info "Min-freq pinning (mode: $PINFREQ_MODE, target: $PINFREQ_TARGET_VAL)"
    if [ "$PINFREQ_MODE" = on ]; then
        local p target
        for p in "$CPU_SYS"/cpufreq/policy*; do [ -d "$p" ] || continue
            if [ "$PINFREQ_TARGET_VAL" = max ]; then target=$(rd "$p/scaling_max_freq")
            else target=$PINFREQ_TARGET_VAL; fi
            [ -n "$target" ] || continue
            save_write "$p/scaling_min_freq" "$target" "$(basename "$p")_scaling_min_freq"; done
    else
        log "min freq" "not pinned - idle cores may idle (single-core boost headroom)"
    fi

    info "C-states (mode: $CSTATE_MODE)"
    if [ "$CSTATE_MODE" = hold ] && [ -e /dev/cpu_dma_latency ]; then
        ( exec 3<>/dev/cpu_dma_latency; printf '\x00\x00\x00\x00' >&3; sleep infinity ) &
        echo $! > "$STATE_DIR/dma_latency_pid"
        log "/dev/cpu_dma_latency" "held 0us (pid $(cat "$STATE_DIR/dma_latency_pid"))"
    else
        log "C-states" "left enabled - idle cores in CC6 free boost budget"
    fi

    info "Kernel & memory"
    [ "$SWAPPINESS_VAL" = keep ]     || save_sysctl vm.swappiness "$SWAPPINESS_VAL"
    [ "$NUMA_BALANCING_VAL" = keep ] || save_sysctl kernel.numa_balancing "$NUMA_BALANCING_VAL"
    [ "$ASLR_VAL" = keep ]           || save_sysctl kernel.randomize_va_space "$ASLR_VAL"
    [ "$NMI_WATCHDOG_VAL" = keep ]   || save_sysctl kernel.nmi_watchdog "$NMI_WATCHDOG_VAL"
    case "$THP_MODE" in
      keep) log "THP" "kept as-is";;
      *)    save_write /sys/kernel/mm/transparent_hugepage/enabled "$THP_MODE" thp_enabled;;
    esac
    case "$THP_DEFRAG_MODE" in
      keep) log "THP defrag" "kept as-is";;
      *)    save_write /sys/kernel/mm/transparent_hugepage/defrag "$THP_DEFRAG_MODE" thp_defrag;;
    esac
    if [ "$DROP_CACHES_MODE" = on ]; then
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && log "page cache" "dropped"
    else
        log "page cache" "left as-is"
    fi

    info "SMT (mode: $SMT_MODE)"
    if [ "$SMT_MODE" = off ]; then save_write "$CPU_SYS/smt/control" off smt_control
    else log "SMT" "kept as-is"; fi

    info "GPU"
    if have nvidia-smi; then
        case "$NVIDIA_PERSIST_MODE" in
          keep) log "NVIDIA persistence" "kept as-is";;
          on)   nvidia-smi -pm 1 >/dev/null 2>&1 && log "NVIDIA persistence" "on";;
          off)  nvidia-smi -pm 0 >/dev/null 2>&1 && log "NVIDIA persistence" "off";;
        esac
        if [ "$NVIDIA_CLOCK_MODE" = max ]; then
            local msm mmem
            msm=$(nvidia-smi --query-gpu=clocks.max.sm     --format=csv,noheader,nounits 2>/dev/null | head -1)
            mmem=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -1)
            [ -n "${msm:-}" ]  && nvidia-smi -lgc "$msm"  >/dev/null 2>&1 && { touch "$STATE_DIR/nvidia_locked"; log "NVIDIA SM clock" "locked ${msm}MHz"; }
            [ -n "${mmem:-}" ] && nvidia-smi -lmc "$mmem" >/dev/null 2>&1 && log "NVIDIA mem clock" "locked ${mmem}MHz"
        else
            log "NVIDIA clocks" "kept as-is"
        fi
    fi
    local c
    if [ "$AMDGPU_PERF_VAL" = keep ]; then
        log "amdgpu perf level" "kept as-is"
    else
        for c in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            [ -e "$c" ] && save_write "$c" "$AMDGPU_PERF_VAL" "amdgpu_$(echo "$c"|grep -o 'card[0-9]*')_perf"; done
    fi
    if have rocm-smi; then
        if [ "$ROCM_PERF_VAL" = keep ]; then
            log "rocm-smi perflevel" "kept as-is"
        else
            rocm-smi --setperflevel "$ROCM_PERF_VAL" >/dev/null 2>&1 && log "rocm-smi perflevel" "$ROCM_PERF_VAL"
        fi
    fi

    info "Done - now: sudo $0 verify   then: sudo $0 run -- <benchmark cmd>"
}

# ==================================================== trace-(un)lock =========
TRACE_KNOBS=( "kernel.perf_event_paranoid=-1" "kernel.kptr_restrict=0"
              "kernel.yama.ptrace_scope=0" "net.core.bpf_jit_enable=1"
              "kernel.ftrace_enabled=1" )
do_trace_unlock() { need_root; action_log trace-unlock; mkdir -p "$STATE_DIR"
    info "Loosening perf/eBPF sysctls (dedicated bench box only!)"
    if [ -n "$PARANOID_VAL" ]; then
        log "kernel.perf_event_paranoid" "$PARANOID_VAL (--paranoid override, default -1)"
    fi
    local kv; for kv in "${TRACE_KNOBS[@]}"; do
        if [ "${kv%%=*}" = kernel.perf_event_paranoid ] && [ -n "$PARANOID_VAL" ]; then
            save_sysctl kernel.perf_event_paranoid "$PARANOID_VAL"
        else
            save_sysctl "${kv%%=*}" "${kv#*=}"
        fi
    done; }
do_trace_lock()   { need_root; action_log trace-lock; info "Re-tightening"
    local kv; for kv in "${TRACE_KNOBS[@]}"; do restore_sysctl "${kv%%=*}"; done
    rmdir "$STATE_DIR" 2>/dev/null || true; }

# ============================================================ restore ========
do_restore() {
    need_root; action_log restore
    [ -d "$STATE_DIR" ] || { echo "Nothing saved in $STATE_DIR." >&2; exit 1; }
    info "CPU"
    restore_each_policy scaling_governor
    restore_each_policy scaling_min_freq
    restore_each_policy energy_performance_preference
    restore_each_policy boost
    restore_write "$CPU_SYS/intel_pstate/no_turbo" intel_no_turbo
    restore_write "$CPU_SYS/cpufreq/boost" cpufreq_boost
    restore_write "$CPU_SYS/smt/control" smt_control
    info "C-states"
    [ -e "$STATE_DIR/dma_latency_pid" ] && { kill "$(cat "$STATE_DIR/dma_latency_pid")" 2>/dev/null
        rm -f "$STATE_DIR/dma_latency_pid"; log "PM-QoS" "released"; }
    info "Kernel & memory"
    for k in vm.swappiness kernel.numa_balancing kernel.randomize_va_space kernel.nmi_watchdog; do
        restore_sysctl "$k"; done
    restore_write /sys/kernel/mm/transparent_hugepage/enabled thp_enabled
    restore_write /sys/kernel/mm/transparent_hugepage/defrag  thp_defrag
    info "Tracing sysctls"
    local kv; for kv in "${TRACE_KNOBS[@]}"; do restore_sysctl "${kv%%=*}"; done
    info "GPU"
    if have nvidia-smi && [ -e "$STATE_DIR/nvidia_locked" ]; then
        nvidia-smi -rgc >/dev/null 2>&1; nvidia-smi -rmc >/dev/null 2>&1
        log "NVIDIA clocks" "reset"; rm -f "$STATE_DIR/nvidia_locked"; fi
    local c
    for c in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$c" ] && restore_write "$c" "amdgpu_$(echo "$c"|grep -o 'card[0-9]*')_perf"; done
    have rocm-smi && { rocm-smi --resetperflevel >/dev/null 2>&1 || rocm-smi --setperflevel auto >/dev/null 2>&1; }
    rm -f "$STATE_DIR/.bench-active" "$STATE_DIR/profile"; rmdir "$STATE_DIR" 2>/dev/null || true
    info "Done - reverted"
}

# ============================================================ verify =========
do_verify() {
    WARNS=0
    info "Pre-flight checks"
    local p bad=0 unpinned=0 npol=0
    for p in "$CPU_SYS"/cpufreq/policy*; do [ -d "$p" ] || continue; npol=$((npol+1))
        [ "$(rd "$p/scaling_governor")" = performance ] || bad=1
        [ "$(rd "$p/scaling_min_freq")" = "$(rd "$p/scaling_max_freq")" ] || unpinned=1; done
    if [ "$npol" -eq 0 ]; then warnl "no cpufreq policies exposed (VM/container?)"
    else
        [ $bad -eq 0 ]      && pass "governor=performance on all $npol policies" \
                            || warnl "some policies not on 'performance' (run: bench)"
        if grep -q 'PINFREQ=off' "$STATE_DIR/profile" 2>/dev/null; then
            pass "min freq not pinned (PINFREQ=off profile - single-core boost mode)"
        else
            [ $unpinned -eq 0 ] && pass "min freq pinned to max (no ramp jitter)" \
                                || warnl "min_freq != max_freq on some policies"
        fi
    fi
    local load ncpu
    load=$(awk '{print $1}' /proc/loadavg); ncpu=$(nproc 2>/dev/null || echo 1)
    awk -v l="$load" -v n="$ncpu" -v f="$LOAD_MAX_FRAC" 'BEGIN{exit !(l < n*f)}' \
        && pass "1-min load $load is quiet for $ncpu CPUs (< ${LOAD_MAX_FRAC}x)" \
        || warnl "load $load - other work is running; results will be noisy"
    local swused
    swused=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
    [ "${swused:-0}" -lt "$SWAP_MAX_KB" ] && pass "swap in use: ${swused}kB (< ${SWAP_MAX_KB}kB)" \
        || warnl "swap in use: ${swused}kB - memory pressure will distort results"
    local avail tot usedpct
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    tot=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    usedpct=$(awk -v a="$avail" -v t="$tot" 'BEGIN{printf "%.1f", (t-a)*100/t}')
    awk -v a="$avail" -v t="$tot" -v p="$MEM_MAX_USED_PCT" 'BEGIN{exit !(a > t*(100-p)/100)}' \
        && pass "memory used ${usedpct}% (< ${MEM_MAX_USED_PCT}%), ${avail}kB available" \
        || warnl "memory used ${usedpct}% (>= ${MEM_MAX_USED_PCT}%) - only $((avail/1024))MB available"
    local thr; thr=$(throttle_total)
    if [ -n "$thr" ]; then
        [ "$thr" -eq 0 ] && pass "no thermal throttle events (Intel counters)" \
                         || warnl "$thr throttle events since boot"
    fi
    local mt; mt=$(max_temp)
    if [ "$mt" -gt 0 ]; then
        [ "$mt" -lt "$TEMP_WARN" ] && pass "hottest sensor: $((mt/1000))C (< ${TEMP_WARN_C}C)" \
                                   || warnl "hottest sensor: $((mt/1000))C - let it cool first"
    fi
    local st; st=$(steal_jiffies)
    [ "${st:-0}" -eq 0 ] && pass "no CPU steal (bare metal or quiet host)" \
        || warnl "steal time present - VM neighbours can distort results"
    local dirty; dirty=$(awk '/Dirty:/{print $2}' /proc/meminfo)
    [ "${dirty:-0}" -lt "$DIRTY_MAX_KB" ] && pass "dirty pages: ${dirty}kB (< ${DIRTY_MAX_KB}kB)" \
        || warnl "dirty pages: ${dirty}kB - run 'sync' first"
    echo
    return "$WARNS"
}

# ============================================================== run ==========
do_run() {
    [ $# -ge 1 ] || { echo "Usage: $0 run [flags] -- <command...>" >&2; exit 1; }

    local rundir; rundir="$LOG_ROOT/run-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$rundir" || { echo "cannot create $rundir" >&2; exit 1; }
    printf '%s\n' "$*" > "$rundir/command.txt"
    write_sysinfo "$rundir/sysinfo.txt"

    local thr0 thr1 sw0 sw1 mf0 mf1 cs0 cs1 st0 st1 t0 t1
    thr0=$(throttle_total)
    sw0=$(( $(vmstat_val pswpin) + $(vmstat_val pswpout) ))
    mf0=$(vmstat_val pgmajfault); cs0=$(stat_val ctxt); st0=$(steal_jiffies)

    # --- samplers -----------------------------------------------------------
    # freq CSV: header maps columns to policy names - glob order is
    # lexicographic (policy0,policy1,policy10,...), column != core number
    local fsampler= p
    if ls "$CPU_SYS"/cpufreq/policy*/scaling_cur_freq >/dev/null 2>&1; then
        { printf 'epoch'
          for p in "$CPU_SYS"/cpufreq/policy*/scaling_cur_freq; do
              printf ',%s' "$(basename "$(dirname "$p")")"; done
          printf '\n'; } > "$rundir/freq.csv"
        ( while :; do
            printf '%s' "$(date +%s.%N)"
            for p in "$CPU_SYS"/cpufreq/policy*/scaling_cur_freq; do
                printf ',%s' "$(rd "$p")"; done
            printf '\n'; sleep "$SAMPLE_INT"
          done >> "$rundir/freq.csv" ) & fsampler=$!
    fi
    ( while :; do printf '%s,%s\n' "$(date +%s.%N)" "$(max_temp)"
        sleep "$SAMPLE_INT"; done >> "$rundir/temp.csv" ) & local tsampler=$!

    # --- launch benchmark ---------------------------------------------------
    info "Running: $*   (logs: $rundir)"
    t0=$(date +%s.%N)
    "$@" > >(tee "$rundir/stdout.log") 2> >(tee "$rundir/stderr.log" >&2) & local bpid=$!

    # Per-thread placement & scheduler: TID,CPU,CLASS,RTPRIO,%CPU,NAME
    local psampler=
    if have ps && ps -L -o tid= -p $$ >/dev/null 2>&1; then
        ( while kill -0 "$bpid" 2>/dev/null; do
            printf '### %s\n' "$(date +%s.%N)"
            ps -L -o tid=,psr=,cls=,rtprio=,pcpu=,comm= -p "$bpid" 2>/dev/null
            sleep 1
          done >> "$rundir/threads.log" ) & psampler=$!
    fi

    wait "$bpid"; local rc=$?
    t1=$(date +%s.%N)
    for s in "$fsampler" "$tsampler" "${psampler:-}"; do [ -n "$s" ] && kill "$s" 2>/dev/null; done
    wait 2>/dev/null

    thr1=$(throttle_total)
    sw1=$(( $(vmstat_val pswpin) + $(vmstat_val pswpout) ))
    mf1=$(vmstat_val pgmajfault); cs1=$(stat_val ctxt); st1=$(steal_jiffies)

    # --- report (printed AND saved) ----------------------------------------
    WARNS=0
    {
    info "Run-condition report  ($(ts), exit code $rc)"
    log "command"   "$(cat "$rundir/command.txt")"
    log "config"    "$(cfg_summary)"
    log "wall time" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3fs", b-a}')"

    if [ -s "$rundir/freq.csv" ]; then
        # dip check judges only the busiest core (= the benchmark's);
        # idle cores at min freq are normal, on Zen even desirable
        awk -F, -v d="$FREQ_DIP_FRAC" '
            NR==1{for(i=2;i<=NF;i++)name[i]=$i; next}
            {for(i=2;i<=NF;i++){v=$i+0; if(v==0)continue
                s[i]+=v; n[i]++
                if(!(i in mn)||v<mn[i])mn[i]=v; if(v>mx[i])mx[i]=v}}
            END{
                best=0; ba=0
                for(i in n){a=s[i]/n[i]; if(a>ba){ba=a; best=i}}
                if(!best) exit 0
                gmx=0; for(i in n) if(mx[i]>gmx)gmx=mx[i]
                printf "  %-44s min=%d avg=%d max=%d kHz (%s, %d samples)\n", \
                    "benchmark-core freq",mn[best],ba,mx[best],name[best],n[best]
                printf "  %-44s %d kHz\n","fastest freq seen (any core)",gmx
                if(mn[best]<mx[best]*d) exit 2
            }' "$rundir/freq.csv" \
          || warnl "benchmark core dipped below ${FREQ_DIP_FRAC}x its max during run (throttling/contention)"
    fi
    if [ -s "$rundir/temp.csv" ] && [ "$(awk -F, '$2>m{m=$2}END{print m+0}' "$rundir/temp.csv")" -gt 0 ]; then
        local pk; pk=$(awk -F, '$2>m{m=$2}END{print m+0}' "$rundir/temp.csv")
        [ "$pk" -lt "$TEMP_WARN" ] && pass "peak temperature: $((pk/1000))C" \
                                   || warnl "peak temperature: $((pk/1000))C (>= ${TEMP_WARN_C}C)"
    fi
    if [ -n "$thr0" ] && [ -n "$thr1" ]; then
        [ "$((thr1-thr0))" -eq 0 ] && pass "no thermal throttle events during run" \
            || warnl "$((thr1-thr0)) throttle events DURING the run"
    fi
    [ "$((sw1-sw0))" -eq 0 ] && pass "no swap activity" \
        || warnl "$((sw1-sw0)) pages swapped during run - not enough RAM"
    [ "$((mf1-mf0))" -lt 100 ] && pass "major page faults: $((mf1-mf0))" \
        || warnl "$((mf1-mf0)) major faults - disk reads mid-run"
    log "context switches" "$((cs1-cs0))"
    [ "$((st1-st0))" -eq 0 ] && pass "no CPU steal during run" \
        || warnl "$((st1-st0)) jiffies stolen by hypervisor"

    if [ -s "$rundir/threads.log" ]; then
        local cpus cls nthr
        cpus=$(awk '/^###/{next}{print $2}' "$rundir/threads.log" | sort -nu | paste -sd, -)
        cls=$(awk '/^###/{next}{print $3}'  "$rundir/threads.log" | sort -u  | paste -sd, -)
        nthr=$(awk '/^###/{next}{print $1}' "$rundir/threads.log" | sort -u  | wc -l)
        log "threads observed"   "$nthr"
        log "ran on CPUs"        "${cpus:-?}"
        log "scheduler classes"  "${cls:-?} (TS=CFS/EEVDF, FF/RR=realtime)"
    fi
    echo
    echo "  Full logs: $rundir/ (sysinfo.txt settings, freq.csv, temp.csv, threads.log, stdout.log)"
    } | tee "$rundir/report.txt"
    return "$rc"
}

# ============================================================ main ===========
usage() {
    cat <<EOF
Usage: sudo $0 <command> [flags] [-- benchmark-cmd]
Commands: status | cpu | core | bench | verify | run -- <cmd> | restore
          profile new [path] | profile show | trace-unlock | trace-lock
Flags:    --turbo=keep|off --pinfreq=on|off --pinfreq-target=max|KHZ
          --cstate=hold|keep --smt=keep|off
          --thp=always|never|keep --thp-defrag=never|always|madvise|keep
          --governor=GOV|keep --epp=EPP|keep
          --swappiness=N|keep --numa-balancing=N|keep --aslr=0|1|2|keep
          --nmi-watchdog=N|keep --drop-caches=on|off
          --nvidia-persist=on|off|keep --nvidia-clock=max|keep
          --amdgpu-perf=LEVEL|keep --rocm-perf=LEVEL|keep
          --temp-warn=C --mem-max=PCT --load-max=FRAC
          --swap-max=KB --dirty-max=KB --freq-dip=FRAC --sample=SEC
          --logs=DIR --state=DIR --profile=FILE | -p FILE
          --paranoid=-1|0|1|2|3|4   (trace-unlock only; default -1)
Precedence: flags > profile file > WATCHCUB_* env > defaults.
Profiles are never auto-loaded; pass one with -p FILE or \$WATCHCUB_PROFILE.
EOF
    exit 1
}

declare -A CLI_CFG=()
RUN_ARGS=()
PARANOID_VAL=""
CMD="${1:-}"; [ $# -gt 0 ] && shift
PACTION=""; PPATH=""
if [ "$CMD" = profile ]; then PACTION="${1:-show}"; [ $# -gt 0 ] && shift; fi

while [ $# -gt 0 ]; do
    case "$1" in
        -p)             PROFILE_FILE="${2:?-p needs a file}"; shift 2;;
        --profile=*)    PROFILE_FILE="${1#*=}"; shift;;
        --turbo=*)      CLI_CFG[TURBO]="${1#*=}"; shift;;
        --pinfreq=*)    CLI_CFG[PINFREQ]="${1#*=}"; shift;;
        --pinfreq-target=*) CLI_CFG[PINFREQ_TARGET]="${1#*=}"; shift;;
        --cstate=*)     CLI_CFG[CSTATE]="${1#*=}"; shift;;
        --smt=*)        CLI_CFG[SMT]="${1#*=}"; shift;;
        --thp=*)        CLI_CFG[THP]="${1#*=}"; shift;;
        --thp-defrag=*) CLI_CFG[THP_DEFRAG]="${1#*=}"; shift;;
        --governor=*)   CLI_CFG[GOVERNOR]="${1#*=}"; shift;;
        --epp=*)        CLI_CFG[EPP]="${1#*=}"; shift;;
        --swappiness=*) CLI_CFG[SWAPPINESS]="${1#*=}"; shift;;
        --numa-balancing=*) CLI_CFG[NUMA_BALANCING]="${1#*=}"; shift;;
        --aslr=*)       CLI_CFG[ASLR]="${1#*=}"; shift;;
        --nmi-watchdog=*) CLI_CFG[NMI_WATCHDOG]="${1#*=}"; shift;;
        --drop-caches=*) CLI_CFG[DROP_CACHES]="${1#*=}"; shift;;
        --nvidia-persist=*) CLI_CFG[NVIDIA_PERSIST]="${1#*=}"; shift;;
        --nvidia-clock=*)   CLI_CFG[NVIDIA_CLOCK]="${1#*=}"; shift;;
        --amdgpu-perf=*)    CLI_CFG[AMDGPU_PERF]="${1#*=}"; shift;;
        --rocm-perf=*)      CLI_CFG[ROCM_PERF]="${1#*=}"; shift;;
        --temp-warn=*)  CLI_CFG[TEMP_WARN]="${1#*=}"; shift;;
        --mem-max=*)    CLI_CFG[MEM_MAX]="${1#*=}"; shift;;
        --load-max=*)   CLI_CFG[LOAD_MAX]="${1#*=}"; shift;;
        --swap-max=*)   CLI_CFG[SWAP_MAX]="${1#*=}"; shift;;
        --dirty-max=*)  CLI_CFG[DIRTY_MAX]="${1#*=}"; shift;;
        --freq-dip=*)   CLI_CFG[FREQ_DIP]="${1#*=}"; shift;;
        --sample=*)     CLI_CFG[SAMPLE]="${1#*=}"; shift;;
        --logs=*)       CLI_CFG[LOGS]="${1#*=}"; shift;;
        --state=*)      CLI_CFG[STATE]="${1#*=}"; shift;;
        --paranoid=*)   PARANOID_VAL="${1#*=}"
                        case "$PARANOID_VAL" in
                            -1|0|1|2|3|4) ;;
                            *) echo "Invalid value '$PARANOID_VAL' for --paranoid (use -1,0,1,2,3,4)" >&2; exit 1;;
                        esac
                        shift;;
        --)             shift; RUN_ARGS=("$@"); break;;
        -*)             echo "Unknown flag: $1" >&2; usage;;
        *)  if [ "$CMD" = profile ] && [ -z "$PPATH" ]; then PPATH="$1"; shift
            else echo "Unexpected argument: $1 (benchmark command goes after --)" >&2; usage; fi;;
    esac
done

finalize_cfg

if [ -n "$PARANOID_VAL" ] && [ "$CMD" != trace-unlock ]; then
    echo "--paranoid=N is only valid with 'trace-unlock'" >&2; usage
fi

case "$CMD" in
    status)       show_status ;;
    cpu)          show_cpu ;;
    core)         show_core ;;
    bench)        apply_bench ;;
    restore)      do_restore ;;
    verify)       do_verify ;;
    run)          [ ${#RUN_ARGS[@]} -ge 1 ] || { echo "run needs: -- <command>" >&2; usage; }
                  do_run "${RUN_ARGS[@]}" ;;
    profile)      case "$PACTION" in
                      new)  profile_new "$PPATH" ;;
                      show) profile_show ;;
                      *)    echo "profile subcommand: new [path] | show" >&2; usage;;
                  esac ;;
    trace-unlock) do_trace_unlock ;;
    trace-lock)   do_trace_lock ;;
    *)            usage ;;
esac
