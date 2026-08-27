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
| **B** | VERIFIED | VERIFIED | **FAILED** | **3815** | ~~our trim~~ — **CakeML bug, fixed upstream 2026-08-26 and worked around in `writepol`** |
| **C** | FAILED | FAILED | — | **896** | solver's proof already bad; trim inherits it |
| **D** | **FAILED** | **VERIFIED** | VERIFIED | **1945** | **solver bug** — it emitted a proof that does not certify |

Out of 214410 pair-records.

**C and D are both solver bugs, and they are ours.** We maintain Glasgow, so a proof that VeriPB
rejects is our defect, not an external constraint. That the trimmed proof happens to certify in
category D is *not* a positive result — it means the solver emitted something unsound or
unjustified, and trimming removed the offending steps by accident. The bug is still there and
still needs fixing; D just measures how often trimming hides it. Do not report D as a win.

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

## B — CakeML rejects a trim VeriPB accepted · 3815 pairs · RESOLVED · `B_cake-smol-failed.tsv`

```
gss-nostaged    1230
gss-lazy         710
gss-lazy-base    702
gss-norestarts   692
gss-proof        479
gss-cliques        2
gss-nosupp         0
```

**RESOLVED 2026-08-27 — a CakeML bug, not ours. VeriPB was right and no code change was
needed on our side.**

**The defect.** Weakening (`w`) removes a variable's terms from a constraint and lowers the
degree by its coefficient. If the variable is not in the constraint its coefficient is 0, so
the step is a **no-op** — legal, and the same situation as the duplicate-weakening case the
CakeML author had seen before. CakeML did not treat it as a no-op: it skipped or misaligned,
and built a *different* constraint from the one VeriPB built. Nothing failed at the `w` itself.
The divergence surfaced much later, at the first `ia` — the only rule with an explicit
implication side condition, so the only place where a silently wrong constraint gets compared
against anything.

**Why our proofs and only ours.** The trimmer drops literals the cone does not need and lowers
the degree to match, but Glasgow's `w` tokens are copied through `writepol` verbatim. A trimmed
proof therefore routinely weakens literals that are no longer there. The untrimmed proof never
does, which is why `veri full` passes on all 3815.

**Verified sound on the reproducer** (`LVg11g58`, `gss-lazy-base`). Constraint `112` loses
`x0_94 x1_94 x2_94 x6_94` to the trim; the first `pol` weakens all four. The degree compensates
exactly:

```
trimmed    112: 38 lits, deg 37;  36 of the 40 w's hit  ->  ~x3_94 ~x4_94 >= 37-36 = 1
untrimmed  112: 42 lits, deg 41;  40 of the 40 w's hit  ->  ~x3_94 ~x4_94 >= 41-40 = 1
```

Identical. The literals the trim removed were the ones about to be weakened away regardless.

**Fixed upstream.** Reported 2026-08-26 with a 1.1 MB reproducer (`/cluster/arthur/repro/`, a
literal truncated prefix of `LVg11g58.smol.pbp` — nothing renumbered); fixed the same day in
`cakepb-dev` `c41ce52` *"fix a bug in weakening"* on `develop`. Rebuilt and rechecked:

```
old cake_pb  ->  Checking failed ... line 67977 ... imply-add for constraint id
new cake_pb  ->  s VERIFIED
```

**Fixed on our side too, and that is the one that matters.** `writepol` no longer emits a
`<lit> w` pair when the variable cannot be on the pol stack at all (`4977151`). The trimmed
proof therefore never contains the construct, so it no longer depends on how a checker treats a
vacuous weakening. Measured on `LVg11g58`/`gss-lazy-base`, same solved proof in both arms:

```
                          arm A (main)   arm B (4977151)
w tokens in .smol.pbp            7560              6804     -10 %
.smol.pbp                  11 182 146        11 176 098
.smol.opb                        identical
veripb                   VERIFIED UNSAT    VERIFIED UNSAT
cake_pb (old, unfixed)   FAILED @67977     VERIFIED UNSAT
cake_pb (new, c41ce52)          -          VERIFIED UNSAT
```

**The old binary now accepts it.** Staging the rebuilt `cake_pb` into `/cluster/arthur/dist` is
therefore no longer on the critical path for this category — worth doing, but the grid can clear
B without it. Only the one instance is confirmed: the other 3814 pairs cannot be rechecked from
disk (the `.opb`/`.pbp` are deleted after verification), so confirming the category as a whole
still means re-running them.

`gss-nosupp` scoring 0 while `gss-nostaged` scores 1230 is consistent with this — long `w`
chains over supplemental-derived constraints are the shape that triggers it — but that link
was never checked directly and is not needed now.

**Do not resurrect the trimmer-side fixes.** `iakeep` and `iaprop` were built and measured on
`diag/littrim-experiment` before the cause was known; both are gone. Literal trimming can be
disabled without a flag anyway, by setting the conelits to true.

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

## D — solver emitted a proof that does not certify · 1945 pairs · `D_smol-rescued-full.tsv`

```
gss-nosupp     1910       gss-lazy-base    9
gss-nostaged     12       gss-cliques      3
gss-norestarts    9       gss-proof        2
```

On `gss-nosupp`, 2678 full proofs are rejected by VeriPB; trimming makes 1910 of them (**71 %**)
certify. Read that as a **solver defect with a 71 % masking rate**, not as a trimmer win — the
trim is deleting steps Glasgow should never have emitted.

Combined with C, `gss-nosupp` emits a non-certifying proof on **11.3 %** of instances. That is
the single largest bug surfaced by this grid and it belongs upstream, in Glasgow. See
[[project-glasgow-unjustified-rups]] — `@elimnds` was fixed in `1ff87ba`, `@binback` is known and
still unfixed, and these numbers are the scale of what remains.

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
C and D. It is a Glasgow bug, not a property of the benchmark. `gss-cliques`'s 4.6 % full-verify timeout rate is ~12x the others and is why that
column is the slowest by a wide margin (VeriPB p90 on its proofs is 569 s against 24-37 s
elsewhere, at comparable proof size — structure, not volume).

## Debug priority

1. **C + D together (2841 pairs)** — Glasgow emits proofs that do not certify. Ours to fix, and
   now the biggest defect in the grid by volume. `gss-nosupp` alone accounts for 2678 of them.
2. **A (LAD)** — re-run the `lad-*` columns post-fix before concluding anything.
3. **B (3815)** — cause found, fixed upstream *and* worked around in `writepol`. What remains
   is bookkeeping: re-run the category to confirm it empties. The old `cake_pb` suffices.
