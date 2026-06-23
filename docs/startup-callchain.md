# Startup & Sysimage Call Chain

## Overview

Three execution contexts run `bin/trimnalyser.jl`, each with different Julia flags and environment. All three must provide `--project` (so Julia resolves `TrimAnalyser` name → UUID via load path) and `TRIMNALYSER_SYSIMAGE=1` (so `import Pkg` is skipped, avoiding stdlib precompilation).

```
./trimnalyser [flags] [args]
│
├─ 1. build_sysimage.jl          (julia --startup-file=no, no sysimage)
│     stale() check → PackageCompiler.create_sysimage([:TrimAnalyser])
│     Writes: trimnalyser.so + trimnalyser.so.juliaversion
│
├─ 2. Main process                (julia --sysimage X --project=ROOT)
│     bin/trimnalyser.jl → TRIMNALYSER_SYSIMAGE=1 → skip Pkg → using TrimAnalyser
│     → main(ARGS) → parse_config! → _run_main
│     │
│     ├─ Single instance (no allgraphs): run_instance_full(ins)
│     │   Runs trimnalyse() in-process (no subprocess). Grim/Clit modes, verify, resolv.
│     │
│     └─ Batch/allgraphs: Threads.@threads → run_instance_batch(ins)
│         │
│         ├─ solve: runsipsolver() — runs Glasgow solver in-thread
│         ├─ trim:  run_trim_subprocess() — spawns child Julia [3]
│         ├─ verif: verify() — runs VeriPB in-thread
│         └─ resolv: run_resolv_loop() — alternates solve + trim subprocess
│
└─ 3. Trim subprocess             (julia --sysimage X --project=ROOT -t1,1)
      bin/trimnalyser.jl → TRIMNALYSER_SYSIMAGE=1 → skip Pkg → using TrimAnalyser
      → main([proofs_dir, ins, "subprocess", ...]) → trimnalyseandcie(ins)
      Trim-only. Writes .smol.opb/.smol.pbp. Exits. SIGTERM → exit 124.
```

## Sysimage contract

Julia 1.12 requires the package to be resolvable in the active load path (via `--project`) **before** it checks `Base.loaded_modules` from the sysimage. `--sysimage` alone is not enough; `using TrimAnalyser` will fail with "Package not found" if there is no load path entry.

The three flags must be consistent across all contexts that do `using TrimAnalyser`:

| Context | `--sysimage` | `--project` | `TRIMNALYSER_SYSIMAGE` | Who sets it |
|---------|:---:|:---:|:---:|---|
| build_sysimage.jl | no | `Pkg.activate(ROOT)` | n/a | build script |
| Main process | bash wrapper | bash wrapper | bash wrapper (`export`) | `trimnalyser` line 34 |
| Trim subprocess | `orchestrator.jl:216` | `orchestrator.jl:216` | `orchestrator.jl:218` | `run_trim_subprocess` |

**Staleness rule**: `build_sysimage.jl:stale()` checks `src/*.jl`, `Project.toml`, `Manifest.toml` mtime vs `trimnalyser.so`. Any change to `src/` triggers a rebuild (~2 min). Beware: runtime-only changes (e.g. subprocess launch flags) are compiled into the sysimage too, so they can't be tested without rebuilding.

## bin/trimnalyser.jl — the entry script

```
if !haskey(ENV, "TRIMNALYSER_SYSIMAGE")    ← gate: skip Pkg when sysimage active
    import Pkg                               ← triggers stdlib precompilation in Julia 1.12
    Pkg.activate(...)                        ← sets load path
    Pkg.instantiate()                        ← may precompile TrimAnalyser (conflicts with sysimage)
end
using TrimAnalyser                           ← needs: name in load path + module in sysimage
TrimAnalyser.main(ARGS)
```

`import Pkg` itself (not just `Pkg.instantiate`) triggers Julia 1.12 stdlib precompilation (~30s+). This is why `TRIMNALYSER_SYSIMAGE` skips the entire block, not just `instantiate`.

## run_trim_subprocess — the subprocess launcher

`orchestrator.jl:208–256`. Launches `timeout $tt julia $flags bin/trimnalyser.jl $ins subprocess ...`.

- stdout/stderr captured to `.subout`/`.suberr` temp files (avoids interleaving from 75+ threads)
- On non-timeout exit, `.suberr` is printed to parent stderr (line 237) — this is where "Package not found" errors surface
- On timeout (exit 124), `.suberr` is discarded (contains only spurious SIGTERM backtrace)
- Memory gate: waits until `available_memory() > minfreemem` before spawning

## run_instance_batch vs run_instance_full

Both implement the solve→trim→verify→resolv pipeline. **Any change to one must be mirrored in the other.**

| | `run_instance_batch` | `run_instance_full` |
|---|---|---|
| Used when | `allgraphs` / batch mode | Single instance, no `subprocess` flag |
| Trim step | `run_trim_subprocess` (child Julia) | `trimnalyse()` in-process |
| GC isolation | Yes (separate heap per instance) | No (shared heap) |
| Resolv | `run_resolv_loop(ins, true, ...)` — subprocess trim | `run_resolv_loop(ins, false)` — in-process trim |

## Debugging sysimage issues

1. **Check if error is main or subprocess**: subprocess errors are prefixed by instance name or appear in `.suberr` files; main process errors are raw stacktraces
2. **Skip sysimage**: `nosys` flag bypasses sysimage build+use entirely (slower startup but no sysimage interactions)
3. **Force rebuild**: delete `trimnalyser.so` then run
4. **Prevent rebuild** (when testing non-code changes): not possible for `src/` changes — staleness check covers all `.jl` files in `src/`

## Known fragility

**Sysimage flag triad is fragile.** Three flags (`--sysimage`, `--project`, `TRIMNALYSER_SYSIMAGE`) must be set consistently across bash wrapper + subprocess launcher. They are set independently in two places (`trimnalyser:34`, `orchestrator.jl:214–218`) with no shared definition. A single constant or helper like `sysimage_julia_cmd()` returning the complete `Cmd` + env pairs would eliminate the duplication.
