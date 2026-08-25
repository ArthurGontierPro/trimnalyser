# Failing instance–config pairs — M7 grid, snapshot 2026-08-25 12:25

Snapshot of the grid launched 2026-08-24 19:13 (commits `184043a`, `3e8740f`), taken
17.2 h in, with seven of nine columns still running. **These are partial columns** — the
counts will grow, but the *shape* of each category is already stable.

## Method, and one caveat that matters

Built from the per-instance logs `/cluster/arthur/logs/<instance>.<solver>.<config>.out`,
not from the benchlogs. Two reasons:

1. Those logs are **append-only** and may carry a 1/60-scale smoke-run block from earlier
   the same evening. Every figure here comes from the **last** `=== RUN` block only.
2. The benchlog console text interleaves across 92 threads, so a `rup failed at N` line
   there cannot be attributed to an instance. The per-instance logs can.

**Caveat — torn NFS appends.** 2268 of 73051 pair-records (3.1 %) carry a mangled config
name (`gssgss-nostaged`, `ed`, `d`) from concurrent appends on shared NFS. They are excluded
from every count below. They also corrupt any *mean*: an unfiltered mean solve time comes out
at 22589 s against a 600 s timeout. **Use p90, never mean, on this data.**

Reproduce with the scripts left in `/cluster/arthur/scan/` on the cluster.

## The four categories

`veri` = VeriPB, `cake` = CakeML. `full` = the solver's own proof, `smol` = our trimmed proof.

| | veri full | veri smol | cake smol | pairs | meaning |
|---|---|---|---|---|---|
| **A** | VERIFIED | **FAILED** | — | **33** | we broke a good proof — *the only true trimmer bug* |
| **B** | VERIFIED | VERIFIED | **FAILED** | **1179** | VeriPB accepts our trim, CakeML rejects it |
| **C** | FAILED | FAILED | — | **249** | solver's proof already bad; trim inherits it |
| **D** | **FAILED** | **VERIFIED** | VERIFIED | **571** | trimming *rescued* a proof VeriPB rejected |

Category D is the paper-positive result, not a defect. C is upstream of us.

---

## A — trimmer broke a verifiable proof · 33 pairs · `A_smol-failed_full-verified.tsv`

**Every one is LAD. Zero Glasgow.**

```
lad-alldiff-pl   17
lad-fc-pl        16
gss-*             0     <- across ~60,000 trimmed Glasgow proofs
```

16 of the 17 instances are common to both configs, and all are small `LVg*`. So this is
**instance-determined, not config-determined** — one bug in the LAD trim path, reached by a
graph property rather than by a solver flag.

`LVg10g12` is in the list, which is the standard local test instance. That makes this
directly reproducible off-cluster:

```bash
./trimnalyser LVg10g12 overwrite resolv verif config=lad-alldiff-pl nosys
```

This is the **only** category worth debugging as a trimmer defect, and it is the highest
priority in this report despite being the smallest. Note it survives the 2026-08-24 `<=`
parse fix, so it is a *second*, distinct LAD problem — do not assume that fix covers it.

## B — CakeML rejects a trim VeriPB accepted · 1179 pairs / 790 instances · `B_cake-smol-failed.tsv`

```
gss-nostaged    400        cviu11_*   1168  (99.1%)
gss-norestarts  243        LVg*         11
gss-lazy        224
gss-lazy-base   216
gss-proof        96
gss-cliques       0
gss-nosupp        0
```

Not instance-determined — 504 of the 790 instances fail in exactly one config:

```
fails in 1 config: 504    4 configs:  16
            2:     201    5 configs:   1
            3:      68
```

So the same instance trimmed under a different flag set yields a proof CakeML accepts. That
points at **proof content**, not graph structure — consistent with the known cviu11 pathology
(Glasgow emitting unjustified `@elimnds* rup` helper lemmas), but the disagreement here is
*between the two checkers*, which is new. Worth a single-instance diff of what `cake_pb`
objects to versus what `veripb` waved through.

Both `gss-nosupp` and `gss-cliques` score zero here, but both are also behind on progress —
treat their zeroes as **not yet observed**, not as clean.

## C — both proofs fail · 249 pairs · `C_both-failed.tsv`

```
gss-nosupp     199        cviu11_*  206
gss-cliques     41        LVg*       43
gss-lazy-base    3
gss-nostaged     2
gss-norestarts   2
lad-alldiff-pl   2
```

The solver's own proof does not certify, so the trim cannot. Upstream of the trimmer.
`gss-lazy` and `gss-proof` contribute **zero**.

## D — trimming rescued the proof · 571 pairs · `D_smol-rescued-full.tsv`

```
gss-nosupp     554        cviu11_*  570
gss-lazy-base    7        LVg*        1
gss-nostaged     6
gss-norestarts   3
gss-cliques      1
```

C and D are near-disjoint (1 instance in both), so on `gss-nosupp` a rejected full proof is
**74 % likely to be rescued by trimming** (554 of 753). Keep this pair of numbers together —
it is the strongest single result in the snapshot.

---

## Debug priority

1. **A (33, LAD)** — a real trimmer bug, reproducible on `LVg10g12` locally, no cluster needed.
2. **B (1179, cviu11)** — checker disagreement; pick one instance and diff the two verdicts.
3. **C / D** — upstream Glasgow proof defects. Not trimmer work; D is a result to report.
