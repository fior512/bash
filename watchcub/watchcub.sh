#!/usr/bin/env bash
#
# watchcub - one-command system tuning + run-condition logging for benchmarks
# ----------------------------------------------------------------------------
#   sudo ./watchcub.sh status                  show current settings (read-only)
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
# Flags (each maps to a profile key of the same name):
#   --turbo=keep|off       --pinfreq=on|off      --cstate=hold|keep
#   --smt=keep|off         --thp=always|never|keep
#   --temp-warn=<C>       --mem-max=<pct>       --load-max=<frac>
#   --swap-max=<kB>        --dirty-max=<kB>      --freq-dip=<frac>
#   --sample=<sec>         --logs=<dir>          --state=<dir>
#   --profile=<file> | -p <file>
#
# Pure bash + /proc + /sys, everything feature-detected. Handles intel_pstate,
# amd-pstate(-epp), acpi-cpufreq. AMD: no thermal_throttle counters, so
# throttling = hwmon temp + freq-dip check; min-freq pin reads
# scaling_max_freq AFTER the boost decision.
set -u

CPU_SYS=/sys/devices/system/cpu

# ===================================================== configuration ========
# keys + defaults + docs; 'profile new' generates from these, keep in sync
CFG_KEYS=(TURBO PINFREQ CSTATE SMT THP
          TEMP_WARN MEM_MAX LOAD_MAX SWAP_MAX DIRTY_MAX FREQ_DIP SAMPLE)
declare -A CFG=(
  [TURBO]=keep   [PINFREQ]=on   [CSTATE]=hold  [SMT]=keep  [THP]=always
  [TEMP_WARN]=65 [MEM_MAX]=40   [LOAD_MAX]=0.05
  [SWAP_MAX]=65536 [DIRTY_MAX]=102400 [FREQ_DIP]=0.97 [SAMPLE]=0.5
)
declare -A CFG_DOC=(
  [TURBO]="keep = full boost clocks (highest perf) | off = fixed base clock (max reproducibility)"
  [PINFREQ]="on = floor ALL cores at max freq (all-core throughput) | off = idle cores idle (max single-core boost)"
  [CSTATE]="hold = block deep C-states (lowest wake latency) | keep = allow CC6 (frees single-core boost budget on Zen)"
  [SMT]="keep = leave hyperthreading as-is | off = disable SMT for the session"
  [THP]="always | never | keep - transparent hugepages mode"
  [TEMP_WARN]="C - verify/run warn when hottest sensor reaches this"
  [MEM_MAX]="percent - verify warns when used RAM exceeds this"
  [LOAD_MAX]="fraction of nproc - verify warns when 1-min load exceeds this"
  [SWAP_MAX]="kB - verify warns when swap in use exceeds this"
  [DIRTY_MAX]="kB - verify warns when dirty pages exceed this"
  [FREQ_DIP]="fraction - run warns when benchmark core dips below this x its max"
  [SAMPLE]="seconds - freq/temp sampling interval during run"
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
        case " ${CFG_KEYS[*]} " in *" $k "*) cfg_set "$k" "$v" "profile $1";;
            *) echo "Unknown key '$k' in $1 (ignored)" >&2;; esac
    done < "$1"
}
finalize_cfg() {
    apply_env
    [ -n "$PROFILE_FILE" ] && load_profile "$PROFILE_FILE"
    local k; for k in "${!CLI_CFG[@]}"; do cfg_set "$k" "${CLI_CFG[$k]}" "flag"; done
    # short names used in the script body
    TURBO_MODE=${CFG[TURBO]};   PINFREQ_MODE=${CFG[PINFREQ]}
    CSTATE_MODE=${CFG[CSTATE]}; SMT_MODE=${CFG[SMT]}; THP_MODE=${CFG[THP]}
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
profile_new() {
    local path="${1:-./watchcub.profile}"
    [ -e "$path" ] && { echo "Refusing to overwrite existing $path" >&2; exit 1; }
    { echo "# watchcub profile - generated $(ts)"
      echo "# KEY=VALUE, # comments ignored. Not auto-loaded: pass it with"
      echo "#   watchcub bench -p $path"
      echo "#"
      local k
      for k in "${CFG_KEYS[@]}"; do
          printf '\n# %s\n%s=%s\n' "${CFG_DOC[$k]}" "$k" "${CFG[$k]}"
      done
    } > "$path"
    echo "Wrote $path - edit it, then: sudo ./watchcub.sh bench -p $path"
}
profile_show() {
    info "Effective configuration"
    local k
    for k in "${CFG_KEYS[@]}"; do log "$k" "${CFG[$k]}"; done
    log "config source" "$PROFILE_SOURCE"
    log "state dir" "$STATE_DIR"
    log "log dir"   "$LOG_ROOT"
}

# ============================================================ bench ==========
apply_bench() {
    need_root
    action_log "bench $(cfg_summary)"
    [ -e "$STATE_DIR/.bench-active" ] && { echo "bench already applied; restore first."; exit 1; }
    mkdir -p "$STATE_DIR"; : > "$STATE_DIR/.bench-active"
    cfg_summary > "$STATE_DIR/profile"

    info "CPU governor & EPP"
    for_each_policy scaling_governor performance
    for_each_policy energy_performance_preference performance

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

    info "Min-freq pinning (mode: $PINFREQ_MODE)"
    if [ "$PINFREQ_MODE" = on ]; then
        local p maxf
        for p in "$CPU_SYS"/cpufreq/policy*; do [ -d "$p" ] || continue
            maxf=$(rd "$p/scaling_max_freq"); [ -n "$maxf" ] || continue
            save_write "$p/scaling_min_freq" "$maxf" "$(basename "$p")_scaling_min_freq"; done
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
    save_sysctl vm.swappiness 1
    save_sysctl kernel.numa_balancing 0
    save_sysctl kernel.randomize_va_space 0
    save_sysctl kernel.nmi_watchdog 0
    case "$THP_MODE" in
      keep) log "THP" "kept as-is";;
      *)  save_write /sys/kernel/mm/transparent_hugepage/enabled "$THP_MODE" thp_enabled
          save_write /sys/kernel/mm/transparent_hugepage/defrag  never thp_defrag;;
    esac
    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && log "page cache" "dropped"

    info "SMT (mode: $SMT_MODE)"
    if [ "$SMT_MODE" = off ]; then save_write "$CPU_SYS/smt/control" off smt_control
    else log "SMT" "kept as-is"; fi

    info "GPU"
    if have nvidia-smi; then
        nvidia-smi -pm 1 >/dev/null 2>&1 && log "NVIDIA persistence" "on"
        local msm mmem
        msm=$(nvidia-smi --query-gpu=clocks.max.sm     --format=csv,noheader,nounits 2>/dev/null | head -1)
        mmem=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -1)
        [ -n "${msm:-}" ]  && nvidia-smi -lgc "$msm"  >/dev/null 2>&1 && { touch "$STATE_DIR/nvidia_locked"; log "NVIDIA SM clock" "locked ${msm}MHz"; }
        [ -n "${mmem:-}" ] && nvidia-smi -lmc "$mmem" >/dev/null 2>&1 && log "NVIDIA mem clock" "locked ${mmem}MHz"
    fi
    local c
    for c in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$c" ] && save_write "$c" high "amdgpu_$(echo "$c"|grep -o 'card[0-9]*')_perf"; done
    have rocm-smi && rocm-smi --setperflevel high >/dev/null 2>&1 && log "rocm-smi perflevel" "high"

    info "Done - now: sudo $0 verify   then: sudo $0 run -- <benchmark cmd>"
}

# ==================================================== trace-(un)lock =========
TRACE_KNOBS=( "kernel.perf_event_paranoid=-1" "kernel.kptr_restrict=0"
              "kernel.yama.ptrace_scope=0" "net.core.bpf_jit_enable=1"
              "kernel.ftrace_enabled=1" )
do_trace_unlock() { need_root; action_log trace-unlock; mkdir -p "$STATE_DIR"
    info "Loosening perf/eBPF sysctls (dedicated bench box only!)"
    local kv; for kv in "${TRACE_KNOBS[@]}"; do save_sysctl "${kv%%=*}" "${kv#*=}"; done; }
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
Commands: status | bench | verify | run -- <cmd> | restore
          profile new [path] | profile show | trace-unlock | trace-lock
Flags:    --turbo=keep|off --pinfreq=on|off --cstate=hold|keep --smt=keep|off
          --thp=always|never|keep --temp-warn=C --mem-max=PCT --load-max=FRAC
          --swap-max=KB --dirty-max=KB --freq-dip=FRAC --sample=SEC
          --logs=DIR --state=DIR --profile=FILE | -p FILE
Precedence: flags > profile file > WATCHCUB_* env > defaults.
Profiles are never auto-loaded; pass one with -p FILE or \$WATCHCUB_PROFILE.
EOF
    exit 1
}

declare -A CLI_CFG=()
RUN_ARGS=()
CMD="${1:-}"; [ $# -gt 0 ] && shift
PACTION=""; PPATH=""
if [ "$CMD" = profile ]; then PACTION="${1:-show}"; [ $# -gt 0 ] && shift; fi

while [ $# -gt 0 ]; do
    case "$1" in
        -p)             PROFILE_FILE="${2:?-p needs a file}"; shift 2;;
        --profile=*)    PROFILE_FILE="${1#*=}"; shift;;
        --turbo=*)      CLI_CFG[TURBO]="${1#*=}"; shift;;
        --pinfreq=*)    CLI_CFG[PINFREQ]="${1#*=}"; shift;;
        --cstate=*)     CLI_CFG[CSTATE]="${1#*=}"; shift;;
        --smt=*)        CLI_CFG[SMT]="${1#*=}"; shift;;
        --thp=*)        CLI_CFG[THP]="${1#*=}"; shift;;
        --temp-warn=*)  CLI_CFG[TEMP_WARN]="${1#*=}"; shift;;
        --mem-max=*)    CLI_CFG[MEM_MAX]="${1#*=}"; shift;;
        --load-max=*)   CLI_CFG[LOAD_MAX]="${1#*=}"; shift;;
        --swap-max=*)   CLI_CFG[SWAP_MAX]="${1#*=}"; shift;;
        --dirty-max=*)  CLI_CFG[DIRTY_MAX]="${1#*=}"; shift;;
        --freq-dip=*)   CLI_CFG[FREQ_DIP]="${1#*=}"; shift;;
        --sample=*)     CLI_CFG[SAMPLE]="${1#*=}"; shift;;
        --logs=*)       LOG_ROOT="${1#*=}"; shift;;
        --state=*)      STATE_DIR="${1#*=}"; shift;;
        --)             shift; RUN_ARGS=("$@"); break;;
        -*)             echo "Unknown flag: $1" >&2; usage;;
        *)  if [ "$CMD" = profile ] && [ -z "$PPATH" ]; then PPATH="$1"; shift
            else echo "Unexpected argument: $1 (benchmark command goes after --)" >&2; usage; fi;;
    esac
done

finalize_cfg

case "$CMD" in
    status)       show_status ;;
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
