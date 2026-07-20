# doc.sh

Terminal reference tool for x86 assembly, SIMD intrinsics, and (optionally) C++ stdlib docs. Looks up instruction encoding, registers, memory-size keywords, SIMD intrinsics, and per-CPU latency/throughput numbers, without leaving the terminal.

## Usage

```bash
doc update                     # download/refresh all data files (asm/simd/perf)
doc arch                       # show detected CPU arch + all valid --arch values

doc asm mov                    # instruction encoding, flags, perf
doc asm reg rsp                # register reference (role, ABI, alignment)
doc asm size qword              # memory transfer size / PTR keyword reference

doc simd vaddps                 # SIMD instruction or intrinsic lookup
doc simd _mm256_fmadd_ps
doc simd list avx2 arithmetic   # list intrinsics by ISA + category
doc simd vec avx2               # vectorization concept cheatsheets

doc cpp std::vector             # requires cppman

doc --arch SKL asm mulps        # override microarch for perf numbers
```

Run `doc help` for the full option/category list.

## Implementation

| | |
|---|---|
| Lines | 1344 |
| Dependencies | `bash`, `xmlstarlet`, `curl` (for `doc update`), `awk`, `less`; `cppman` only for the `cpp` category |
| Parametrization | `DOC_ARCH` env var overrides the auto-detected CPU microarch (also settable per-call with `--arch`). `DATADIR` env var overrides where data files live, default `<script dir>/data`. |

Data files (`x86reference.xml`, `intrinsics.xml`, `uops.xml`) are downloaded on demand via `doc update` and cached in `DATADIR`; nothing is bundled. Arch auto-detection reads `/proc/cpuinfo`. Lookups are done with `xmlstarlet` XPath queries against the cached XML, formatted and piped through `less`.
