# Category-B re-run — 2026-08-27, fataepyc-02

Re-runs the 3815 (config, instance) pairs whose **trimmed** proof CakeML rejected in the
2026-08-24 grid, against both fixes for that rejection.

## What is being tested

Two independent fixes for one defect landed on the same day, and this run measures the
shipping combination of both:

| | where | what it does |
|---|---|---|
| **theirs** | cakepb-dev `c41ce52` "fix a bug in weakening" | `w v` on a variable that is not in the constraint is a legal no-op (coefficient 0). CakeML skipped it and built a different constraint from VeriPB's. |
| **ours** | `4977151` `src/writer.jl` | the trim no longer emits that construct: a `<lit> w` pair is dropped when the variable cannot be on the pol stack at all. |

Either one alone clears the category — `3803e41` A/B'd the writer fix on
`LVg11g58`/`gss-lazy-base` and took the *old, unfixed* `cake_pb` from FAILED at line 67977
to `s VERIFIED UNSATISFIABLE` on the same solved proof. This run confirms the pair on the
full population.

**Why a re-run and not a re-check:** the pipeline deletes each proof at last use, so the
3815 rejected `.pbp` files no longer exist. Confirming the fix means regenerating
solve → trim → veripb → cake for every pair.

## The set

Derived from the archived `results.csv` (`cake_smol_status == FAILED`), not from the earlier
66 h log scan — that one carried 23 `.coreN` resolv children, which are not benchmark
instances, and missed the 23 parents they belong to.

| config | pairs |
|---|---|
| gss-nostaged | 1236 |
| gss-lazy | 707 |
| gss-lazy-base | 697 |
| gss-norestarts | 692 |
| gss-proof | 481 |
| gss-cliques | 2 |
| **total** | **3815** |

1392 distinct instances, 99.3 % `cviu11_*`. Glasgow only — no LAD pair ever hit this.

**`cake_full` FAILED is 0 in all 217835 pair-records.** That is the signature of the bug:
it can only fire on a trimmed proof, because the trimmer drops literals while `writepol`
copied Glasgow's `w` tokens through verbatim. An untrimmed proof never weakens a literal
that is not there.

## Provenance

```
repo      864e99d
cake_pb   /scratch/arthur/cake_pb   sha256 5948bd58…4609b72  (cakepb-dev c41ce52)
threads   92,1        (same as the grid, so timings stay comparable)
timeouts  stnopl=60 st=600 tt=6000 vt=6000 ct=6000   (scale 1, same as the grid)
launched  2026-08-27T14:22:33Z, tmux session `rerunB` on fataepyc-02
lists     /cluster/arthur/rerun/20260827T142233Z/<config>.txt
log       /cluster/arthur/rerun/rerunB.log
```

Estimated ~19 h wall from the archived per-pair timings (1756 cpu-hours, of which 1571 are
trim).

## Results

_pending — fill in from the last `=== RUN` block of each log once the run completes._

## Traps hit while setting this up

- **The sysimage re-baked the old binary paths through the precompile cache.** Sourcing
  `cluster_env.sh` before `build_sysimage.jl` is not sufficient: the constants are baked at
  *precompile* time and Julia's `.ji` cache key does not include the environment, so a
  freshly built image resolved all nine Glasgow columns to
  `/scratch/arthur/glasgow_subgraph_solver`. Fixed in `864e99d` (purge the cache, and stamp
  the baked env so an environment change counts as stale — the staleness check was
  mtime-only, which deadlocks against `check_sysimage_env()`).
- **`cluster_env.sh` used `export VAR=…`, not `:=`.** `bench_config.sh` has always
  documented that an exported value wins; it did not. `CAKE_PB=/fixed/cake_pb bash
  scripts/bench_config.sh …` silently ran the grid's binary.
- **`allgraphs` beats `instfile=` in `orchestrator.jl:614`.** `bench_config.sh`'s new
  `INSTFILE` branch has to *replace* `allgraphs`, not add to it, or the list is ignored in
  silence.
