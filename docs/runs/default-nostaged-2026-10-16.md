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

## Finished 2026-10-19 16:50 UTC, aggregated 17:10 UTC

Wall time 257,054 s (71.4 h; the lazy resolv arm took 58.4 h). The benchlog's last lines
are the tail of 100-minute stages: trims and CakePB full checks stopped at 6,000 s, two
trims killed at 38 GB. Nothing `FAILED` anywhere.

Aggregated on the node at trimnalyser `7d36fd2` (aggregator unchanged since `5fcc800`),
`/scratch/arthur/agg-nostaged.sh` (log `/cluster/arthur/m7-1012/aggregate-gss-default-nostaged.log`),
from a node-local symlink farm of the key's 37,543 logs (25,590 base + 11,953 `.coreN`) with
the proof tree still on disk (7 GB, `.err` intact), into
`/cluster/arthur/m7-1012/gss-default-nostaged/cluster_results.csv` (25,590 × 316, sha256
`6ca1a8e8cc40a98e547972937c5029860603a8caf0c423a2420efd428c13cb5b`), mirrored with the log to
`~/trimnalyser/runs-1012/gss-default-nostaged/` (README and `MANIFEST.sha256` there). Every
row carries `run_solver = …_861a84f`, `run_flags = --no-clique-detection`, `run_resolv_gate =
veripb`, `run_cake_heap = 28672 STACK_MB 4096 VIA flags`, `run_trimnalyser_rev = fac3b07`.

### Verdicts

Every CSV count equals the sentinel count in the proof tree (`.sat` 3,902, `.timeout60` 518,
`.timeout600` 1,926, `.memout32` 5,887 top-level, `.done` 12,864).

| stage | shipped (this run) | lazy resolv arm (`gss-lazy-resolv`) |
|---|---|---|
| tier-1 (60 s, no logging): UNSAT / SAT / UNKNOWN | 21,170 / 3,902 / 518 | 21,167 / 3,900 / 523 |
| logging solve (600 s): UNSAT / timeout / memout | 19,242 / 1,926 / 2 | 20,183 / 981 / 3 |
| full proof, VeriPB: VERIFIED / timeout / FAILED | 19,033 / 209 / 0 | 20,049 / – / 0 |
| full proof, CakePB: VERIFIED / timeout / heap | 18,837 / 178 / 18 | – / – / 88 |
| trim: memout / timeout | 5,885 / 493 | 4,020 / 667 |
| certified cones (VeriPB on the trimmed proof) | 12,864 | 15,493 |
| by family LV / bio / meshes / images | 3,267 / 6,540 / 2,086 / 971 | 3,886 / 6,597 / 2,821 / 2,170 |
| CakePB on the trimmed proof: VERIFIED / heap | 12,863 / 1 | 15,492 / – |
| resolv: fixpoint / trim memout / solver t/o / trim t/o | 12,656 / 134 / 48 / 26 | 14,236 iterations |

The grid's default column (`sep01-gss-proof-nds`, `861a84f` with `--staged`) certifies
14,618 cones (LV 3,595, bio 6,569, meshes 2,805, images 1,631). Against it, per instance:
778 instances it solves UNSAT time out here at 600 s, 36 the other way round.

### First reading (paper scripts, `~/papers/trimnalyser-paper/numbers-1019/`)

`sec6_0903.py` with this column as the "default" side and the grid's default column as the
other (`sec6_shipped_vs_staged.txt`, 12,745 instances certified by both): the shipped
solver's proof is 2.33× the staged one's in bytes (sgm), 6.27× on the 5,026 instances where
the layer is derived and **identical on the other 7,719**; cone 1.60× (2.89× where derived);
logged solve time 1.20×. Against the lazy run (`sec6_shipped_vs_lazy.txt`, 12,860 paired):
proof 2.62× (7.88× where derived), cone 1.58×, solve 1.32×. `sec6_staged_vs_lazy.txt`
reproduces `numbers-1012/sec6_0903.txt` to the byte, so the scripts and the node mirror
are the ones the paper's numbers came from.

**Open with Ciaran, now with data:** with `--staged` off the layer still appears in only
5,026 of the 12,745 paired certified proofs, and 7,719 proofs are byte-equal to the staged
build's. So "every supplemental graph built, and its justification written, on every
instance" (above) is not what the proofs show; something else gates the layer on those
instances. The no-meshes line of the per-family tables is the same gate: the layer is never
derived on a mesh in either build.
