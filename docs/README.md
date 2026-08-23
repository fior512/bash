# doc.sh

Terminal reference for x86 asm, SIMD intrinsics, and (optionally) C++ stdlib docs. Covers instruction encoding, registers, memory-size keywords, intrinsics, and per-CPU latency/throughput.

## Usage

```bash
doc update                     # download/refresh all data files (asm/simd/perf)
doc arch                       # show detected CPU arch + all valid --arch values

doc asm mov                    # instruction encoding, flags, perf
doc asm reg rsp                # register reference (role, ABI, alignment)
doc asm size qword              # memory transfer size / PTR keyword reference

doc simd vaddps                 # SIMD instruction or intrinsic lookup
doc simd _mm256_fmadd_ps
doc simd load                   # op word: name-first match, decomposed into
                                 # vector/func/suffix axes (defs mined live, no static glossary)
doc simd epi8                   # bare suffix token: shown with its sibling widths
                                 # (epi8/16/32/64/64x, epu8/16/32/64, ...)
doc simd _mm_store_si128        # exact intrinsic: full detail + the same
                                 # vector/func/suffix decomposition
doc simd list avx2 arithmetic   # list intrinsics by ISA + category
doc simd vec avx2               # vectorization concept cheatsheets

doc cpp std::vector             # requires cppman

doc --arch SKL asm mulps        # override microarch for perf numbers
```

Run `doc help` for the full option/category list.

## Implementation

| | |
|---|---|
| Lines | 2001 |
| Dependencies | `bash`, `xmlstarlet`, `curl` (for `doc update`), `awk`, `less`, `fold`, `tput` (from `ncurses`); `cppman` only for the `cpp` category |
| Parametrization | `DOC_ARCH` env var overrides the auto-detected CPU microarch (also settable per-call with `--arch`). `DATADIR` env var overrides where data files live, default `<script dir>/data`. |

`doc update` downloads `x86reference.xml`, `intrinsics.xml`, `uops.xml` on demand and caches them in `DATADIR`. Nothing is bundled. Arch auto-detection reads `/proc/cpuinfo`. Lookups run `xmlstarlet` XPath queries against the cached XML, then pipe through `less`.

SIMD concept/family/decomposition output colorizes and wraps to the real terminal width (`tput cols`, falls back to 80 off-tty). No static glossary: definitions come from the naming grammar (width/sign parsed from the token, cross-checked against the XML's return types) or get mined live from the matched intrinsics' own `<description>` text.
