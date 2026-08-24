# Incorporating CakeML checking — findings and plan

Written 2026-08-24, after establishing on `LVg10g12` that (a) the trimmed proof *is*
Cake-checkable, (b) `cake_pb_iso` has never accepted a Glasgow proof, and (c) the two
encodings differ by one loop order. Everything below is measured, not assumed; the
reproduce commands are inline.

Supersedes the M7.3 / M7.6 claim in `ROADMAP.md` that Cake-checking the trimmed proof is
"blocked by construction". It is not. A different thing is broken instead.

---

## 1. What is actually true today

### 1.1 The trimmed proof is Cake-checkable — via `cake_pb`, not `cake_pb_iso`

`~/CakePB-dev` ships two relevant frontends. Only one of them was ever built here.

```
$ cake_pb_iso
Usage: cake_pb_iso <LAD file (pattern)> <LAD file (target)> <optional: PB proof file>

$ cake_pb
Usage: cake_pb <OPB file> <optional: PB proof file> <optional: output OPB file>
```

`cake_pb` takes a supplied OPB. That is exactly what the trimmed proof needs, and it
works:

```sh
cd ~/CakePB-dev && make                       # builds cake_pb; only graph/cake_pb_iso existed
veripb -e smol.elab.pbp LVg10g12.smol.opb LVg10g12.smol.pbp   # s VERIFIED UNSATISFIABLE
cake_pb LVg10g12.smol.opb smol.elab.pbp                        # s VERIFIED UNSATISFIABLE
```

Mechanics that the harness must respect:

- **Cake needs the elaborated proof.** On the raw `.pbp` it stops at
  `rup 1 ~x20_9 >= 1` — the kernel format has no `rup`.
- **Exit codes.** `0` on success *and* on a check failure (`c Checking failed …` on
  stdout); `1` on `CakeML heap space exhausted.` (stderr). So `s VERIFIED` on stdout
  remains the only success signal, exactly as for `cake_pb_iso`, but a heap exhaustion is
  now separable from a rejection.
- **Cake cannot OOM the node.** Its heap is bounded by `CML_HEAP_SIZE` (MB, default 4096)
  and it fails cleanly when it hits it. VeriPB has no such bound — see §4.3.

Cost on `LVg10g12`, which is the smallest useful data point we have:

| stage | wall | peak RSS | output |
|---|---:|---:|---:|
| `veripb -e` full | 0.13 s | 31 MB | 421,508 B (2.24× the `.pbp`) |
| `cake_pb` full | 0.75 s | 304 MB | — |
| `veripb -e` trimmed | 0.05 s | — | 17,287 B (1.38× the `.smol.pbp`) |
| `cake_pb` trimmed | **0.07 s** | **35 MB** | — |
| `cake_pb_iso` encode only | 0.27 s | 117 MB | 823,592 B |

**Cake is the expensive checker** — ~8× VeriPB's time and ~10× its memory on the full
proof. But the trimmed proof is ~10× cheaper than the full proof on *both* axes. That
ratio is the quantitative core of the rescue claim in §3.

### 1.2 `cake_pb_iso` rejects Glasgow's proofs — M7.3 has never verified one

```sh
cake_pb_iso ~/veriPB/newSIPbenchmarks/LV/g10 ~/veriPB/newSIPbenchmarks/LV/g12 full.elab.pbp
# c Checking failed for top-level proof step starting at line: 4 … Reason: imply-add for
#   constraint id. expect: 1 ~x18 >= 1; from: <a 65-term constraint>
```

This is not new breakage. The only run that ever exercised the stage recorded it:

```
$ grep cake ~/veriPB/subgraphsolver/logs/LVg10g12.gss.gss-lazy.out
cake smol UNSUPPORTED encoder_rebuilds_model
cake ELAB SIZE 421508
cake full FAILED
```

So `M7.3 — Elaborate + CakeML check ⚠️ full proof only` in `ROADMAP.md` means *the stage
runs and reports*, not *it verifies*. **Zero Glasgow proofs have ever been
CakeML-certified in this project.** The `⚠️` was pointed at the wrong half: the trimmed
proof was the reachable one and the full proof was the broken one.

Correct `ROADMAP.md` and the `output.jl:566-571` comment when this lands.

### 1.3 The two encodings are the same formula in a different order

The reason for the rejection is *not* a different encoding. Normalising both files
(negated literals folded, `<=` flipped to `>=`, terms sorted) and comparing as multisets:

```
iso_enc.opb : 7810 constraints
LVg10g12.opb: 7810 constraints
multisets equal: True
same order (so same ids): False
  first id divergence at A index 1 (A id 2 -> B id 3)
```

Same 7810 constraints, same variable names (`x<p>_<t>`), same label scheme
(`@al`, `@am`, `@inj`, `@adj<i>_<j>_<k>`). They differ in emission order:

```
cake_pb_iso :  [ all @al ][ all @am ][ all @inj ][ @adj sorted by (j, i, k) ]
Glasgow     :  @al10 @am10 @al11 @am11 …          [ @adj sorted by (i, j, k) ]
                ^ interleaved per pattern vertex    ^ pattern-major, not target-major
```

The permutation is **computable from the labels alone** — no encoder run needed. Verified:

```
sort Glasgow's constraints by (class rank al<am<inj<adj, then j, i, k)
permuted Glasgow == iso:  True
```

(`@am` also differs by an equivalent normalisation — Glasgow writes `-1 x … >= -1`, iso
writes `1 x … <= 1`. Irrelevant: `cake_pb_iso` never reads Glasgow's OPB, it builds its
own. **The only thing that must agree is the constraint numbering the proof references.**)

**Caveat, and it is the one to close first: this is one instance.** `LVg10g12` is
non-induced, loop-free, no `--cliques`. A family with self-loops, or the `gss-cliques`
ablation (which adds clique constraints `cake_pb_iso` does not emit), may not have equal
multisets at all. See §5.1.

---

## 2. The four routes, and what each one certifies

The trust distinction matters more than the cost, so state it plainly:

- `cake_pb_iso pat tar proof` certifies **"no subgraph isomorphism exists between these
  two graphs"** — Cake derives the encoding from the graphs, so nothing between the
  benchmark file and the verdict is trusted.
- `cake_pb model.opb proof` certifies **"this OPB is unsatisfiable"** — the step from
  "the graphs" to "this OPB" is trusted, not checked.

| | route | certifies | works today | effort |
|---|---|---|---|---|
| **A** | `cake_pb` on full and trimmed | OPB is UNSAT | ✅ **verified above** | build `cake_pb`, ~40 lines of harness |
| **B** | reorder Glasgow's model emission into iso order | full proof: no SI exists | ❌ | one loop transposition + full re-validation |
| **C** | post-process id remap, no Glasgow change | same as B, full proof only | ❌ | new tool + an extra full-proof pass |
| **D** | B, plus a trimmed proof on the *original* id space that `del`s the model constraints outside the cone | **trimmed proof: no SI exists** | ❌ | B + a new writer mode |

### On B — "would it be easy to adapt Glasgow?"

Smaller than it sounds, and larger than it looks.

*Small:* mechanically it is emitting the level-0 model constraints target-major instead of
pattern-major, and the `@al`/`@am` blocks ungrouped instead of interleaved. §1.3 pins the
exact target order. Supplemental (`g1adj`…) and path (`pathg*`) constraints are *derived*
in the `.pbp`, not in the OPB — the model really is just `al`/`am`/`inj`/`adj` — so the
reorder touches only the model-emission site, not the proof machinery.

*Large:* every constraint id in every proof shifts. That means re-validating the trimmer,
re-checking the M3.5.2 label taxonomy (it keys on labels, which do not move, so this
should be a no-op — but "should" is not "checked"), and deciding what happens to the
harvested `39ca857` / `1ff87ba` data the appendix baseline columns are pinned to. It also
cannot help `gss-cliques`, whose extra constraints iso does not model at all.

**Recommendation: A now, B as a scoped follow-up, D only if B turns out cheap.** A is what
unblocks the run and produces the §3 result; B upgrades what the Cake column *means* and
can be measured on a subset later without redoing the grid.

### On C

Attractive because it needs nothing from upstream, and our parser/writer already renumber
ids. But it adds a full pass over the largest artefact in the pipeline for a claim B gets
for free once the loop is transposed. Keep as a fallback only if B is refused upstream.

### On D

The one that would put a *trusted end-to-end* verdict on a **trimmed** proof, which no one
has. It works because `cake_pb_iso` builds the whole model itself: a trimmed proof that
keeps the original ids and opens with `del` of the model constraints outside the cone is
a well-formed proof against that model. `writeconedel` currently renumbers
(`index[i] = lastindex`, `writer.jl:184`), so this is a second writer mode, not a change
to the existing one — the renumbered `.smol.opb` is still what the size columns need.

---

## 3. The result this unlocks: trimming rescues verification

With A in place, both halves of the comparison exist for the first time:

```
full proof   ── veripb -e ──► elaborated ── cake_pb ──►  verdict_full
trimmed proof ─ veripb -e ──► elaborated ── cake_pb ──►  verdict_smol
```

The claim to test is: **there are instances where `verdict_full ∈ {timeout, memout,
failed}` and `verdict_smol = verified`** — i.e. trimming produces a certificate for
instances that cannot be certified untrimmed. The 10× time-and-memory ratio in §1.1 says
the mechanism is there; the `hard` rows of the appendix are exactly the population where
it should fire.

Three things this requires of the pipeline, and all three are the user's point:

1. **Trim runs regardless of what the full check said.** Already true — the trim is a
   sibling of the full check, not a child of it (`ROADMAP.md` M7.6, indentation note).
   Do not let W2's reorder quietly make it a child.
2. **Keep trim *before* the full check.** M7.6 specifies check-then-trim and justifies it
   on peak disk. That justification mostly evaporates here: trim-then-check peaks at
   `full + smol + elab` against `full + elab`, and `smol` is 9–24 % of `full`. What
   trim-first buys is that a 6000 s full-elaboration timeout followed by a 6000 s Cake
   timeout no longer runs *before* we have the cheap verdict — on the `hard` rows that is
   most of the budget, spent before the result we care about. **Recommend trim-first and
   amend M7.6.**
3. **Record every verdict distinctly.** `timeout`, `memout`, `heap-exhausted`, `failed`
   and `verified` must be separable per (proof, checker). Today they are not — see §4.2.

---

## 4. Harness work items

Numbered to extend M7.6's W-list rather than replace it.

### W1′ — one elaboration per proof, shared by both checkers

Fold `verify` (`output.jl:525`) and `cakecheck` (`output.jl:577`) into
`check_proof(ins, which)` for `which ∈ {:full, :smol}`:

```
veripb -e <elab> <opb> <pbp>     → the VeriPB cell     (tl vt)
cake_pb <opb> <elab>             → the Cake cell       (tl ct)
rm <elab>
```

`run_verif`'s exit-code mapping carries over verbatim. This removes the current
double-verification of the full proof (bare `veripb` in `verify`, then `veripb -e` inside
`cakecheck`) which is M7.6's largest single saving. Sound because `-e` only adds RUP hints
to what the bare check already does.

Cake path: new `CAKE_PB` env + `cakepbpath`, keeping `CAKE_PB_ISO` for the LAD arm and for
route B later. Set `CML_HEAP_SIZE` explicitly (§4.3).

### W3′ — Cake on the trimmed proof (was "blocked by construction")

`check_proof(ins, :smol)` is now the same code as `:full`. Delete the
`logstage(ins, "cake smol UNSUPPORTED", …)` line and the comment block above `cakecheck`
that justifies it.

### W4′ — the recursion gate is no longer blocked

M7.6's W4 wanted the coreN recursion gated on Cake accepting the trimmed proof, and
recorded that as partly impossible. With W3′ it is a plain condition:
`cake(:smol) == :verified && writeunsatcore` produced a strictly smaller core.

### W7 — checker memory containment *(new, and it gates the hard rows)*

The whole §3 result lives on instances where the full check blows up, so the harness must
survive that predictably.

- **Cake is safe by construction:** `CML_HEAP_SIZE` bounds it and it exits 1 with
  `CakeML heap space exhausted.` Pick a value against `maxmem=` and log it; map exit 1 +
  that stderr string to a `:heapout` status distinct from `:failed`.
- **VeriPB is not.** Nothing caps it. The OOM monitor (`orchestrator.jl:599`) watches only
  trimmer subprocesses and Glasgow, so a runaway elaboration is invisible to it and the
  kernel OOM killer may take the *orchestrator* rather than the checker. Run every
  `veripb` under an explicit cap — `ulimit -v` in the spawn, or teach the monitor a third
  process type. Note the existing monitor already needs the `(binary, extractor)` table
  from *Known Design Flaws*; this is the third entry.

### W8 — log keys and CSV columns *(new)*

`aggregate_results.jl` currently reduces the trimmed verdict to
`veri_smol_verified ∈ {1, ""}` (lines 353–354): it matches the literal string
`veri smol VERIFIED`, and `veri smol FAILED` / `TIMEOUT` / `MEMOUT` all fall through to an
empty cell, indistinguishable from "never ran". **The §3 result cannot be computed from
that.** Needed:

| column | from |
|---|---|
| `veri_smol_status`, `veri_full_status` | `veri <which> <STATUS>` |
| `veri_smol_time`, `veri_full_time` | already logged |
| `cake_smol_status`, `cake_full_status` | `cake <which> <STATUS>` |
| `cake_smol_time`, `cake_full_time` | `cake <which> TIME` |
| `elab_smol_size`, `elab_full_size` | `cake <which> ELAB SIZE` |

Keep `veri_smol_verified` as a derived column so `config_grid.py` keeps working unchanged.

### W9 — `.err` must reach the head node *(new)*

`aggregate_results.jl` enumerates instances from **`logdir`**, not the proofs dir
(line 508), and every field `config_grid.py` uses (`inp_total_size`, `grim_total_size`)
comes from the log. Since `/cluster` is NFS-shared and `/scratch` is node-local, **one
aggregation on the head node can cover all nine configurations** — except that `.err` is
read from the node-local proofs dir. Either mirror `.err` content into the log (M7.4
already asks for this: "mirror it into the log so one file is enough to fill a cell"), or
have the per-node seal step copy `*.err` to `/cluster`. Prefer the former.

---

## 5. Validation before any cluster time

### 5.1 Is §1.3 family-independent? *(blocks route B, not route A)*

The multiset equality is verified on `LVg10g12` only. Run one small instance per family
plus one `--cliques` instance, and compare with `scripts/opb_vs_iso.py` (to be extracted
from the scratch script used here). Expected failures: `gss-cliques` (extra constraints),
anything with self-loops. Record which configurations can *ever* be iso-checkable.

### 5.2 Route A end-to-end on the standard instance

```sh
./trimnalyser LVg10g12 overwrite resolv verif cake config=gss-lazy nosys
```

Expect `veri smol VERIFIED`, `veri full VERIFIED`, `cake smol VERIFIED`,
`cake full VERIFIED` — the last two for the first time in this project.

### 5.3 Cake cost calibration *(the number that sizes the grid run)*

Cake at scale is entirely unmeasured — the 8-18 run predates M7 and never ran the stage.
§1.1 gives 8× VeriPB on a 188 KB proof; the median cluster proof is three orders larger
and the `hard` rows larger still. One config, a stratified few-thousand-instance
`instfile=` subset, full pipeline, **before** committing nine nodes. Deliverables:
cake time and heap as a function of elaborated-proof size, the `heapout` rate at the
chosen `CML_HEAP_SIZE`, and the §3 rescue count on a real population.

---

## 6. Cluster scripts to write

Environment, confirmed 2026-08-24: nodes `fataepyc-01`…`-17`, reachable **only** via
`ProxyJump fataepyc-head` (the old FQDNs no longer route). `/cluster` is NFS-shared
(18 T, 13 T free) and holds the logs; `/scratch` is node-local (7 T, 6.6 T free) and holds
the proofs; `/users/grad` is shared NFS. SSH does not source `.bashrc`, so every remote
command needs `bash -lc`.

| script | does |
|---|---|
| `scripts/cake_setup.sh` | `make` both frontends in `~/CakePB-dev`, deploy `cake_pb` + `cake_pb_iso` to `/scratch/arthur/`, print the CakeML/HOL4 revisions into the run record |
| `scripts/preflight.sh` | on a node: assert every binary exists and is executable (`glasgow_subgraph_solver` per pinned revision, `veripb`, `cake_pb`, `lad`), assert `/scratch/arthur/newSIPbenchmarks` is populated, assert `/cluster/arthur/logs` is writable, print free space, print `git rev-parse HEAD` for trimnalyser and Glasgow. Refuses rather than warns — a missing `veripb` currently costs a whole run one yellow line |
| `scripts/run_config.sh <config> [instfile]` | one configuration on the current node under `nohup`/`tmux`, with the timeouts **pinned** (`stnopl=60 st=600 tt=6000 vt=6000 ct=6000`) rather than left to defaults (`st=5`, `tt=45`) — M7.6 W5 |
| `scripts/dispatch_grid.sh` | assign the nine Glasgow configurations to nodes over `ssh -J`, run preflight on each, refuse to launch if any fails, record the node↔config map into `/cluster/arthur/logs/GRID_MAP` |
| `scripts/seal_run.sh` | per node, after the run: mirror `*.err` / `*.cake.err` / `*.veripberr` to `/cluster` (unless W9 makes this unnecessary), write a per-node manifest |
| `scripts/harvest_all.sh` | **one** aggregation on the head node over the shared logs → a single `cluster_results.csv` carrying all nine configurations in its `config` column. Replaces nine separate `harvest.sh` invocations; note `harvest.sh`'s `.harvest_source` clobber guard assumes one config per output set |
| `scripts/rescue_table.jl` | the §3 result: per family × config, the count and rate of `full ∈ {timeout,memout,failed,heapout} ∧ smol = verified`, separately for VeriPB and Cake, with the `hard` subset broken out |

`config_grid.py --selftest` must still reproduce the published `39ca857` column after the
CSV schema change in W8.

---

## 7. Open questions

- **Does `cake_pb` on our own OPB earn a table column at all?** It certifies "this OPB is
  UNSAT", so the honest caption is narrower than the LAD table's Cake footnote, which is
  a genuine end-to-end claim. Either state the narrower claim explicitly, or hold the Cake
  column until route B lands. Decide before the grid run, not after.
- **What is the `CML_HEAP_SIZE` for the grid?** It trades `heapout` rate against node
  memory at 75 instances in flight. Comes out of §5.3.
- **Does route B invalidate the harvested baseline columns?** The appendix pins
  `39ca857` deliberately. If B changes ids, the pinned revision cannot also carry B, so
  the Cake column and the compression columns would be measured on different builds.

---

## 8. Every route, and what each costs

Added 2026-08-24, replacing the four-row sketch in §2 with the full enumeration. Runtime
figures are `LVg10g12` (890 KB `.opb` / 188 KB `.pbp`), the only measured point we have —
treat them as ratios, not absolutes. "Work" is implementation plus the validation the
route needs before it can be trusted, not keystrokes.

### Group 1 — works today, no new artefacts

| # | Route | Certifies | Work | Runtime / instance |
|---|---|---|---|---|
| **R1** | `cake_pb <full.opb> <full.elab>` | the full OPB is UNSAT (encoding trusted) | **½ day** — `make` in `~/CakePB-dev`, deploy, `CAKE_PB` env, swap the invocation in `cakecheck`; do it inside W1′ so the elaboration is shared | +0.75 s, 304 MB peak |
| **R2** | `cake_pb <smol.opb> <smol.elab>` | the trimmed OPB is UNSAT | **½ day** — same code path with `which=:smol`; delete the `UNSUPPORTED` line; W8 CSV columns | +0.07 s, 35 MB peak |
| **R3** | R1 **and** R2, verdicts recorded separately | the §3 rescue result: full uncheckable ∧ trimmed checked | **1 day** on top — `rescue_table.jl` | sum of the two |
| **R10** | R2 on every `.coreN` resolv iteration | same as R2, per iteration | **2 h** — `run_resolv_loop` calls `verify` but never `cakecheck` | ×iterations |
| **R11** | LAD arm: `cake_pb_iso` on LAD proofs (its native frontend), `cake_pb` on LAD's `-O` OPB as the weaker variant | LAD: no SI exists / OPB UNSAT | **1 day** — mostly W6's `-P` collision bug, which today makes both `lad-*-pl` configs write no proof at all | LAD-side |

### Group 2 — needs a new trimmer output, no Glasgow change

| # | Route | Certifies | Work | Runtime / instance |
|---|---|---|---|---|
| **R9** | R2 **+** a check that `.smol.opb ⊆ .opb` | the **full** OPB is UNSAT, via the trimmed proof | **1 day** — `writeconedel` already builds the `index[]` map (`writer.jl:184`); log it and the check is a lookup, not a search | negligible |
| **R7** | trimmed proof on the **original** id space, opening with `del` of the out-of-cone model constraints, checked as `cake_pb <full.opb> <smol_origids.elab>` | the full OPB is UNSAT, from the cone alone, no containment argument needed | **2 days** — second writer mode beside `writeconedel`; `dels` bitvector already exists | proof cost drops ~10×, **model cost does not** — must be measured, R1's 304 MB is mostly model |

R9 and R7 are alternatives to each other: both upgrade R2's claim from "the trimmed OPB"
to "the original OPB". R9 is cheaper and keeps the small `.smol.opb`; R7 is stronger
(nothing outside Cake is trusted) but pays the full model on every check.

### Group 3 — needs the model ids to match `cake_pb_iso`

| # | Route | Certifies | Work | Runtime / instance |
|---|---|---|---|---|
| **R4** | reorder Glasgow's `emit_model`, then `cake_pb_iso <pat> <tar> <full.elab>` | **no subgraph isomorphism exists** — nothing between the benchmark file and the verdict is trusted | **2–4 days.** The edit is ~35 lines in two files: split `create_cp_variable` (`proof.cc:107`) into its `@al` and `@am` halves and run them as two loops, and transpose the `for p / for t` nest at `homomorphism_proofs.cc:679` to `for t / for p`. All the risk is downstream — 42 `ctest`s, VeriPB re-verification, trimmer label/cone equivalence, and the revision-pinning question in §7 | replaces R1: iso rebuilds the model instead of reading it |
| **R5** | post-process: permute the model ids and rewrite the proof's references, then R4's check — **no Glasgow change** | same as R4 | **3–5 days** — new tool; only model ids ≤ `nbopb` permute (derived ids are unaffected, the model size is unchanged), and our `SystemLink` already indexes every reference | one extra full pass over the largest artefact, **permanently** |
| **R8** | R4 (or R5) **+** R7's writer → `cake_pb_iso <pat> <tar> <smol_origids.elab>` | **no SI exists, certified from a trimmed proof** — the cell nobody has | R4 + R7 + joint validation | iso rebuilds the full model; only the proof shrinks |

### Group 4 — audit and research

| # | Route | Certifies | Work | Note |
|---|---|---|---|---|
| **R6** | `cake_pb_iso <pat> <tar>` with no proof → encoding, compared to our `.opb` by `scripts/opb_vs_iso.py`; combined with R1 | close to R4, but the encoding-equivalence step rests on **our** 150-line comparator, not on HOL | **1 day** as a sampling audit | Not viable as a per-instance stage: the encoder is the 4.20 GB / 10.5 s memory ceiling on meshes (`ROADMAP.md` M5-proof-trim). Its real use is proving the §1.3 permutation is *structural*, after which R4 needs no per-instance encoder run at all |
| **R12** | make trimming a VeriPB **output claim**, checked by `cake_pb <in.opb> <proof> <out.opb>` (the third argument) | that `.smol.opb` is genuinely implied by `.opb`, *verified* rather than argued | **not scoped — weeks** | The only route that makes R9's containment a machine-checked step. The trimmed proof is not in that shape today |
| **R0** | no Cake; VeriPB only | VeriPB's word | none | The honest fallback if the Cake column cannot be given a caption we can defend |

### Reading the table

- **R1+R2+R3+R10 is one working day and unblocks the whole §3 result.** Nothing in it
  depends on any other route, and it is a prerequisite for every route below it.
- **R9 is the cheapest meaningful upgrade in trust** and should probably ship with R2.
- **R4 is the only route that changes what the Cake column *means*** for Glasgow. Its
  effort is not in the patch; it is in re-validating everything keyed on constraint ids and
  in deciding whether the appendix's pinned revisions can carry it.
- **R8 is the prize** and is exactly R4 + R7, so it costs nothing new to *decide* — only to
  validate once both halves exist.
- **R5 exists so that R4 being refused upstream is not the end of the line.** Do not build
  it first.

### Two unknowns that could move R4

1. `emit_preserved_assignment_variables()` writes a `preserved:` line that
   `cake_pb_iso`'s own encoding does not have. Harmless for an UNSAT decision proof in
   principle; unverified.
2. §1.3's multiset equality is one instance. `gss-cliques` adds constraints iso does not
   model at all, so that ablation column can never be iso-checkable whatever R4 does.
