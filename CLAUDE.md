# CLAUDE.md

## Testing Constraints

**Local disk can't hold the full benchmark set.**

- **Never** run without specifying an instance name or without reading memory first.
- **Standard local test** after any code change:
  ```bash
  ./trimnalyser LVg10g12 overwrite resolv
  ```
  Proof files at `/home/arthur_gla/veriPB/subgraphsolver/proofs/`. This instance is 858 KB OPB + 24 MB PBP and exercises the full resolv loop.
- **Syntax-only check** (no execution, zero disk writes):
  ```bash
  julia --startup-file=no -e 'for f in readdir("src"; join=true); endswith(f,".jl") && Meta.parseall(read(f,String)); end; println("OK")'
  ```

## Common Commands

```bash
./trimnalyser LVg10g12 overwrite resolv                                          # single instance
./trimnalyser LVg10g12 overwrite resolv verif cake config=gss-lazy               # one grid configuration (M7)
./trimnalyser --threads 92,1 solve resolv verif allgraphs minnodes=50 maxnodes=200 st=18 tt=600 rand  # cluster run
julia scripts/aggregate_results.jl /scratch/arthur/proofs/gss/gss-lazy cluster_results.csv /cluster/arthur/logs  # aggregate → CSV
bash scripts/bench_config.sh gss-lazy                                            # one grid column, specified timeouts
bash scripts/bench_config.sh gss-lazy 60 LVg10g12                               # ...at 1/60 timeouts, one instance
bash scripts/bench_all.sh 60                                                    # smoke-test all fourteen columns
bash scripts/lad_bench.sh lad_results.csv                                       # LAD columns (route 1, via ladveri)
julia scripts/merge_lad_results.jl cluster_results.csv lad_results.csv combined.csv
julia scripts/graph_features.jl /scratch/arthur/proofs/ graph_features.csv       # static graph features
julia scripts/quick_stats.jl cluster_results.csv                                 # terminal stats (stdlib only)
julia --project=scripts scripts/proof_survey.jl cluster_results.csv graph_features.csv proof_survey.html  # HTML report
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv classify_supplementals  # supplemental classifier
julia --project=scripts -e 'using Pkg; Pkg.instantiate()'                        # install script deps
julia --project=. build_sysimage.jl                                              # build sysimage (~5s → ~0.1s)
```

Key flags: `solve` (run SIP solver), `resolv` (iterative re-solve on UNSAT cores), `verif` (run VeriPB), `cake` (elaborate + CakeML check of the full proof), `overwrite`, `profile`, `allgraphs`, `bfs`/`clit` (alternative trim modes).
Timeout args: `st=N` (solver), `stnopl=N` (tier-1 non-logging solve, default 60; `0` disables it), `tt=N` (trim), `vt=N` (verif), `ct=N` (cake), `maxnodes=N`, `minnodes=N`.

### Configuration grid (M7)

`config=<key>` selects one of the fourteen entries in `SOLVER_CONFIGS` (`src/config.jl`),
one per column of the paper's appendix tables. Default `gss-lazy` = the old hardcoded
`--staged --no-clique-detection --prove`. Consequences to keep in mind:

- **Proofs are namespaced:** `<root>/proofs/<solver>/<config>/`. Two configurations of one
  instance no longer collide, and `config=` must stay in the `subargs` whitelist
  (`orchestrator.jl`) or trim subprocesses resolve a different directory.
- **Logs live outside the proof tree:** `/cluster/arthur/logs/<instance>.<solver>.<config>.out`
  (`$TRIMNALYSER_LOGS` locally), **append-only**, one `=== RUN <iso8601> <host> <config> ===`
  block per run. Readers must take the **last** block. The proof directory is deleted at last
  use; the log must survive that.
- **The solver's own stdout is separate:** `<ins>.solverout` in the proof directory, truncated
  per solve. The SAT/UNSAT verdict is grepped out of it, so it must never carry a previous
  run's. Glasgow reports the verdict as `status = true|false` — it never prints the word
  SATISFIABLE.
- **Two-tier solve:** a non-logging solve at `stnopl=` runs first. A `proves=false` config
  stops there (that solve is its table cell); for the others it gates the logging solve.
- **`cake` checks both proofs, with two different binaries.** `cake_pb <opb> <elab>` is generic
  and takes the OPB as given, so it checks the full *and* the trimmed proof of either solver;
  it claims only "this OPB is unsatisfiable" (encoding trusted, not checked). `cake_pb_iso
  <pat> <tar> <elab>` rebuilds the encoding from the graphs and makes the trusted end-to-end
  claim, but only works where the solver's model IS that encoding — LAD's `-O`, never Glasgow's,
  whose emission order differs. It is logged under a separate `cakeiso` key and run for `lad-*`
  only. Both **exit 0 on failure** and print to stderr; `s VERIFIED` on stdout is the only
  success signal. Cake needs the *elaborated* proof — the raw `.pbp` still carries `rup`.
- **`veripb -e` writes the elaboration's header before it checks anything**, so a rejected proof
  still leaves a ~40-byte file. The verdict must come from `VERIFIED` on stdout, never from the
  file's existence (`certify`, `src/output.jl`).
- **`lad-*` configs run through the same pipeline** since 2026-08-24 (`runladsolver`, dispatched
  by `runsolver`). Solve, full-verify and both Cake stages work; the **trim stage fails** on LAD
  proofs (`rup failed at ...` → cone half-built → constraint id `0` in the output). See ROADMAP
  M7.5. `bio` is excluded outright for every LAD configuration. LAD exits 0 even on its own
  timeout, so the verdict is grepped out of stdout (`Run completed: N solutions`).

### Cluster commands

```bash
# on cluster: aggregate + generate reports
bash scripts/harvest.sh
# on local: pull everything
bash scripts/harvest_pull.sh

# single instance test on cluster
./trimnalyser LVg10g12 overwrite solve resolv nosys

# verify labels are in .out
grep 'LABEL' /scratch/arthur/proofs/LVg10g12.out   # lines are "<mode> LABEL <TAG> <cone>/<full>", e.g. "grim LABEL INJ 37/48"

# rebuild sysimage on cluster
julia --project=. build_sysimage.jl
```

**`/scratch` is volatile** — it was recreated 2026-07-06, destroying `/scratch/arthur/` (proofs, benchmarks, both binaries). Three paths are hardcoded to it: `src/config.jl:41` (proofs), `src/TrimAnalyser.jl:24` (benchmarks), `src/TrimAnalyser.jl:26` (solver). Rebuild before any run:

```bash
mkdir -p /scratch/arthur/proofs
cp -r ~/newSIPbenchmarks /scratch/arthur/                                    # 102 MB
cp ~/glasgow-subgraph-solver/build/glasgow_subgraph_solver /scratch/arthur/
cp ~/veripb-dev/target/release/veripb /scratch/arthur/veripb                 # else verif silently no-ops
```

`verif` with no `veripb` at `/scratch/arthur/veripb` prints one yellow "veripb not found — skipping verif" line and completes the whole run unverified. Override the location with the `VERIPB` env var (`src/output.jl:522`).

**Building Glasgow after the 2026-07-08 reimage.** GMP dev headers are no longer installed system-wide and `sudo` isn't available; they live in `~/local`, unpacked from `.deb`s (`apt-get download` needs no privileges). Boost is *not* required — `gss/CMakeLists.txt` only looks for GMP/GMPXX.

```bash
cmake -S . -B build \
  -DGMP_INCLUDE_DIR=$HOME/local/include \
  -DGMP_LIBRARY=$HOME/local/lib/libgmp.so \
  -DGMPXX_LIBRARY=$HOME/local/lib/libgmpxx.so \
  -DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,$HOME/local/lib   # rpath: finds libgmpxx at run time
cmake --build build -j 48    # ~40s
```

**SSH is non-interactive and does not source `.bashrc`**, so `julia` isn't on `PATH`. Wrap remote commands: `ssh fataepyc-07 'bash -lc "..."'`. Long runs need `tmux`/`nohup` — each SSH is a fresh shell.

## Related projects

**LAD with VeriPB proof logging** — `~/ladveri` (`git@github.com:ArthurGontierPro/ladveri.git`). Since 2026-08-12 there is a *second* proof-producing SIP solver, verified end-to-end through CakeML. Relevant to M5: it can test whether our per-family proof fingerprints are instance properties or Glasgow artefacts. **Pilot-only — it has never run a real benchmark instance**, has no proof deletions, and emits no proof at all on clique instances. Read `ROADMAP.md` "M5-proof" for the full capability limits before planning any run.

Note the name clash: `writecoreladfile` (`src/solver.jl`) writes the LAD *graph file format*, which is unrelated to the LAD *solver*.

## Architecture

**Orchestrator mode** (no instance in ARGS, or `allgraphs`): spawns one subprocess per instance via `julia bin/trimnalyser.jl <instance>`. OOM monitor on `:interactive` thread polls `/proc` every 10s, kills trimmer subprocesses and Glasgow solver processes exceeding `maxmem=` GB. Solve/verif/resolv run in orchestrator threads with independent timeouts.

**Subprocess mode** (instance name in ARGS): trim-only. Writes `.smol.opb` + `.smol.pbp`, then exits. SIGTERM caught cleanly (exit 124). Output routed via `.subout` temp file to avoid interleaving.

### Source layout

| File | Contents |
|------|----------|
| `src/TrimAnalyser.jl` | Module root, static constants, include chain |
| `src/config.jl` | `Config` struct, `parse_config!`, `argflags` |
| `src/utilities.jl` | `available_memory`, file helpers |
| `src/types.jl` | Core structs: `FlatEqStore`, `SystemLink`, `PBSystem`, `Trail`, `Ante`, `PolScratch` |
| `src/parser.jl` | `readopb`, `readproof`, `tokenize!` |
| `src/pol.jl` | `PolScratch`, `solvepol_flat!` |
| `src/trimmer.jl` | `getcone!`, `ruptrail`, `process_eq!`, `conflicttrail` |
| `src/writer.jl` | `writeconedel`, `writeeq`, `writered`, `writepol` |
| `src/solver.jl` | `runsipsolver`, `resolvecore`, `writecoreladfile` |
| `src/output.jl` | `writeout_*`, `verify`, `printconestat`, statistics |
| `src/pipeline.jl` | `trimnalyseandcie`, `trimnalyse`, `smol_complete` |
| `src/orchestrator.jl` | `main()`, OOM monitor, instance enumeration |

### Key data structures

**`FlatEqStore`** — CSR-like flat storage for all parsed equations. Fields: `vars/coefs/signs/rhs` (flat arrays) + `row_ptr` (offsets). Eliminates millions of heap allocations vs `Vector{Eq}`.

**`SystemLink`** — CSR for proof step link data. `idx[i]`: `k>0` → slice in flat `data[ptr[k]:ptr[k+1]-1]`; `k<0` → shared singleton (rule type); `k=0` → mutable `Vector{Int}` in `extra` dict (RUP cone / RED refs). Zero allocation per step during parsing.

**`PBSystem`** — Dual-index CSR. Forward: `row_ptr/vars/coefs/signs/rhs`; inverse: `var_ptr/var_eqs/var_lit_idx` (equations per variable + flat literal index within each — eliminates O(k) inner scan in `update_slack_on_assign!`). Stores `initial_slack_fwd/rev` for O(n) Trail reset per RUP step. Built once from `FlatEqStore`.

**`PolScratch`** — Task-local scratch for POL evaluation. Stack-based evaluator on flat arrays; pushes result into `FlatEqStore` without allocating. Retrieved via `task_local_storage(:pol_scratch)`.

**`Trail`** — Propagation trail: `pos[]` (step index per var) + `assi[]` (0=unset, 1=true, 2=false), O(1) lookup.

**`Ante`** — Antecedent set: O(1) membership + O(k) iteration, used by `getcone!`.

### Parser

Files read via `Mmap.mmap` → byte array. `tokenize!` produces `ByteSpan` tokens (no copies). `varmap::Dict{Vector{UInt8},Int}` with `ByteSpan` keys (same hash as `Vector{UInt8}`) for zero-allocation lookups. New variables copy bytes once and are kept permanently.

### Trimming algorithm

`getcone!` does backward reachability from the UNSAT contradiction, accumulating the minimal cone of proof steps needed to justify it.

**Outer loop.** `frontier` is a `BinaryMaxHeap{Int}` — highest-index-first. Each step dispatches by rule type: POL/IA have explicit antecedents; RUP is verified by unit propagation.

**RUP — two-queue heuristic.** `ruptrail` routes each equation to `pq_prio` if `cone[eid]` is already true, `pq_nonprio` otherwise, and drains `pq_prio` completely before taking one step from `pq_nonprio`. This steers conflict toward already-needed constraints, minimising cone growth. `cone` is read by `activate!` but never written inside `ruptrail` — only the outer loop writes it via `push_frontier!`.

**Conflict analysis — `conflicttrail`.** PB-specific (not CDCL): slack value determines minimum coefficient-sum of falsified literals to explain. `Grim` sorts by proof index; `Clit` filters to essential/already-cone literals first. `to_explain` (the trail-position work list) is a `BinaryMaxHeap{Int}` (`types.jl`) — a genuine priority queue keyed on trail position, not a stack. Its `push!`/`pop!` calls in `trimmer.jl` use `DataStructures.jl`'s heap API, which shares method names with `Vector` stack usage but has heap (highest-trail-position-first) pop semantics — check the field's declared type in `types.jl` before assuming which one it is.

**Full heuristic chain (do not break any link):**
outer traversal → `cone` accumulation → `activate!` routing → `pq_prio`/`pq_nonprio` ordering → first conflict found → `conflicttrail(mode)` → antecedents added to cone

**One propagation engine — `ruptrail`.** The initial contradiction used to be handled by a separate `propagate!` (index scan with a rewind pointer, hardcoded `Grim`, no `rev` handling); it was removed 2026-08-11 in favour of `do_rup!(firstcontradiction, 0:0)`, the call the BOUNDS branch already used. Safe because for UNSAT the contradiction is the empty `>= 1` constraint, so reversing it in `process_eq!` is a no-op (`slack_rev = rhs-1 = 0`, no literals to propagate) and the min-heaps pop in index order with an empty cone — i.e. exactly the old scan order. Gains: `mode` (`clit`) now respected in the contradiction's own conflict analysis; a non-RUP final step fails loudly instead of silently yielding a size-1 cone; `rs.que` reused instead of a fresh `trues(n)` per call. Do not reintroduce a second propagation path.

*Validated 2026-08-12* by a solve-once/trim-twice A/B on 828 stratified instances (`scripts/ab_propagate_unify.sh`, arms in `ab-propagate/` and `ab-ruptrail/`). Output is unchanged: 1642/1642 `.smol.*` byte-identical, 0 differing, and every cone metric equal on all 1490 paired instances. VeriPB: 0 failures in either arm.

**`propagate!` was quadratic on large systems.** Its `i = rewind` (`rewind = min(rewind, eid)` over every constraint containing a newly assigned variable) jumped the scan back to the lowest affected index and walked forward one index at a time, so cost grew with the *whole* constraint set rather than with the constraints an assignment touches. `ruptrail` pops from the occurrence-indexed heaps instead. The A/B shows a clean dose-response in median trim time (arm B / arm A) against OPB constraint count — and, importantly, **no effect on small systems**, which is what rules out a machine-load artifact:

| constraints | <10k | 10k–100k | 100k–300k | 300k–1M | 1M–3M | >3M |
|---|---|---|---|---|---|---|
| n | 509 | 515 | 179 | 166 | 92 | 29 |
| median B/A | 0.98 | 0.92 | 0.39 | 0.27 | 0.04 | 0.01–0.07 |

Three instances that hit `tt=6000` under `propagate!` now trim: `LVg75g80` (13.3 M constraints) 7.7 s, `LVg71g100` (6.0 M) 14.4 s, `cviu11_p4_t102` (1.1 M) 5656 s. Caveat on the headline −42 % total trim time: arm B skipped solving, so the arms ran under different load. The size buckets, not the total, are the trustworthy signal — on the <100k null control arm B is in fact 4.4 % *slower* in aggregate (median 0.96), i.e. no measurable win where the mechanism cannot fire.

### Resolv loop

`resolvecore` iterates: extract UNSAT core → write reduced LAD → re-run Glasgow solver → trim new proof. Stops at fixpoint or solver failure. Core LADs written to `vis/`; outputs are `.smol.opb`/`.smol.pbp`.

## Output files

- `<instance>.smol.opb` / `.smol.pbp` — trimmed constraint + proof
- `<instance>.out` / `.err` — per-instance logs (parsed by `aggregate_results.jl`)
- `cluster_results.csv` — aggregated metrics (~100 columns) from all `.out` files

## Startup & Sysimage Call Chain

See [`docs/startup-callchain.md`](docs/startup-callchain.md) for the full call chain diagram, sysimage contract (the `--sysimage`/`--project`/`TRIMNALYSER_SYSIMAGE` triad), subprocess launcher details, and debugging guide.

## Known Design Flaws

**Sysimage flag triad is fragile.** Three flags (`--sysimage`, `--project`, `TRIMNALYSER_SYSIMAGE`) must be set consistently across bash wrapper + subprocess launcher. They are set independently in two places (`trimnalyser:34`, `orchestrator.jl:214–218`) with no shared definition. See `docs/startup-callchain.md` for the contract table.

**`run_instance_full` / `run_instance_batch` duplication.** Both implement solve→check→trim→verify→resolv with different subprocess handling for the trim step. Any fix must be mirrored in both. Should be unified with a strategy parameter.

**Global `_cfg[]`.** Every function reads global mutable config implicitly. Makes the call graph opaque and prevents unit-testing of individual stages.

**Internal stdout tee pipe — FIXED 2026-07-31, do not reintroduce.** `main()` used to redirect stdout into a Julia pipe drained by a tee *task*. This deadlocked two full cluster runs (2026-07-27 wedged at 4%, 2026-07-30 at 23%). Cycle: a blocking `write(2)` on fd 1 stalls on the full 64 KB pipe while holding the iolock → no thread can run the libuv event loop → the tee task is never rescheduled → the pipe is never drained → the write never completes. Knock-on: no libuv means no SIGCHLD, so children stay `<defunct>` and every `wait(proc)` (`orchestrator.jl:222`) hangs forever.

Spawning the tee on `:interactive` (the mitigation the old comment describes) is **not** sufficient: `--threads 75,1` gives exactly one interactive thread, and any Julia task still depends on the scheduler that is wedged. The tee must be a separate *process*, which the OS always drains.

Now: the `./trimnalyser` wrapper pipes `2>&1 | tee -a "$TRIMNALYSER_BASE/output.log"` and exports `TRIMNALYSER_EXTERNAL_TEE=1`; `main()` skips the internal redirect when that variable is set. The wrapper also resolves and exports `TRIMNALYSER_BASE` so its log path cannot diverge from `abspath_base` (`src/TrimAnalyser.jl:21`), and forces `--color=yes` because stdout is a pipe at startup. The internal path is kept for direct `julia bin/trimnalyser.jl` invocation only.

**Deadlock signature, if it ever returns:** among the orchestrator's threads, zero in `epoll_wait` and at least one in `anon_pipe_write` (`cat /proc/PID/task/*/wchan | sort | uniq -c`), plus unreaped zombies with PPID = orchestrator and orphan `.subout`/`.suberr` in the proofs dir. Note the thread-1 CPU pattern is *not* reliable: it spun in userspace in the first wedge and slept in `futex_do_wait` in the second. `~/runcheck.sh` on the cluster checks all of these.

**Progress `printstyled` outside `@threads` try-catch** (`orchestrator.jl:609–616`). An IO error there escapes the thread loop and crashes the orchestrator while subprocesses are still running.

**Truncated proofs are solver memouts.** `no conclusion (truncated proof)` (`orchestrator.jl:385`, `pipeline.jl:55`) means the `.pbp` has no conclusion line because the solver died mid-proof. In practice that is always an OOM: on the 2026-07-31 run, 50/50 instances with `proof truncated` in their `.err` also had `OOM at <rss>G` — written by the OOM monitor (`orchestrator.jl:595`) just before it `kill -9`s the solver.

Beware the wording: `<ins> solver stderr: OOM at 51.0G` is **not** Glasgow talking. `runsipsolver` re-reads the `.err` after the run (`solver.jl:174–180`) and echoes back the line the monitor had just appended to it.

Partial `.opb`/`.pbp` *are* cleaned (`tryrm`), so nothing stale is left on disk.

**Sentinel — implemented 2026-08-21.** `.memoutNNN` mirrors `.timeoutNNN`, with `NNN` the
`maxmem=` limit in GB in force when the instance died. Written at three sites: the OOM
monitor's `kill -9`, a trim subprocess exiting 137, and the truncated-proof branch (which is
an OOM in practice). Read by `memout_at_current_maxmem` (`pipeline.jl`), by
`prepare_instance` / `run_instance_full`, and by the batch pre-scan's `memout_cache` — the
instance is skipped unless the new `maxmem=` is strictly larger than the recorded limit, and
`overwrite` bypasses it. `clean` deletes `.memoutNNN` alongside `.timeoutNNN`.

The truncated-proof site guards on a partial `.pbp` actually being on disk: `pbpconclusion`
also returns `""` for a *missing* file, so an unguarded `touch` would permanently sentinel
every instance that had simply never been solved. That guard is also what keeps the
custom-proofs-dir bug below from sentinelling a whole run.

**Custom proofs dir — FIXED 2026-08-21, do not reintroduce.** `subargs` (`orchestrator.jl`)
is a whitelist, and the proofs-dir positional could not be in it (it is a bare path, not a
flag). Trim subprocesses therefore fell back to `defaultproofs` (`config.jl`) and reported
`no conclusion (truncated proof)` for every UNSAT instance of a batch run into a custom dir —
deterministic, and misleading twice over: the real `.pbp` was complete, and the `.err` plus
the `tryrm` cleanup landed in the *default* dir, so the custom dir looked untouched with
nothing explaining it. Worse, if the default dir held proofs for the same instances from an
earlier run, the child trimmed *those* instead and deleted them — plausible numbers computed
from the wrong config's proof. Single-instance mode spawns no subprocess and was unaffected,
so it always worked when tested one instance at a time.

Now `main()` pushes the **resolved** `_cfg[].proofs` onto `subargs`; the child picks it up via
the same `findfirst(isdir)` rule `parse_config!` already uses, so parent and child cannot
diverge however the arg was written or omitted. Forward the resolved value, never a re-filter
of `args`. Verified: batch and single-instance trims of `LVg10g12` in a scratch dir produce
byte-identical `.smol.opb`/`.smol.pbp`.

**OOM monitor matching logic.** Now branches on two process types (trimmer vs solver) with different instance-name extraction. Needs a registered table of `(binary_name, extractor)` pairs if more process types are added.
