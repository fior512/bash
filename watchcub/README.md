# watchcub 🐻

One script that puts a Linux box into good state for benchmarking, watches the machine while your benchmark runs, tells you whether the result can be trusted, and puts everything back exactly how it was.

No dependencies. One file. Works on any distro, any CPU vendor.

---

## Table of contents

1. [Why](#why)
2. [Requirements](#requirements)
3. [Install](#install)
4. [Quick start](#quick-start)
5. [Commands](#commands)
6. [Parameters](#parameters)
7. [Profiles](#profiles)
8. [Choosing a profile: throughput vs latency](#choosing-a-profile-throughput-vs-latency)
9. [Output files](#output-files)
10. [Reading the run report](#reading-the-run-report)
11. [What bench actually changes](#what-bench-actually-changes)
12. [Hardware notes](#hardware-notes)
13. [Limits](#limits)

---

## Why

A benchmark number without its machine state is hearsay. Governor, boost, thermals, memory pressure, a stray compile job - any of these silently shifts results. watchcub makes the state explicit: set up, verify, record, revert.

## Requirements

- Linux, any distro (Arch, Debian, Ubuntu, Fedora, ...). Kernel from the last decade.
- bash + coreutils + awk. Everything else is optional and feature-detected:
  - `lscpu`, `numactl` -> richer sysinfo capture if present
  - `nvidia-smi` / `rocm-smi` -> GPU clock locking if present
  - procps `ps` -> per-thread placement sampling if present
- root (`sudo`) for anything that writes; `status`, `verify`, `profile` read fine without.
- Any CPU: intel_pstate, amd-pstate(-epp), acpi-cpufreq are all handled. Knobs that don't exist on your machine are skipped, not fatal.

## Install

```sh
curl -O https://raw.githubusercontent.com/fior512/bash/main/watchcub/watchcub.sh    # or copy the file
chmod +x watchcub.sh
sudo ln -s "$PWD/watchcub.sh" /usr/local/bin/watchcub   # optional
```

## Quick start

```sh
sudo watchcub status           # print current state
sudo watchcub bench            # save current state, apply performance profile
sudo watchcub verify           # pre-flight: is the box actually ready?
sudo watchcub run -- ./mybench # run it, sample conditions
sudo watchcub restore          # put every setting back exactly as it was
```

Per-project setup (optional):

```sh
cd myproject/
watchcub profile new              # writes ./watchcub.profile
vim watchcub.profile              # tune it once for this project
sudo watchcub bench -p watchcub.profile
```

## Commands

| Command | Root | What it does |
|---|---|---|
| `status` | no | Dump current CPU/kernel/GPU/thermal settings. Read-only. |
| `bench [flags]` | yes | Save current values, then apply the performance profile. Refuses to double-apply. |
| `verify [flags]` | no | Pre-flight checklist (governor, load, RAM, swap, temp, steal, dirty pages). Exit code = warning count, so you can gate scripts on it. |
| `run [flags] -- CMD...` | no* | Run CMD while sampling per-core frequency, temperature, and thread placement. Writes a full log directory. |
| `restore` | yes | Revert every value that `bench`/`trace-unlock` saved. Deletes the state dir. |
| `profile new [path]` | no | Write an editable, commented profile file (default `./watchcub.profile`). Won't overwrite. |
| `profile show [flags]` | no | Print the effective configuration and where each part came from. |
| `trace-unlock` | yes | Loosen `perf_event_paranoid`, `kptr_restrict`, ptrace scope, eBPF JIT - for `perf`/uProf/VTune sessions. Reverted by `trace-lock` or `restore`. |
| `trace-lock` | yes | Re-tighten the above. |

\* `run` itself needs no root, but reading some sensors and the settings snapshot is richer with it.

## Parameters

Every parameter can be set four ways. Highest wins:

```
CLI flag  >  profile file  >  WATCHCUB_<KEY> env var  >  built-in default
```

| Key | Flag | Default | Meaning |
|---|---|---|---|
| `TURBO` | `--turbo=` | `keep` | `keep` = full boost clocks (highest performance). `off` = fixed base clock (max run-to-run reproducibility for sustained workloads). |
| `PINFREQ` | `--pinfreq=` | `on` | `on` = floor **all** cores at max freq (best for all-core throughput). `off` = idle cores may idle (best for 1-few-thread runs: preserves single-core boost headroom). |
| `CSTATE` | `--cstate=` | `hold` | `hold` = block deep C-states (lowest wake latency). `keep` = allow CC6 (idle cores sleeping frees boost budget on AMD Zen). |
| `SMT` | `--smt=` | `keep` | `off` disables hyperthreading/SMT for the session. |
| `THP` | `--thp=` | `always` | Transparent hugepages: `always`, `never`, or `keep` current. |
| `TEMP_WARN` | `--temp-warn=` | `65` | C. verify/run warn when the hottest sensor reaches this. |
| `MEM_MAX` | `--mem-max=` | `40` | %. verify warns when used RAM exceeds this. |
| `LOAD_MAX` | `--load-max=` | `0.05` | Fraction of nproc. verify warns when 1-min load exceeds it. |
| `SWAP_MAX` | `--swap-max=` | `65536` | kB. verify warns when swap in use exceeds this. |
| `DIRTY_MAX` | `--dirty-max=` | `102400` | kB. verify warns on pending writeback above this. |
| `FREQ_DIP` | `--freq-dip=` | `0.97` | run warns when the benchmark core's min freq drops below this x its max (throttling detector). |
| `SAMPLE` | `--sample=` | `0.5` | Seconds between freq/temp samples during run. |

Non-profile flags: `--profile=FILE` / `-p FILE`, `--logs=DIR` (default `/var/tmp/watchcub-logs`), `--state=DIR` (default `/var/tmp/watchcub-state`).

Examples:

```sh
sudo watchcub bench --turbo=off --smt=off          # reproducibility profile
sudo watchcub bench --pinfreq=off --cstate=keep    # max single-core boost
sudo watchcub run --sample=0.1 -- ./mybench        # finer sampling
sudo watchcub bench -p profiles/ci.profile         # explicit profile file
```

## Profiles

`watchcub profile new` writes a plain `KEY=VALUE` file with every parameter, its default, and a one-line comment. Edit it, commit it next to your benchmark code.

Profiles are never auto-loaded. Pass one with `-p/--profile FILE`, or set `$WATCHCUB_PROFILE`; no file given means built-in defaults. Unknown keys are ignored with a warning; invalid values abort naming the offending source.

`watchcub profile show` prints the effective config and where each value came from - use it whenever precedence is in doubt.

## Choosing a profile: throughput vs latency

Two physical regimes, two profiles:

**All-core throughput** (HPC kernels, compiles, renders): defaults are right. `PINFREQ=on CSTATE=hold` keeps every core hot. Add `TURBO=off` when comparing runs across days/machines - all-core boost sags with temperature.

**Single/few-thread latency** (microbenchmarks, cycle counting): `PINFREQ=off CSTATE=keep`. Zen grants the top single-core boost bin only when the other cores sleep in deep C-states; forcing all cores to max caps your busy core at the lower all-core boost. Measured on a Ryzen 7600X: ~5.45 GHz latency profile vs ~5.3 GHz throughput profile - a 2% bias on every cycle count.

## Output files

Every `run` creates `LOGS/run-YYYYMMDD-HHMMSS/`:

| File | Contents |
|---|---|
| `report.txt` | The condition report (same text printed to the terminal). |
| `sysinfo.txt` | Kernel, distro, boot cmdline, lscpu, NUMA topology, RAM, effective config, full settings snapshot at run time. |
| `command.txt` | The exact command line executed. |
| `stdout.log` / `stderr.log` | The benchmark's own output (also streamed live). |
| `freq.csv` | Timestamped frequency of every core. Header row maps columns to `policyN` names, column order is lexicographic. |
| `temp.csv` | Timestamped hottest-sensor readings (millidegrees). |
| `threads.log` | Samples of every benchmark thread: TID, which CPU it was on, scheduler class, RT priority, %CPU. Shows thread migration and scheduling policy. |

State-changing commands (`bench`, `restore`, `trace-*`) also append their output, timestamped, to `LOGS/actions.log` - an audit trail of what changed when.


## Reading the run report

```
benchmark-core freq   min=5448000 avg=5449333 max=5451000 kHz (policy3, 9 samples)
fastest freq seen (any core)                 5451000 kHz
[ OK ] peak temperature: 56C
[ OK ] no swap activity
[ OK ] major page faults: 0
context switches                             4921
[ OK ] no CPU steal during run
threads observed                             1
ran on CPUs                                  3
scheduler classes                            TS (TS=CFS/EEVDF, FF/RR=realtime)
```

- **benchmark-core freq**: busiest core only (the one your benchmark ran on); idle cores at min freq are normal and ignored. A `[WARN]` here means throttling or contention mid-run - the usual reason "run 3 was slower".
- **peak temperature**: hottest sensor during the run, judged against `TEMP_WARN`.
- **swap / major faults**: memory pressure and mid-run disk reads. Build first, measure the binary.
- **CPU steal**: nonzero means a hypervisor took cycles; results on shared VMs are suspect.
- **ran on CPUs / scheduler classes**: where threads actually executed, under which policy. Spots unwanted migration; pin with `taskset` if it matters.

## What bench actually changes

Everything is read and saved *before* being written, so `restore` is exact, not "back to distro defaults".

- CPU: governor and EPP -> `performance` on every policy, boost per `TURBO`, min-freq per `PINFREQ` (pinned against `scaling_max_freq` after the boost decision, so it's correct with boost off), SMT per `SMT`. C-states per `CSTATE` via a PM-QoS hold on `/dev/cpu_dma_latency` (background holder process, killed on restore).
- Kernel/memory: `swappiness=1`, NUMA balancing off, ASLR off, NMI watchdog off (frees a PMU counter for `perf`), THP per `THP`, page cache dropped once.
- GPU: NVIDIA persistence mode + SM/mem clocks locked to max (`-lgc`/`-lmc`), amdgpu `power_dpm_force_performance_level=high`, rocm-smi perflevel high.
- Tracing (only via `trace-unlock`): `perf_event_paranoid=-1`, `kptr_restrict=0`, ptrace scope 0, eBPF JIT on. Security-loosening - dedicated bench boxes only.

## Hardware notes

- **AMD Zen (Ryzen/EPYC)**: boost is controlled globally; per-policy `boost` files (kernels >= 6.11) are the fallback. No Intel-style throttle counters - throttling is detected via hwmon temperature (k10temp Tctl) plus the frequency-dip check. `amd_pstate=active` on the cmdline gives the EPP knob (`status` shows the driver mode). With `prefcore` the scheduler already favors best-binned cores; `amd_pstate_prefcore_ranking` in each policy dir tells you which to `taskset` onto.
- **Intel**: `intel_pstate/no_turbo` handles boost; `thermal_throttle` counters give exact throttle-event counts before/after runs.
- **VMs/containers**: cpufreq and sensors are usually absent - watchcub degrades to the checks that still work (load, RAM, swap, steal, faults) and says so instead of failing.

## Limits

Things watchcub can't do from userspace, worth knowing about:

- BIOS-level settings: PBO/Curve Optimizer, power limits, memory timings. The only route past stock boost clocks.
- Kernel boot parameters: `isolcpus`, `nohz_full`, `rcu_nocbs`; the cure for the last microsecond of tick/RCU jitter on a pinned core. Needs a reboot.
- IRQ steering: stop `irqbalance` and mask your benchmark core out of `/proc/irq/*/smp_affinity` for the quietest possible core.
- watchcub observes conditions; it does not repeat runs or do statistics on your results. Pair it with your benchmark harness's own repetition/aggregation.
