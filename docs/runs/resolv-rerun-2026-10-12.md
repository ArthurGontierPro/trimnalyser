# Resolv rerun, 2026-10-12 (arm 2 of RERUN-REQUEST.md, in arm L)

The first part of the rerun `~/papers/trimnalyser-paper/RERUN-REQUEST.md` asks for: resolv
**without the CakePB gate**, on the lazy build, over the whole benchmark. One column, one node
(fataepyc-07), launched 2026-10-12 — see "Launch" below for the exact time and command.

## What it measures

The grid's resolv loop only recursed on a core when CakePB had accepted the trimmed proof
(`recurse_ok`, `src/orchestrator.jl`). That selected the images population by CakePB's heap
wall, not by anything about the instance. This run recurses whenever the trim succeeded and
**VeriPB** verified the trimmed proof; CakePB still runs on every proof and its verdict is
logged (`cake full|smol <STATUS>`), it just no longer stops the loop.

Everything else is the published `gss-lazy` column: same build, same switches, same limits,
same instance enumeration. So arm L's full-pipeline numbers (solve, elaborate, VeriPB, CakePB,
trim, VeriPB and CakePB on the trimmed proof) come out of the same run.

## Configuration

| | |
|---|---|
| config key | `gss-lazy-resolv` (`src/config.jl`); a new key so its blocks stay out of the published `gss-lazy` logs |
| solver | Glasgow `1ff87ba` = HEAD of `lazy-adjacency-relabelled` on the laptop, the cluster and `origin` (checked 2026-10-12). The "latest labelled solver". |
| binary | `/scratch/arthur/glasgow_subgraph_solver_1ff87ba`, sha256 `be51f986…9e71ea` (`/cluster/arthur/dist/MANIFEST`, staged 2026-08-28) |
| switches | `--staged --no-clique-detection --prove` (`_gss_base`) |
| veripb | `/scratch/arthur/veripb`, sha256 `66c300a7…18c011a` |
| cake_pb | `/scratch/arthur/cake_pb`, sha256 `5948bd58…09b72` (post-`c41ce52`, the weakening fix) |
| trimnalyser | `3bedcb9` on `diag/littrim-experiment` (first launch: `e587066`, see "Restart") |
| limits | `stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32`, `--threads 92,1` (the grid's) |
| instance set | `allgraphs rand` = the 25,590 of every published column (LV, bio, images-CVIU11, meshes-CVIU11, phase, scalefree, images-PR15 all included by the enumerator) |
| extra args | `nocakegate minmem=500` (first launch: `nocakegate`) |
| CakePB memory | heap 28672 MB + stack 4096 MB = maxmem, passed as `--CML_HEAP_SIZE=`/`--CML_STACK_SIZE=` flags, stamped `run CAKE_HEAP_MB 28672 STACK_MB 4096 VIA flags` (first launch: 8192/4096 requested through the environment, which this cake_pb ignores → 4096/4096 in force) |
| machine | fataepyc-07: 2× AMD EPYC 7643 48-core (192 threads), 2 TB RAM, `/scratch` 13 TB md0 |
| logs | `/cluster/arthur/logs/<ins>.gss.gss-lazy-resolv.out` (+ `.coreN` for resolv iterations) |
| benchlog | `/cluster/arthur/benchlogs/gss-lazy-resolv.fataepyc-07.<ts>.log` |
| proofs | `/scratch/arthur/proofs/gss/gss-lazy-resolv/` (node-local, deleted as the run proceeds) |

The full sha256 of every binary is printed at the top of the benchlog (`binary <sha> <path>`
lines, added to `bench_config.sh` for this run), and every run block in every log now opens
with `run LIMITS …`, `run SOLVER …`, `run FLAGS …`, `run RESOLV_GATE veripb`,
`run TRIMNALYSER e587066`.

## What changed in the pipeline for this run (commit `e587066`)

- `nocakegate` flag; `recurse_ok` ignores Cake's verdict when it is set. The gate in force is
  stamped as `run RESOLV_GATE veripb+cake|veripb|none|off`.
- The solver's own `key = value` summary (`status`, `nodes`, `propagations`, `runtime`,
  `restarts`, `shape_graphs`, `supplemental_graph_names`, `subsumed_supplemental_graphs`, …)
  is copied from `.solverout` into the append-only log after every solve. Unprefixed for the
  logging solve, `nopl `-prefixed for the tier-1 solve. This is why `solver_nodes`,
  `solver_propagations`, `status`, `pattern_vertices`, `target_vertices`, `runtime_ms` were
  empty in every `runs-0903` CSV: the lines went to a file in the proof tree that is deleted.
- Peak RSS: the solver runs under GNU time → `solve MAXRSS_KB` / `nopl MAXRSS_KB`; the trim
  subprocess logs its own VmHWM → `grim MAXRSS_KB`.
- A solve killed by the OOM monitor is logged `solve VERDICT MEMOUT` + `solve MEMOUT 32.0`
  (was: TIMEOUT, with a `.timeoutNNN` sentinel on top of the `.memoutNNN`). Tier-1 solves get
  `nopl TIMEOUT 60` / `nopl MEMOUT 32.0`; the monitor can now name a tier-1 solve (via the
  parent GNU time process's `-o <ins>.rss`), which it could not before.
- `aggregate_results.jl`: 24 columns **appended** after every existing one (none moved, none
  repurposed): `nopl_nodes nopl_propagations nopl_runtime_ms solver_restarts
  solver_shape_graphs solver_supplemental_levels solver_subsumed_levels
  solver_supplemental_graphs solver_subsumed_graphs nopl_maxrss_kb solve_maxrss_kb
  grim_maxrss_kb error_stage nopl_timeout_s nopl_memout_gb solve_timeout_s solve_memout_gb
  trim_timeout_s trim_memout_gb run_limits run_solver run_flags run_resolv_gate
  run_trimnalyser_rev`. `error_type` is filled from the log's `TIMEOUT|MEMOUT` lines when the
  `.err` is gone, so it is non-empty after the proof tree is deleted; `error_stage` says
  `nopl|solve|trim`.

## For the paper side — read before aggregating

1. **`config_grid.py::normalise_m7` would have misread this CSV — FIXED 2026-10-12** (paper
   repo, `is_m7()` keys on `solve_verdict`/`nopl_verdict`; self-test passes, six published
   columns reproduce byte for byte, the 8-3 run is untouched). The original trap: it keyed "pre-M7 rundir" on
   `d.status.notna().any()`, and `status` is populated again here (it is the solver's
   `status = true|false` line, as it was before M7). With that guard taken, it skips the
   `veri_smol_verified` 0→NaN repair, so every FAILED/TIMEOUT/MEMOUT row counts as certified.
   Key the guard on something else — `run_trimnalyser_rev` being present, or `solve_verdict`
   being non-empty — before using this run. `sec6_0903.py` reads `solve_verdict ∈ {SAT,UNSAT}`
   and is unaffected, but note the new value `MEMOUT` beside `TIMEOUT`.
2. `status` here is the **logging** solve's verdict, so it is empty for instances the tier-1
   solve already settled (SAT) or that never reached tier 2. `solve_verdict.fillna(nopl_verdict)`
   remains the complete verdict, as in every M7 column.
3. **Resolv rows**: `resolv_iter_pat_nodes`/`resolv_iter_tar_nodes` come from the `resolv ITER n
   PAT p TAR t` lines of the base instance's log; the per-iteration trim metrics come from the
   `.coreN` logs. The key is new, so no stale `.coreN` log from an older run can be mistaken for
   this run's (the aggregator counts iterations by the existence of `.coreN` files).
4. `cake_smol_status` is recorded for every trimmed proof; the recursion no longer depends on
   it. Filter on it yourself if a Cake-certified subset is wanted.

## Not in this run (deliberately)

- Arms E, G, M and the throughput arm (3): those need three more Glasgow builds and are the
  second part of the rerun. This run is arm L only.
- "Smallest n at which T_n differs from T_{n-1}" and "minimum common-neighbourhood size over
  pairs at distance two": `1ff87ba` does not print them, and the solver binary was not
  changed for this run (it must stay the published `gss-lazy` build). The levels built
  (`solver_supplemental_levels`, from `supplemental_graph_names`) and the levels that
  collapsed (`solver_subsumed_levels`, from `subsumed_supplemental_graphs`) ARE there.
- Elaborated sizes: `cake_elab_size` / `cake_smol_elab_size` as before.
- The alternative conflict-analysis rule (`gclt_*`): not run.

## Launch

Started **2026-10-12 13:49:08 UTC** on fataepyc-07, tmux session `grid-gss-lazy-resolv`,
benchlog `/cluster/arthur/benchlogs/gss-lazy-resolv.fataepyc-07.20261012-134906.log`:

```
CONFIGS=gss-lazy-resolv NODES=fataepyc-07 EXTRA=nocakegate SKIP_SYSIMAGE=1 bash scripts/run_grid.sh launch
# which ran, on the node:
./trimnalyser --threads 92,1 solve resolv verif cake config=gss-lazy-resolv \
    stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32 allgraphs rand nocakegate
```

Sysimage rebuilt once beforehand with `cluster_env.sh` sourced and the precompile cache
purged (`build_sysimage.jl`, 150 s), then checked with `check_sysimage_env()`; no other
column had written a benchlog since 2026-09-10, so nothing had the shared `.so` mapped.

**Smoke tests before the launch, and why their traces were removed.** A single-instance run
of `LVg10g12` at scale 60, then a five-instance batch (`LVg6g7 LVg10g28 LVg17g24 bio001064
LVg10g12`, `INSTFILE`, scale 60) to exercise the subprocess trim and the recursion: three of
the five iterated (LVg6g7 19→4→3, bio001064 46→18→16, LVg17g24 four iterations), every core
certified by both checkers, no `.rss` left behind. Then the config's proof tree and the
smoke's log files (base + `.coreN`, by explicit name) were deleted: a smoke `.done` makes
the real run skip that instance silently (observed — the batch smoke skipped `LVg10g12`
because the single-instance smoke had marked it), and a stale `.coreN` log would be counted
as a resolv iteration by the aggregator. The real run therefore started on an empty tree and
needs no `overwrite`.

**Watching it:** `bash scripts/run_grid.sh status` (CONFIGS/NODES as above), or count
`*.gss.gss-lazy-resolv.out` only via the proof dir's `.done`/sentinels — never `ls` the
900k-entry logs directory over NFS.

**Aggregating it** (on the node, once the session has ended):

```
julia scripts/aggregate_results.jl /scratch/arthur/proofs/gss/gss-lazy-resolv \
      /cluster/arthur/m7-1012/gss-lazy-resolv/cluster_results.csv /cluster/arthur/logs
```

Build the symlink farm of just this key's logs first (see `docs/runs/` and the
`project-appendix-data-provenance` memory): the aggregator `readdir()`s the whole logs
directory otherwise. Aggregate while the proof tree still exists if `.err` details are wanted
beyond what the log carries; `error_type`/`error_stage` no longer depend on it.

## First-hour check (14:50 UTC, 589 instances settled, 385 done)

Everything that could be paired with the published `sep01-gss-lazy` column was: the 589
instances settled so far are all in it, with the same verdicts (109 SAT, 11 tier-1 UNKNOWN,
14 of 16 tier-2 timeouts also timed out there, the other 2 are borderline), byte-identical
`inp OPB SIZE` and `inp LIT` on all 385 done instances, trim time ratio median 1.05, cake
full time ratio median 1.00 where both verified, VeriPB on the trimmed proof 373/373, CakePB
on the trimmed proof 372/373 (the published column had 10 FAILED among these — the c41ce52
weakening bug, gone). Every new log line is present on every done instance (`run *`, `nopl *`,
`nodes =`, `status =`, `*_MAXRSS_KB`, `supplemental_graph_names`); no OOM kill was booked
against `?`; no `.rss` left behind; no deadlock signature (one thread in `ep_poll`, none in
`anon_pipe_write`). Resolv iterated on 310 of 373; paired iteration counts equal the
published ones except 8 instances that now iterate once where the Cake gate had stopped
them (`smolcake_failed` → `stabilized`). Throughput ~10 inst/min on the random order,
i.e. ~40 h for the set.

Two defects, one of which is a decision:

1. **CakePB runs at a 4 GB heap, not 8 GB.** The cake_pb staged 2026-08-27 (`5948bd58…`,
   post-c41ce52) ignores `CML_HEAP_SIZE`/`CML_STACK_SIZE` in the environment and takes them
   as `--CML_HEAP_SIZE=<n>` / `--CML_STACK_SIZE=<n>` flags, defaulting to 4096/4096. Probed
   on fataepyc-07 with a FIFO as input so the process blocks after its startup `malloc`:
   VmPeak 8.39 GB with the env (= 4096+4096), 12.6 GB with the flags (= 8192+4096); the
   pre-c41ce52 binary gives 12.6 GB with the env. Consequence here: the full-proof CakePB
   wall is a 216 MB model (largest verified 215 MB, smallest memout 217 MB) against 456 MB
   in `sep01-gss-lazy`; 21 of the 385 done instances CakePB certified there are MEMOUT here.
   The same applies to every column run after 2026-08-27 (`gss-lazy-norestarts`,
   `-nostaged`, `-nosupp`, `-cliques`, `-ft`, `-tb`, the lad-* columns) — this is the
   "looks like a 4 GB heap" note in `project-cake-formula-bound`, now root-caused.
   Fixed in the code (`cakeflags()`, `src/output.jl`: the flags are passed to a binary whose
   `--h` documents them, the env to the other; the heap in force is stamped as
   `run CAKE_HEAP_MB 8192 STACK_MB 4096 VIA flags|env` and aggregated as `run_cake_heap`).
   The running orchestrator cannot pick that up; it needs a stop, sysimage rebuild, clean
   restart. Restart decision: see the next section.

2. **A trim killed by the OOM monitor leaves no log line.** 82 of the 589 settled instances
   are trim memouts (all `cviu11`/large LV, the same instances that have no trim result in
   the published column), each with the monitor's `.memout32` and `OOM at 32.xG (limit
   32.0G, stage trim)` in the `.err`, but none with `trim MEMOUT` in the log: libuv reports
   a signal death as exitcode 0 + termsignal, and coreutils `timeout` re-raises the child's
   SIGKILL on itself, so `run_trim_subprocess` took the silent `else` branch (status
   `:failed`). Data is intact — `error_type` comes from the `.err` — and the aggregator now
   also takes `error_stage` from the `.err`'s `stage …` word. The orchestrator folds
   termsignal into 128+n so the 137 branch fires from the next launch on. Same silent path
   existed in every grid column.

Also noted, not a defect: `.done` is written before the resolv loop starts
(`orchestrator.jl`), so a `.done` count overstates completed instances by the resolv
iterations in flight, and an instance interrupted mid-resolv is skipped on resume.

### Which heap each published column ran with (measured 2026-10-12 from `runs-0903`)

| column (CSV dir) | run window | cake_pb | heap | full-proof wall | cake full MEMOUT | MEMOUT < 456 MB model |
|---|---|---|---|---|---|---|
| `sep01-gss-lazy` (lazy baseline, printed everywhere) | 08-24 19:13 → 08-27 05:33 | pre-c41ce52 | **8 GB** | 455 MB | 520 | 25 |
| `sep01-gss-lazy-base` (pre-NDS, not a column) | 08-24 → 08-27 | pre-c41ce52 | 8 GB | 455 MB | 425 | 23 |
| `sep01-gss-proof` (pre-NDS, not a column) | 08-24 → 08-28 | pre-c41ce52 | 8 GB | 455 MB | 426 | 24 |
| `sep01-gss-proof-nds` (default logging `861a84f`) | 08-28 17:04 → 09-01 10:37 | c41ce52 | **4 GB** | 219 MB | 1303 | 754 |
| `sep01-gss-lazy-base-nds` | 08-28 → 08-31 | c41ce52 | 4 GB | 219 MB | 1230 | 763 |
| `gss-lazy-nostaged` | 09-01/09-03 → 09-05 | c41ce52 | 4 GB | 219 MB | 1280 | 672 |
| `gss-lazy-nosupp` | 09-01/09-03 → 09-06 | c41ce52 | 4 GB | 221 MB | 1783 | 1313 |
| `gss-lazy-norestarts` | 09-01/09-03 → 09-04 | c41ce52 | 4 GB | 219 MB | 1357 | 789 |
| `gss-lazy-cliques` | 09-03 → 09-10 | c41ce52 | 4 GB | 219 MB | 1127 | 740 |
| `lad-alldiff-pl`, `lad-fc-pl` (+ `-capped`) | 08-31 → 09-09 | c41ce52 (pb + iso) | 4 GB | 222 MB | 1532 / 1529 | 832 / 832 |
| `gss-lazy-resolv` (this run, first hour) | 10-12 13:49 → | c41ce52 | 4 GB | 216 MB | 30 of 385 | 30 |

Wall = largest model CakePB verified a full proof for; no model above it verified in that
column. The 08-27 14:04 staging of the new binary reached the nodes with the 08-28 17:04
`setup_all_nodes` relaunch; the three 08-24 columns ran to completion on the old one.
Companion columns (`-ft`, `-tb`) and the no-logging columns carry no CakePB data.

So only the lazy baseline (and two pre-NDS columns that are not in the paper) have the
intended 8 GB. The default-logging column, the four ablation columns and both LAD columns
are at 4 GB. Any CakePB memout comparison across that boundary in the current appendix is
confounded by the heap (the `project-cake-formula-bound` warning, now with the exact list),
and the "456 MB wall" in the paper text is the 8 GB figure.

## Restart (2026-10-12, after the first-hour check)

Stopped at 15:11 UTC on the decision to fix the CakePB memory. Clean restart: the proof
tree deleted, the 1,187 log files of the 770 touched instances deleted by explicit name
(base and `.core1..20` of every instance named in the first benchlog), nothing else in
`/cluster/arthur/logs` touched. Node pulled to `3bedcb9`, sysimage rebuilt with
`cluster_env.sh` sourced, `check_sysimage_env()` passed.

What `3bedcb9` changes against `e587066` (commits `e0e3c71`, `3bedcb9`):

- **CakePB memory = maxmem.** `heap = maxmem − stack`, `stack = min(4096, maxmem/8)` →
  28672 + 4096 MB at maxmem=32, passed as flags (the post-08-27 wrapper ignores the
  environment; see `cakeflags()` and `project-cake-heap-flag-regression`). Rationale: the
  trimmer, solver and veripb are killed at 32 GB resident; CakeML's heap+stack is one block
  that a long check sweeps entirely, so it is cake's resident footprint; equal budgets means
  heap+stack = maxmem. The stack keeps the cakepb-dev default: 368/368 exhaustion files on
  the surviving `gss-lazy-norestarts` tree say heap, and cake_pb has no FAILED verdict in
  any of the thirteen columns. The 2,241/2,212 cake_pb_iso FAILED of the LAD columns are
  unexplained (their stderr is on unbooked nodes) and will be classified by the new line.
- **`cake <tag> EXHAUSTED heap|stack`** on every CakeML exhaustion; both are MEMOUT (a stack
  exhaustion used to be FAILED). Aggregated as `cake_full_exhausted`, `cake_smol_exhausted`,
  `cakeiso_full_exhausted` (appended).
- **`minmem=500`**: no heavyweight child is launched while less than 500 GB is free. A
  28 GB heap means a cake check can grow to 32 GB resident; 92 slots at the old 100 GB floor
  left no room for that growth. The node has 2 TB and 7 GB of swap.
- **A monitor-killed trim is booked `trim MEMOUT`** (termsignal folded into 128+n).

Published columns and the CakePB heap: `sep01-gss-lazy` and the two pre-NDS columns ran at
8192/4096 (old wrapper, environment honoured); every column from 2026-08-28 on at
4096/4096. Columns to rerun end to end for CakePB figures at the new setting — proofs are
not kept, so there is no cake-only rerun: arms L, E, G, M (the rerun request's "certified
by CakePB" per arm) and `lad-alldiff-pl` + `lad-fc-pl` (the only CakePB numbers in the
paper's prose: §4's "accepts almost every trimmed LV proof" and appendix A's 38.9 % vs
57.3 % / 3,543 of 3,544). The four lazy ablation columns and `gss-proof-nds` print no
CakePB cell (`config_grid.py` reads none); their 4 GB cake data is not to be cited.

**Relaunched 2026-10-12 15:53:51 UTC**, tmux `grid-gss-lazy-resolv`, benchlog
`/cluster/arthur/benchlogs/gss-lazy-resolv.fataepyc-07.20261012-155350.log`:

```
CONFIGS=gss-lazy-resolv NODES=fataepyc-07 EXTRA="nocakegate minmem=500" SKIP_SYSIMAGE=1 bash scripts/run_grid.sh launch
# on the node:
./trimnalyser --threads 92,1 solve resolv verif cake config=gss-lazy-resolv \
    stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32 allgraphs rand nocakegate minmem=500
```

Verified on the first processes: `cake_pb --CML_HEAP_SIZE=28672 --CML_STACK_SIZE=4096 …`,
VmPeak 33,558,008 kB (= 32 GB + 3.5 MB); every run block opens with
`run CAKE_HEAP_MB 28672 STACK_MB 4096 VIA flags`; `%OOM limit: 32.0 GB per subprocess,
minfreemem: 500 GB`. The 13:49 benchlog is the aborted first launch and is not part of
the run's data; its instances' logs were deleted before the relaunch.

## Day-one check (2026-10-13 12:20 UTC, 20 h in)

9,160 instances settled (5,735 done, 1,408 SAT, 573 solver timeouts, 1,444 memouts), a
steady 750–970 per two hours → about 36 h to go. Load 93, 872 GB used, no memory or disk
waits at the 500 GB floor, no wedge signature. Trim memouts + trim timeouts are 18.1 % of
settled instances against 18.3 % "reached the trimmer, no trimmed-proof check" in the
published column, 88 % of them images. CakePB at 28 GB: 33 full-proof memouts in 12,639
checks (0.26 %; the published column had 2.6 % at 8 GB), all heap, none stack; 0 FAILED on
either proof. VeriPB: 50 full-proof timeouts, 2 "FAILED" — and both of those are the OOM
monitor killing veripb at 32 GB (`OOM KILL LVg68g76 (verif …)`, `LVg40g77`), booked FAILED
because `runcapture` returned exit 0 for a signal death (same defect as the trim one). The
published column records the same two as FAILED. Fixed for later arms in `runcapture`;
for this run the aggregator reclassifies `veri_* FAILED` to `MEMOUT` when the base
instance's `.err` says `stage verif`, so **aggregate before the proof tree is deleted**.
Also 2 solver OOM kills (LVg68g77 at 40 GB, LVg64g76), the dense-target wall.

## Finished, and aggregated (2026-10-16)

The run ended 2026-10-15 02:18:56 UTC, 210,304 s (58.4 h) after the relaunch. Base
instances: 3,900 tier-1 SAT, 523 tier-1 UNKNOWN, 981 logging-solve timeouts, 3 solver OOM
kills (LVg64g76, LVg64g77, LVg68g77), 20,183 UNSAT with a full proof, of which 15,493 `.done`,
4,020 trim OOM kills at 32 GB, 667 trim timeouts at 6,000 s (no sentinel: only solver
timeouts and memouts get one) and 3 veripb OOM kills (LVg32g77, LVg40g77, LVg68g76, logged
`veri full FAILED`, reclassified from the `.err` by `1cb91e3`). 88 CakeML heap exhaustions
at 28 GB against 561 in the published column at 8 GB. 14,236 resolv iterations, 25 of them
OOM-killed (`<ins>.coreN.memout32`). 22 partial `.smol.*` files of 14 killed trims remain
(`run_trim_subprocess`'s non-`:ok` return skips `release_smol`). Every count pairs with
`sep01-gss-lazy`; on the 15,413 cones common to both runs every proof and cone is
byte-identical.

Aggregated 2026-10-16 13:47 UTC on the node into
`/cluster/arthur/m7-1012/gss-lazy-resolv/cluster_results.csv` (25,590 × 316, sha256
`141aa910…`), mirrored to `~/trimnalyser/runs-1012/`, from a symlink farm of the key's 39,826
logs with the proof tree still on disk. **The aggregator had not run since `e587066` and was
broken twice over:** a missing comma after the appended columns (`cb39d52`) and the appended
pushes placed after the row-length check, which skipped every row and wrote an empty CSV
(`0a557de`); and the veripb-memout reclassification of `1cb91e3` keyed on the last stage that
died, which for all three such instances was a later trim kill (`5fcc800`). The CLAUDE.md
syntax check covers `src/` only; run it on `scripts/` too.

What the rerun says about the paper's prose (memory against time as what stops the trimmer,
same-binary noise under the §6 1.06, CakePB at 28 GB) is in the paper repository's
`NUMBERS-PROVENANCE.md`, "What the rerun says about the prose", from
`scripts/rerun_1012_claims.py`.

What the paper takes from it (`~/papers/trimnalyser-paper`, `\rerun` marks, 2026-10-16):
resolv factors LV 4.55 / meshes 3.25 / bio 1.72 / images 1.41 and fixpoint 99.82 % (15,446 of
15,474) replacing 8-3's 4.2 / 3.3 / 1.7 / 1.4 and 99.9 %; the memout/timeout split of the
4,689 untrimmed four-family instances (4,023 OOM, 666 timeouts; 4,080 images; 27 of them
killed after the trimmer printed its statistics, which tab:instance-counts files as "no
verification record"); the proxy
`grim_full_prop > 0` equals `solver_nodes > 0` on every cone. The §4 "32 GB" doubt was
cleared from the benchlogs: every launch line from 2026-08-24 19:06 on says `maxmem=32`.
