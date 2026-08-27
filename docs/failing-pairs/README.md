# Failing instance–config pairs — M7 grid, snapshot 2026-08-27 13:11

Snapshot of the grid launched 2026-08-24 19:13 (commits `184043a`, `3e8740f`), taken 66 h in.
**Six of nine columns are complete** (`gss`, `gss-noclique`, `gss-lazy`, `gss-lazy-base`,
`gss-nostaged`, `gss-norestarts` — all 25590 instances). `gss-proof` is at 98.5 %, `gss-nosupp`
at 92.7 %, `gss-cliques` at 41.9 %. The five `lad-*` columns sit at ~3.4 % and were never
relaunched, so **their last `=== RUN` block predates the 2026-08-24 `<=` parse fix** — see the
warning under category A.

Progress must be counted from the per-instance logs, never from the `[N/25590]` line in a
benchlog: that counter is block-buffered and was 17 h stale on one node and 66 h stale on
another while the columns ran normally.

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
| **B** | VERIFIED | VERIFIED | **FAILED** | **3815** | VeriPB accepts our trim, CakeML rejects it |
| **C** | FAILED | FAILED | — | **896** | solver's proof already bad; trim inherits it |
| **D** | **FAILED** | **VERIFIED** | VERIFIED | **1945** | trimming *rescued* a proof VeriPB rejected |

Out of 214410 pair-records. Category D is the paper-positive result, not a defect; C is upstream
of us.

---

## A — trimmer broke a verifiable proof · 33 pairs · `A_smol-failed_full-verified.tsv`

**Every genuine one is LAD. Zero Glasgow, across ~200,000 Glasgow pair-records.**

```
lad-alldiff-pl   17
lad-fc-pl        16
gss-*             0
```

The file also carries two rows with instance names `D` and `LVgIED`. Those are torn NFS
appends, not instances — do not chase them.

> **These 33 are almost certainly stale, and are NOT a live bug.** The `lad-*` columns were
> never relaunched after the 2026-08-24 `<=` parse fix, so the last `=== RUN` block in their
> logs is still a pre-fix run. A separate check found 33/33 passing at HEAD. Treat this
> category as **unmeasured for LAD** until those columns are re-run — do not open a bug from it.

The real conclusion from A is about Glasgow, and it is a strong one: **zero** trimmer-induced
verification failures across every completed Glasgow column.

## B — CakeML rejects a trim VeriPB accepted · 3815 pairs · `B_cake-smol-failed.tsv`

```
gss-nostaged    1230
gss-lazy         710
gss-lazy-base    702
gss-norestarts   692
gss-proof        479
gss-cliques        2
gss-nosupp         0
```

The largest open question in the grid, and it is **Glasgow-only**. Two checkers disagree about
the same trimmed proof: VeriPB accepts it, CakeML rejects it. One of them is wrong, and which
one matters for the end-to-end claim.

`gss-nosupp` scoring 0 while `gss-nostaged` scores 1230 is itself a lead — whatever CakeML
objects to appears to be absent from proofs built without supplementals.

## C — both proofs fail · 896 pairs · `C_both-failed.tsv`

```
gss-nosupp     768        gss-nostaged     5
gss-cliques    105        lad-alldiff-pl   2
gss-lazy-base    8        gss-proof        2
gss-norestarts   6
```

The solver's own proof does not certify, so the trim cannot. Upstream of the trimmer, and
concentrated in the two configurations that strip inference (`--no-supplementals`, `--cliques`).
`gss-lazy` contributes **zero**.

## D — trimming rescued the proof · 1945 pairs · `D_smol-rescued-full.tsv`

```
gss-nosupp     1910       gss-lazy-base    9
gss-nostaged     12       gss-cliques      3
gss-norestarts    9       gss-proof        2
```

On `gss-nosupp`, 1910 of 2678 rejected full proofs (**71 %**) are rescued by trimming. Keep that
pair of numbers together — it is the strongest single result in the grid, and it says the
trimmed proof certifies where the solver's own proof does not.

---

## Per-config health

```
config           pairs  vfullTO  vfullFAIL  trimmed
gss-cliques      13218     4.6%       1.1%    80.9%
gss-lazy         33887     0.4%       0.0%    85.8%
gss-lazy-base    33534     0.3%       0.1%    85.9%
gss-norestarts   33521     0.3%       0.1%    85.8%
gss-nostaged     30950     0.4%       0.2%    82.2%
gss-nosupp       33839     0.6%      11.3%    93.9%
gss-proof        32732     0.4%       0.0%    83.7%
```

`gss-nosupp`'s 11.3 % full-proof rejection rate is 50-100x every other column and drives all of
C and D. `gss-cliques`'s 4.6 % full-verify timeout rate is ~12x the others and is why that
column is the slowest by a wide margin (VeriPB p90 on its proofs is 569 s against 24-37 s
elsewhere, at comparable proof size — structure, not volume).

## Debug priority

1. **B (3815, Glasgow)** — checker disagreement. Now the top item: it is real, current, large,
   and it bears directly on the end-to-end CakeML claim. Pick one instance, diff the verdicts.
2. **A (LAD)** — re-run the `lad-*` columns post-fix before concluding anything.
3. **C / D** — upstream Glasgow proof defects. Not trimmer work; D is a result to report.
