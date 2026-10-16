# The "shipped" column: `gss-default-nostaged` (861a84f, `--staged` off)

Launched **2026-10-16 17:26:37** (node time) on fataepyc-07, tmux `grid-gss-default-nostaged`,
benchlog `/cluster/arthur/benchlogs/gss-default-nostaged.fataepyc-07.20261016-172637.log`,
per-instance logs `/cluster/arthur/logs/<ins>.gss.gss-default-nostaged.out`, trimnalyser
`fac3b07`:

```
CONFIGS=gss-default-nostaged NODES=fataepyc-07 EXTRA="nocakegate minmem=500" SKIP_SYSIMAGE=1 bash scripts/run_grid.sh launch
# on the node:
./trimnalyser --threads 92,1 solve resolv verif cake config=gss-default-nostaged \
    stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32 allgraphs rand nocakegate minmem=500
```

Binary `/scratch/arthur/glasgow_subgraph_solver_861a84f` (sha256 `f5d5d7d4…`), flags
`--no-clique-detection` alone (`run FLAGS` in every block; no `--staged` on any solver
command line at launch), `run RESOLV_GATE veripb`, `run CAKE_HEAP_MB 28672 STACK_MB 4096 VIA
flags`, `%OOM limit: 32.0 GB per subprocess, minfreemem: 500 GB`. Same limits, pipeline and
instrumentation as the resolv arm (`resolv-rerun-2026-10-12.md`).

## Why

AG, 2026-10-16: `--staged` was added by Ciaran after the early readings of the cone, and
lazy supplemental graphs after the full reading. The paper's rule is that the instrument is
read on the solver before the change it produced; `gss-default` (861a84f with `--staged`)
has already absorbed the first change, since the supplemental layer is built there only
when the cheap first round fails. This column is the solver before either change: every
supplemental graph built, and its justification written, before any search, on every
instance. Paired per instance with `gss-default` it measures `--staged` on the default
build by the same method as the ablation grid (same binary, one switch); `gss-default`
against `runs-1012` then measures lazy generation as now.

The option was switched off rather than reverting to a revision before it existed: that
revision predates the NDS proof-witness fix (VeriPB rejected thousands of full proofs
before it) and part of the labelling, and only `861a84f` and `1ff87ba` may be paper
columns. Open with Ciaran: that `--staged` off is the pre-staged code path.

## Before the launch

Config key added (`src/config.jl`, `fac3b07`); node pulled; sysimage rebuilt with
`cluster_env.sh` sourced (a new key needs it: `SOLVER_CONFIGS` is a `const` baked into the
image), `check_sysimage_env()` passed and the image resolved the key to the 861a84f binary.
Smoke on `LVg10g12` at scale 60: solve 0.4 s, full proof VERIFIED by both checkers, cone
28/41 pattern nodes, resolv one iteration to a fixpoint, core VERIFIED by both; the full
proof carries the layer up front (`PATHG1 723/57252`, `G1ADJ 240/14662`). The key's proof
tree and the smoke's two log files (`LVg10g12`, `LVg10g12.core1`) were deleted by name
before the launch, so the run started on an empty tree without `overwrite`.

## When it ends

Aggregate on the node from a symlink farm of `*.gss.gss-default-nostaged.*out` with the
proof tree still on disk (`/scratch/arthur/agg-1012.sh` is the template), into
`/cluster/arthur/m7-1012/gss-default-nostaged/cluster_results.csv`, and mirror to
`~/trimnalyser/runs-1012/`. Then, in the paper: the characterisation re-read on this
column, and §6.2 with two paired changes, shipped → staged → lazy.
