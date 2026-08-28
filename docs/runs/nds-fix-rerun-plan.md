# What to run after the NDS fix

Written 2026-08-28, against the M7 grid launched 2026-08-24 19:13 and the five-branch NDS
backport of the same week. Companion to `docs/failing-pairs/README.md`, which supplies every
count below.

## The case the data already makes

`gss-lazy` is the only proving column pinned to an NDS-fixed revision (`1ff87ba`). It is also
the only proving column with **no** category C and **no** category D pairs:

| config | revision | NDS | C (both failed) | D (full failed, smol rescued) |
|---|---|---|---|---|
| `gss-nosupp`     | `39ca857` | buggy | 768 | 1910 |
| `gss-cliques`    | `39ca857` | buggy | 104 | 2 |
| `gss-lazy-base`  | `39ca857` | buggy | 8 | 9 |
| `gss-nostaged`   | `39ca857` | buggy | 5 | 12 |
| `gss-norestarts` | `39ca857` | buggy | 6 | 9 |
| `gss-proof`      | `2180663` | buggy | 2 | 2 |
| **`gss-lazy`**   | **`1ff87ba`** | **fixed** | **0** | **0** |

This is suggestive, **not** proof. `1ff87ba` is five commits ahead of `39ca857`, and three of
those five touch supplemental-graph handling — the exact mechanism `--no-supplementals`
governs, and `gss-nosupp` is 2678 of the 2801 affected instances (94 %). The comparison
confounds the NDS fix with the supplemental work. That confound is the whole reason
`nds-fix/39ca857` (`84f1d3e`) exists: it is `39ca857` plus the two-line NDS fix and nothing
else, so it isolates the one variable.

## Stage 0 — unblock the two wedged columns (do first, costs nothing)

`gss-proof` (fataepyc-03) and `gss-nostaged` (fataepyc-06) have processed every instance but
their orchestrators cannot exit: one trim subprocess each is deadlocked in Julia's SIGTERM
shutdown after burning its full `tt=6000`, and plain `timeout` never escalates. See
`cf07c42`. Two nodes have been at load 0.00 for 43 h and 91 h.

    kill -9 <the julia subprocess pid>   # NOT the `timeout` parent

The cluster is still running the pre-`cf07c42` code, so that kill surfaces as exit 137, which
the old code files as an OOM — it writes a `.memoutNNN` sentinel that would suppress the
instance on every later run at `maxmem=32`. Delete both sentinels afterwards; the honest
label is a trim timeout, which is what these were.

    LVg57g66  (gss-proof)     LVg14g48  (gss-nostaged)

`gss-cliques` is healthy and genuinely mid-run at roughly half the set; leave it. At its
observed rate it needs about four more days, and its bottleneck is VeriPB verify time, not
the solver.

## Stage 1 — pin and stage `84f1d3e`, without disturbing what has been measured

Add it as a **new** revision. Never overwrite `glasgow_subgraph_solver_39ca857`: the harvested
tables were measured against that binary, and `setup_node.sh` explicitly checks that no two
revisions hash the same — that check exists to catch precisely this.

1. `src/config.jl`: a new key, e.g. `gss-nosupp-ndsfix`, identical to `gss-nosupp` but
   `gssbin("84f1d3e")`.
2. `scripts/cluster_env.sh`: the matching `GLASGOW_SUBGRAPH_SOLVER_84f1d3e` pin. It must be
   exported **before julia starts** — `SOLVER_CONFIGS` is a `const` built at module load.
3. `bash scripts/cluster_dist.sh` — it greps revisions out of `config.jl` by hash and builds
   one worktree per revision, so this adds one build and rebuilds nothing.
4. `bash scripts/setup_all_nodes.sh`, then `--verify`.
5. Purge the sysimage precompile cache before rebuilding, or the `.ji` re-bakes the old
   paths (`864e99d`).

Smoke-test on `LVg10g12` before committing a node to it.

## Stage 2 — the experiment

One node, **sequential**, `THREADS=92,1`, grid-identical timeouts
(`stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32`). Never concurrent columns.

**Set.** The 2678 `gss-nosupp` C+D instances, plus ~500 that certified cleanly in the same
column as a null control — the fix must be a no-op on those. Build both lists from
`docs/failing-pairs/{C_both-failed,D_smol-rescued-full}.tsv` (field 1 = config, field 2 =
instance) and feed them with `INSTFILE=`; `bench_config.sh` drops `allgraphs` for that branch.

**What decides it:**

| metric | source | pass |
|---|---|---|
| category C + D on the 2678 | per-instance logs, last `=== RUN` block | **0** |
| `^@elimnds[0-9_]* +rup` in emitted `.pbp` | a ~50-instance `keepraw` subset | **0** |
| search nodes vs the recorded run, same instances | `.out` logs | **exactly equal** |
| the 500 controls | per-instance logs | unchanged |

The node-count check is the one that must not be skipped. The fix touches only the proof
witness, so identical node counts are what proves it changed logging and not search. A
difference there means something is wrong with the build, not that the fix helped.

Do not keep `keepraw` on for the whole set — it needs several hundred GB of `/scratch`.

## Stage 3 — conditional, and it is the expensive one

If Stage 2 comes back clean, every proving column except `gss-lazy` is currently reporting a
verification-failure rate that is our own solver bug rather than anything about trimming, and
category D is a masking rate being read as a result. Re-pinning all of them to NDS-fixed
revisions (`84f1d3e` for the five on `39ca857`, `861a84f` for the three on `2180663`) and
re-running the grid is roughly four to five days across nine nodes.

That is a decision about what the paper claims, not a technical one, so it is left open here.
The cheaper alternative is to keep the current numbers and report the bug explicitly — the
`docs/failing-pairs` taxonomy already supports that.

## Still open, and not blocking any of the above

- **`@binback`** (`Proof::backtrack_from_binary_variables`) is a separate unfixed bug,
  reachable only with clique detection on. It is untouched by the NDS fix, so `gss-cliques`
  will not come back clean from Stage 2's mechanism check. Repro: `LVg13g30` at `.pbp:12538`.
- **`del index is 0`** (`writer.jl:156`) prints to stdout and reaches no per-instance log —
  400-file samples of all seven proving columns found zero occurrences in `.out` while the
  live panes were flooding with it. It also *skips writing the id*, so the `del id` line is
  silently short. Same class as `pol 0`: a half-built cone two stages upstream. Worth making
  loud and recorded before the next grid, not during one.
- The five `lad-*` columns still predate the `<=` parse fix and remain unmeasured.
