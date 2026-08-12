# TrimAnalyser — Research Roadmap

TrimAnalyser supports all 8 newSIP benchmark families, extracts UNSAT cores via the resolv loop, outputs ~160-column CSV per run, and maps proof cone leaves back to CP constructs via labelled Glasgow proofs.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-07-27:** M1–M2.5, M3.5.1–M3.5.3, M3.5.5, M3.5.6, M3.5.7 complete. M3.5.4 still open. M4.1 (lazy supplemental generation) pivoted: our own per-vertex prototype abandoned, Ciaran's upstream proof-compatible implementation adopted and relabelled on `lazy-adjacency-relabelled`, not yet merged into the reference `labels-for-analysis` branch. **Paper scope decided:** characterisation-only (cone-vs-full + resolv shrinkage), M4/M4.1 as future work — see "Paper scope decision" below. **Full run launched 2026-07-27** on `lazy-adjacency-relabelled` — characterisation stats only, single-arm (see "Cluster run — 2026-07-27" below). Next: harvest, then reassess — either write up, or pull M5 (cross-solver) forward for more results.

**Update 2026-08-12 — a second proof-producing solver now exists.** The LAD solver (Solnon's; repo `~/ladveri`, `git@github.com:ArthurGontierPro/ladveri.git`) has VeriPB proof logging, verified end-to-end through CakeML. This is relevant to M5, which until now could only have compared against *non*-proof-producing solvers. It is **not yet ready for a cluster arm** — see "M5" below for the honest capability list before planning around it.

---

## M1–M2.5 — Infrastructure ✅

- **M1** — Full newSIP benchmark coverage (8 families, `allgraphinstances()` in `src/orchestrator.jl`).
- **M2** — Proof-to-feature extraction (~160 CSV columns: step-type fractions, cone depth distribution, RUP/POL depth profiles, compression rate, resolv shrinkage, exhaustive M3.5.2 cone labels). Graph features in `scripts/graph_features.jl`.
- **M2.5** — Pipeline timeout correctness (orchestrator threads with independent `st`/`tt`/`vt` budgets, OOM monitor).

---

## M3 — Graph taxonomy and heuristic fingerprinting ✅

**Goal:** Characterise which graph families and structural properties predict proof difficulty and solver behaviour.

### Family feasibility — SAT vs UNSAT by construction

Source: Solnon 2019 (GBR), Table 2. All counts are non-induced SI instances.

| newSIP family | Paper class | SAT | UNSAT | Notes |
|---|---|---|---|---|
| `si` (bvg, m4D, rand) | randBVG + randM + randER | 1,170 | **0** | Pattern extracted from target — always SAT by construction |
| `scalefree` | randSF | 80 | 20 | ~80% SAT by construction; 20 instances not guaranteed |
| `phase` | randERP | 164 | 36 | Near phase transition — mixed, hard by design |
| `LV` | LV | 596 | 3,235 | Mostly UNSAT |
| `bio` | biochemical | mixed | mixed | Both SAT and UNSAT |
| `images-CVIU11` / `images-PR15` | images | 52 | 6,250 | Overwhelmingly UNSAT |
| `meshes-CVIU11` | meshes | 88 | 2,930 | Overwhelmingly UNSAT |

### First pass — manual analysis

Full write-up in `paper/notes.tex` (§3 families, §4 fingerprints, §5 drivers, §6 heuristic implications, §7 open questions).

**Key finding — images vs meshes:**

| Feature | images-CVIU11 | meshes-CVIU11 |
|---|---|---|
| `ia_frac` | **~50%** | ~0% |
| `pol_frac` | ~50% | **~100%** |
| `cone_depth_max` | **93.6** | 2.0 |
| `cone_depth_entropy` | **2.18** | 0.01 |
| `pol_ante_mean` | 5.45 | **15.97** |
| `resolv_pat_shrinkage` | 0.13 | **0.38** |

Mesh shape = "single-wave algebraic certificate" (depth ≈ 1, pure POL, OPB-heavy). Image shape = "propagation cascade" (deep IA chains, PBP-heavy). Key structural drivers: width–depth tradeoff (pol_ante_mean × cone_depth_max inversely correlated), clustering → proof flatness, node ratio → resolv effectiveness.

### Cluster run — 2026-06-22 (harvested)

15,431 instances, 15,394 with graph features, 6,920 `.coreN` resolv iterations. Full innerjoin coverage (was 1,708/3,590 before). Reports in `6-22-fullrun/`: `proof_survey.html`, `classify_supplementals.html/.txt`, `cluster_results.csv`, `graph_features.csv`. Before/after merge comparison in `6-22-median-run-{before,after}-merge/`.

### Cluster run — 2026-06-29 (harvested)

31,417 instances (LV 8,277 / bio 11,914 / images-CVIU11 6,226 / meshes-CVIU11 4,718 / images-PR15 16 / phase 165 / scalefree 101). Reports in `6-29-fullrun/`: `proof_survey.html`, `classify_supplementals.html/.txt`, `cluster_results.csv`, `graph_features.csv`, `cone_vs_full.html`, `oracle_scatter.html`.

**Supplemental usage findings (from classify_supplementals):**

| Family | Instances | g1adj > 0 | Rate | Median g1adj |
|---|---|---|---|---|
| LV | 3,770 | 297 | 8% | 0 |
| bio | 7,637 | 4,194 | 55% | 12 |
| images-CVIU11 | 804 | 804 | 100% | 38,178 |
| meshes-CVIU11 | 2,102 | 10 | 0% | 0 |

No proof data yet for: images-PR15, phase, scalefree, si (SAT-dominated or timeout-limited).

### Cluster run — 2026-07-27 (in progress)

Launched `./trimnalyser --threads 75,1 solve resolv verif allgraphs st=600 tt=6000 rand` — same parameters as the 6-29 run (reconstructed from its log header: `minnodes=0`, `maxnodes` unset, 75 threads, `maxmem=50`/`minmem=100` defaults, 1052 solver timeouts at 600s, `Timeout after 6000s` trim cap, no `overwrite`).

**Solver branch: `lazy-adjacency-relabelled` (`39ca857`)**, not `labels-for-analysis`. Single-arm by decision — characterisation stats on the latest branch only; the M4.1 timing A/B is deferred (see M4.1 below).

**Environment rebuilt from scratch.** `/scratch` was recreated ~2026-07-06 and the machine reimaged ~07-08, destroying `/scratch/arthur/` entirely (proofs, benchmarks, solver and veripb binaries) and dropping the C++ dev packages. Restored: benchmarks re-copied from `~/newSIPbenchmarks`, Glasgow rebuilt, `veripb` v3.0.2 re-deployed from `~/veripb-dev/target/release/veripb`. GMP headers are no longer installed system-wide — they now live in `~/local` (unpacked `.deb`s, no sudo needed); Glasgow must be configured with `-DGMP_INCLUDE_DIR=$HOME/local/include -DGMP_LIBRARY=$HOME/local/lib/libgmp.so -DGMPXX_LIBRARY=$HOME/local/lib/libgmpxx.so` plus `-Wl,-rpath,$HOME/local/lib`. Boost is **not** required (`gss/CMakeLists.txt` only looks for GMP/GMPXX).

**Pre-flight validation** (7692-instance smoke run, `st=6 tt=60 minnodes=10 maxnodes=100`, 301.8s at 1529 inst/min): 10337 instances with proofs, **zero verification failures** (10337 smol + 10337 full VERIFIED), zero truncated, 77 errors all `Timeout after 60s` from the deliberately short trim cap. Sentinels (`.done`/`.sat`/`.timeoutNNN`) working. All 6 `harvest.sh` stages produced output. Smoke artefacts parked in `~/smoke-2026-07-27/` on the cluster. That smoke config covers only LV and bio — the larger families (images, meshes, PR15, phase, scalefree, si) have targets of 150–4838 nodes and are excluded by `maxnodes=100`; at `st=30` they predominantly hit the solver timeout or OOM, which is expected at those sizes.

### Open questions (`notes.tex §7`)

- **Two-axis classifier:** `cone_depth_entropy × pol_frac` as primary family discriminants.
- **Scalefree proof coverage:** 20 UNSAT instances exist; determine how many complete within timeout.
- **Intra-family scaling:** proof size as O(|V(P)|), O(|V(T)|), or O(|V(P)|·|V(T)|)?
- **Intra-LV sub-fingerprinting:** `pat_deg_var` and `pat_is_bipartite` as stratification axes.

### Second pass — automated clustering

Cluster by `(graph_features, proof_features)` using k-means / hierarchical; primary axes `cone_depth_entropy` and `pol_frac`. Visualise in proof_survey (PCA/t-SNE). Deliverable: taxonomy doc + scalability plots.

---

## M3.5 — CP constraint provenance and branching heuristic ✅

**Goal:** Map cone leaves to CP constructs; identify which Glasgow components are proof-critical per family; derive branching heuristic.

### M3.5.1–M3.5.3 — Label infrastructure ✅

- **M3.5.1** — Glasgow (branch `labels-for-analysis`) writes labels on all level-0 constraints: 37 label categories covering domain, injectivity, adjacency, elimination, search, path-graph, and bound constructs. Full label table in `paper/notes.tex §2`.
- **M3.5.2** — `classify_label` + `cone_label_stats` + `writeout_cone_labels` in `src/output.jl`. Exhaustive: every Glasgow label maps to a named counter. ~40 count columns + 9 fraction columns in CSV. Prefix ordering: longer prefixes checked first (`elimdegpol` before `elimdeg`, etc.).
- **M3.5.3** — Branching heuristic sidecar: pattern vertex occurrence counts in OPB cone → `<instance>.var_order`. CSV: `grim_cone_uniq_pat`, `grim_cone_uniq_tar`.

### M3.5 analysis — from 2026-06-22 cluster run

Per-family supplemental usage now quantified (see M3 cluster run table). Key findings:
- g1adj bimodal: 77% zero, 23% with counts sometimes exceeding g0adj. Per-family stratification required.
- images-CVIU11: 100% supplemental usage, massive counts (median 38k g1adj). meshes-CVIU11: near-zero.
- bio: 55% g1adj usage overall, jumps to 100% in search-heavy instances.
- Families with near-zero gNadj → depth-N supplementals can be disabled — direct `--supplementals` tuning knob for M4.

### M3.5.4 — Structural classifier for supplemental graph usage 🔜 CURRENT

**Goal:** Identify which graph structural properties predict whether g1adj/g2adj/g3adj appear in the UNSAT cone. Feed result into M4 as a fast pre-solve probe.

**Inputs:** `6-22-fullrun/graph_features.csv` (33 structural features + 30 core features) joined with `6-22-fullrun/cluster_results.csv` (g1adj/g2adj/g3adj counts). 15,394 instances in innerjoin.

**Steps:**

1. **Per-family stratification** — for each family (LV, bio, images, meshes, phase, scalefree), compute: fraction of instances with g1adj > 0, median g1adj count, median g1adj/g0adj ratio. *(Partially done in classify_supplementals — extend with g0adj ratios.)*

2. **Feature correlation** — point-biserial correlation of each `graph_features` column against `g1adj_used` (binary). Primary candidates: `pat_triangles`, `pat_clustering`, `density_ratio`, `node_ratio`, `pat_deg_var`, `diameter_ratio`.

3. **Simple classifier** — decision tree (depth ≤ 3) or explicit threshold rules on top 2–3 features. Interpretability required; no black-box models. Target: per-family precision ≥ 0.80.

4. **proof_survey section** — per-family g1adj usage rate stacked bar + top structural predictors table + classifier confusion matrix.

5. **M4 implication** — families where classifier predicts g1adj ≈ 0 → propose `--supplementals=0` as default; document expected speedup.

**Deliverable:** classifier rules in `paper/notes.tex §8` + new proof_survey section.

### M3.5.5 — Branching order variance analysis ✅

**Finding:** Within-family Kendall tau is **low across all four families** — no canonical per-family ordering exists. Per-instance branching matters. M3.5.6 promoted to high-priority.

| Family | Instances | Mean tau | Std tau | Min tau | Max tau |
|---|---|---|---|---|---|
| LV | 3,771 | 0.104 | 0.229 | -1.000 | 0.964 |
| bio | 7,637 | 0.096 | 0.250 | -0.500 | 1.000 |
| images-CVIU11 | 804 | 0.075 | 0.213 | -0.463 | 0.961 |
| meshes-CVIU11 | 2,102 | 0.086 | 0.270 | -0.667 | 1.000 |

All mean tau values are well below the 0.4 threshold (range 0.075–0.104). The high standard deviation and wide min/max range show that some instance pairs agree strongly while others are near-anticorrelated — ordering is instance-specific, not family-specific.

**Infrastructure:** `scripts/aggregate_var_order.jl` integrated into `harvest.sh` (step 3/5) and `harvest_pull.sh`. Outputs: `var_order_stats.csv` (14,314 rows, per-instance entropy/Gini/top-k) + `var_order_family_summary.csv`.

### M3.5.6 — Glasgow per-instance branching integration ✅

**Goal:** Measure whether cone-derived branching order can improve Glasgow's search.

**What was tested:** Glasgow's `find_branch_domain` normally uses **dynamic smallest-domain-first** — at each search node, pick the unfixed pattern vertex with the fewest remaining target candidates (tiebreak by pattern degree). The oracle replaces this with a **static fixed ordering** from `.var_order` (cone vertex frequency), ignoring domain sizes entirely.

Glasgow modified (`labels-for-analysis` branch `a87b8ab`): `--pattern-order-file` flag. `scripts/oracle_replay.jl` runs baseline vs oracle on all 7,430 base instances with `.var_order` files (92 threads, 180s timeout).

**Results — oracle ceiling is modest and family-dependent:**

| Family | Search instances | Geomean node ratio | Oracle better | Oracle worse |
|---|---|---|---|---|
| LV | 203 | **0.93** | 29% | 19% |
| bio | 2,206 | **0.85** | 38% | 25% |
| images-CVIU11 | 489 | **1.41** | 24% | 59% |
| meshes-CVIU11 | 0 | — | — | — |

4,531 instances (61%) have 0 search nodes (solved by preprocessing alone — branching irrelevant). Meshes: 100% preprocessing. Bio has 96 instances with 10x+ oracle speedup but also 63 with 10x+ slowdown.

**Why the oracle hurts on images:** deep propagation cascades cause domain sizes to shift dramatically during search. The adaptive smallest-domain-first heuristic tracks this; a static ordering cannot. The oracle forces branching on proof-critical vertices even when their domains are large, expanding the search tree.

**Conclusion:** A static ordering override is the wrong integration point. The cone data has signal (bio geomean 0.85) but a fixed ordering fights Glasgow's adaptive heuristic. Two paths remain:
1. **Tiebreaker integration** — use cone-derived priority only to break ties in smallest-domain-first (same domain size → prefer proof-critical vertex). Small change, preserves fail-first, may capture the bio/LV upside without the images downside.
2. **Preprocessing flags (M4)** — higher leverage: 61% of instances are decided by preprocessing alone. Tuning `--staged`, `--no-supplementals`, NDS per family likely outweighs any branching improvement.

**Decision: Phase 2/3 cancelled.** Cross-instance transfer and feature-predicted ordering would perform worse than this oracle ceiling, which is already marginal. Tiebreaker integration is a low-cost experiment for M4. Focus shifts to M4 preprocessing heuristics.

### M3.5.7 — Trimmed vs full proof comparison ✅

**Goal:** Compute the same statistics on the full (untrimmed) proof as on the trimmed cone. Test whether trimming biases our understanding of which Glasgow components are proof-critical. The cone shows what is *logically necessary* for the UNSAT certificate — but it also potentially shows what the solver *could have used directly*. Comparing cone vs full proof statistics lets us quantify this.

**Hypothesis:** If cone label/vertex distributions are a proportional subsample of the full proof, trimming introduces no bias and our M3.5 conclusions hold as-is. If they diverge (e.g., supplementals are heavily used during search but rare in the cone), the full-proof view is more relevant for heuristic guidance (M4).

**Findings (from `cone_vs_full.html`, 2026-06-25, confirmed and extended by 6-29-fullrun):** Hypothesis REJECTED — trimming is massively non-proportional.

Compression rates (cone/full, all UNSAT instances with full data) — 6-29-fullrun:

| Family | n | mean | median |
|---|---|---|---|
| LV | 5,793 | 15.3% | 9.7% |
| bio | 9,736 | 24.2% | 23.0% |
| images-CVIU11 | 2,857 | 9.6% | 7.4% |
| meshes-CVIU11 | 4,546 | 21.3% | 18.3% |
| scalefree | 32 | 33.3% | 33.3% |

Label survival rates (mean cone count / mean full count) — 6-29-fullrun:

| Label | LV | bio | images-CVIU11 |
|---|---|---|---|
| g0adj | 18.2% | 30.2% | 23.7% |
| g1adj | **0.6%** | **1.4%** | **1.5%** |
| g2adj | **1.8%** | **1.2%** | **0.2%** |
| g3adj | **0.9%** | **0.9%** | — |
| pathg1 | **0.5%** | **1.2%** | **1.5%** |
| pathg2 | 4.5% | 2.0% | 7.2% |
| pathg3 | 3.4% | 4.7% | — |

Full proof volume (share of total OPB proof steps, as shown in `cone_vs_full.html` stacked barplots) — images-CVIU11: gNadj+pathN = **50%** of all OPB steps (pathg1 = 32%, pathg2 = 9%, g1adj = 8%), at <2% survival. Bio: **13%** (pathg2 = 5.6%, pathg1 = 4.7%). LV: **3.2%**. Meshes: **0%**. Images is the dominant case where dead-wood volume is structurally significant.

**Dead wood** (generated during search, nearly absent from UNSAT certificate):
- `pathg1`, `pathg2`, `pathg3` — path-consistency propagation scaffolding; pathg1+pathg2 alone account for 65% of bio proof steps and 66% of images steps
- `g1adj`, `g2adj`, `g3adj` — supplemental edges almost entirely evicted (<2% survival everywhere)
- `elimdeg` — degree-elimination steps nearly completely pruned

**Proof-critical** (survive trimming far above the average compression rate):
- `inj`: 20% (LV overall), 62% (LV search), 88% (bio), 73% (images)
- `loop`: ~80% (LV) — loop-consistency steps tightly coupled to the UNSAT certificate
- `guess`: ~58% (LV search) — branching decisions that lead to contradiction remain needed

**Dominant in both** but still compressed:
- `g0adj`: 18–30% survival — base adjacency is the bulk of both proof and cone, but ~75–80% is trimmed away

**Key conclusion for M4:** Full-proof label fractions measure *search load* (what the solver did). Cone label fractions measure *certificate structure* (what was logically required). Features for heuristic learning should use cone labels. The ratio `cone/full` per label is itself a new candidate feature for M4. The extreme dead-wood volume of gNadj/pathN motivates M4.1.

**Implementation note:** The planned `.out` fraction format was superseded by separate `grim_full_<label>` columns in the CSV (256 columns total, positions 176–226 for per-label full counts). The cluster re-run (2026-06-22) already produced these columns. The `.full.var_order` files were not written — oracle replay comparison (cone-order vs full-proof-order) remains possible as a future M4 sub-experiment but is not required for M4 main track.

**Output format refactor — fraction `cone/total`:**

For count-based stats, the `.out` file switches from separate lines to a single fraction line:
```
# Before (current):                  # After (M3.5.7):
grim OPB NBEQ 999                    grim OPB 55/999
grim OPB CONE 55                     grim PBP 12/500
grim PBP NBEQ 500                    grim NBEQ 67/1499
grim PBP CONE 12                     grim RUP 8/400
grim CONE RUP 8                      grim POL 3/80
grim CONE LABEL G0ADJ 40             grim LABEL G0ADJ 40/800
```

Applies to: equation counts (OPB/PBP/NBEQ), step types (RUP/POL/IA/RED), literal/variable counts, all 37 label categories.

For distributional stats (depth, entropy, CV, antecedent profiles), there is no natural cone/total ratio — these are independent measurements on different DAGs. These get parallel `full` prefix lines:
```
grim CONE DEPTH MAX 93
grim FULL DEPTH MAX 150
grim CONE DEPTH ENTROPY 2.18
grim FULL DEPTH ENTROPY 3.4
```

**New `.full.var_order` file:**

Alongside the existing `.var_order` (cone vertex frequencies), write `.full.var_order` (vertex frequencies from ALL OPB equations, not just cone). Enables direct oracle replay comparison: cone-ordering vs full-proof-ordering as heuristic signal.

**Implementation plan:**

| Step | File(s) | Change |
|------|---------|--------|
| 1. Full-proof stat functions | `src/output.jl` | `count_step_types_full(systemlink)` — all PBP steps, no cone filter. `full_label_stats(ctrmap, ctrmap_evicted, nbopb, n_total)` — all labels, no cone filter. `full_var_order(varmap_inv, sys, nbopb)` — vertex freq from ALL OPB equations. |
| 2. Full-proof depth | `src/output.jl` | `compute_full_depth(systemlink, nbopb)` + `compute_full_depth_dist(...)` — depth over entire proof DAG (including dead-end branches). |
| 3. Writeout refactor | `src/output.jl` | Merge `writeout_parse`/`writeout_trim` into fraction format. `writeout_step_types` takes (cone_counts, full_counts). `writeout_cone_labels` takes (cone_labels, full_labels). New `writeout_full_depth`. |
| 4. Pipeline integration | `src/pipeline.jl` | Compute full-proof stats before `getcone!` (step types, labels, var_order need only `systemlink`/`ctrmap`, not `cone`). Pass both to writeout functions. Write `.full.var_order`. |
| 5. Aggregate refactor | `scripts/aggregate_results.jl` | Parse `N/M` fraction → dual CSV columns `*_cone` / `*_full`. Add `full_*` columns for depth/distribution stats. Compute `cone_full_ratio` derived columns. |
| 6. Downstream scripts | `scripts/classify_supplementals.jl`, `scripts/proof_survey.jl`, `scripts/quick_stats.jl` | Update to new CSV column names. Add cone-vs-full comparison sections in reports. |
| 7. `plotresultstable` update | `src/output.jl` | Parse new fraction format in the inline stats display. |

**Key design decisions:**
- Full-proof depth includes dead-end branches — measures what the solver actually explored, not just the minimal certificate. Full depth ≥ cone depth always.
- Label "utilization rate" = cone_count / full_count per category. Low utilization → the solver generates many constraints of this type but few end up needed.
- The `.full.var_order` enables a direct re-run of M3.5.6 oracle replay to compare cone-derived vs full-proof-derived branching heuristics.

**Deliverable:** Updated `.out` format, dual-view CSV columns, `.full.var_order` files. Cluster re-run needed (new `.out` format is a breaking change — old `.out` files become unparseable by the new aggregate script).

---

## M4 — Multi-axis heuristic learning

**Goal:** Learn which Glasgow configuration performs best for each cluster.

**Heuristic dimensions:** variable ordering (most-constrained / degree-based / BFS-topology), preprocessing aggressiveness (degree filter, triangle propagation, supplemental graph depth).

**Family-specific predictions from M3:**

| Family class | Predicted best | Predicted ineffective |
|---|---|---|
| Mesh-like | Preprocessing + triangle propagation | Variable ordering |
| LV-like | Degree pre-check + neighbourhood propagator | Fine-grained ordering |
| Image-like | Most-constrained variable ordering | Triangle propagation |
| Bio-like | BFS ordering from bottleneck vertex | Degree pre-check |

**Depends on:** M3.5 cluster data (supplemental depth profiles inform which `--supplementals` flags to test). Framework: `scripts/heuristic_eval.jl` — runs flag combinations on benchmark subset, outputs per-instance × per-config performance matrix. Learning: manual rules first, then decision-tree model.

---

### M4.1 — Lazy/demand-driven supplemental and path constraint generation 🔜

**Motivation:** The 6-29-fullrun cone_vs_full data shows that gNadj and pathgN constraints are near-pure dead wood: survival rates of 0.5–5%, yet for images-CVIU11 they represent **50% of all OPB proof steps** (pathg1 alone = 32%), and 13% for bio. Full findings and the abandoned/adopted implementation history are in `docs/lazy-supplementals-plan.md`.

**Own per-vertex prototype (Variantes 1–2, abandoned, 2026-06-29).** Implemented `--lazy-supplementals` directly on `labels-for-analysis` (per-pattern/target-vertex builders, `ensure_pattern_supplementals`/`ensure_target_supplementals`, no proof support). Benchmarked 4 iterations (`benchmark_results/lazy_v1-v4_2026-06-29.csv`) fixing successive bugs (target-side non-laziness, silently-disabled NDS). Result: never beat `--staged` net. `--staged` already dominates `default` everywhere (PAR-2 0.0–0.1 vs 0.1–0.6, see Étape 3 in the plan doc); the per-vertex prototype matched or slightly beat `--staged` only on images/meshes/scalefree (where staged is already near-optimal), while being 3–75× worse in search nodes on LV/bio (v4: LV 8876 vs 117 nodes, bio 6533 vs 1974) because g≥1 NDS was never implemented (architectural cost concern, `docs/lazy-supplementals-plan.md` §5) and no proof logging was supported at all — unusable for this project's pipeline regardless of speed. **Abandoned**, no further v5.

**Upstream adoption (2026-07-23).** Ciaran McCreesh has his own proof-compatible lazy-adjacency implementation upstream (`origin/proofs/lazy-adjacency`, `origin/proofs/lazy-adjacency-staged` on `ciaranm/glasgow-subgraph-solver`, not yet merged to his `master`): supplemental adjacency derivations are registered as pending closures and materialised only when the antecedent `(p,t)` is actually decided during search (assignment or forward-check removal) — always on when proof logging is active, no CLI flag. Defers ~40–70% of derivations per `dev_docs/proof-logging.md` on that branch. This supersedes our own prototype entirely (proof support + no g≥1 NDS gap, since degree/NDS filtering isn't touched by this mechanism).

**Compatibility fix required and done:** `proofs/lazy-adjacency-staged` bundled an unrelated de-labelling pass — ~25 `proof.cc` derivation sites lost their `@label` prefix (`elimdeg`, `elimnds`, `loop`, `hall`, `guess`, `nogood`, `binback`, `colpol`, `hombd`, `homfin`, `homcross`, `mcspart`, `notconn`, `cliqedge`, `forb`, `ptbig`, `unsatconc`, …), and per-slot `@g1adj`/`@g2adj`/`@g3adj` collapsed into a single `@d3adj` with `pathg`/`d2g`/`d3g` intermediate labels dropped — breaking the M3.5.2 cone-label taxonomy (`classify_label` in `src/output.jl`) that all prior harvested data depends on. Rebased our two `labels-for-analysis`-only commits (`--pattern-order-file`, RUP→POL loop-cancellation fix) on top and restored every label exactly, keeping the lazy machinery untouched (pure relabelling, no derivation changes). Pushed as `lazy-adjacency-relabelled` on `ciaranm/glasgow-subgraph-solver` (not merged anywhere yet).

**Verified (LVg10g12, 2026-07-23):** builds clean; VeriPB accepts the proof (`s VERIFIED UNSATISFIABLE`); 100% of non-comment/non-directive `.pbp` lines (81,201/81,201) carry an `@label`, full expected prefix set present (`@adj`, `@pathg`, `@g<N>adj`, `@elimdeg(pol)`, `@elimnds(pol/conc)`, `@hall`, `@unsatconc`), zero `@d3adj`.

**Branch topology (established 2026-07-27) — the two branches are SIBLINGS, not parent/child.** They diverge at merge-base `6a5d7a4` ("Phase 3 Option 2, step 2d: migrate the extra-shape derivation to the middle"):

| Only on `lazy-adjacency-relabelled` | Only on `labels-for-analysis` |
|---|---|
| `39ca857` restore @label prefixes | `2180663` replace RUP with POL |
| `dbe34dc` replace RUP with POL | `a87b8ab` add `--pattern-order-file` |
| `069ba7f` add `--pattern-order-file` | `739caca` Merge `pipeline/refactor` |
| `7ade5b3` Emit supplemental adjacency lazily | `d987ee8` M3.5.3 · `75984b5` M3.5.2 · `de50e8c` M3.5 per-level GADJ · `b5439ad` M3.5 unified labels |

So `lazy-adjacency-relabelled` never contained the M3.5/M3.5.2/M3.5.3 label commits — `39ca857` re-derived equivalent labelling independently — and it carries `dbe34dc`, a separate commit sharing a title with `2180663`. **Consequence:** the candidate differs from the reference by four solver commits plus a refactor merge, not just by lazy adjacency. A PAR-2 delta measured against the 6-29 data would be confounded (the cluster was also wiped and reimaged in between), so M4.1 step 1 must run **both arms on the same machine on the same day** — roughly double the wall time.

**Label taxonomy verified equivalent (2026-07-27).** Extracting every `@…` literal from both branches' `gss/` trees gives identical sets: all 40 prefixes on `labels-for-analysis` are present on `lazy-adjacency-relabelled` (plus `@label`). Where a trimmed proof reports `G1ADJ 0/0` and no `PATHG` line, the solver genuinely emitted none for that instance (confirmed on LVg10g12's raw `.pbp`); other instances are dense with them (LVg12g20: `@pathg` 210124, `@g1adj` 6272, `@g2adj` 13440, `@g3adj` 4672). This closes the "did relabelling lose categories?" question — it did not.

**Not yet done:**
- `labels-for-analysis` (the branch all prior harvested data — 6-22/6-29-fullrun, cluster_results.csv — was generated with) is untouched on purpose, to keep that data reproducible. `lazy-adjacency-relabelled` is a candidate, not yet the reference.
- No PAR-2 benchmark yet of `lazy-adjacency-relabelled` vs `labels-for-analysis`/`--staged` on the full suite — only single-instance correctness checked so far. **Explicitly deferred 2026-07-27:** the 07-27 run is single-arm on `lazy-adjacency-relabelled` for characterisation stats; a proper timing comparison is a separate later exercise.
- Not reviewed by Ciaran; branch is pushed but no PR opened.
- Cone-label CSV stats not yet re-verified at cluster scale (only LVg10g12 spot-checked) — need a small multi-instance run to confirm `classify_label` counts match `labels-for-analysis` byte-for-byte on non-lazy-affected labels.

**Steps:**

1. **Benchmark** `lazy-adjacency-relabelled` vs `labels-for-analysis` (no lazy) vs `--staged` on the 6-29-fullrun instance list. Primary metric: PAR-2. Secondary: proof size (expect the 40–70% derivation deferral to show up directly).
2. **Cross-check cone-label CSV** on a handful of instances per family: `lazy-adjacency-relabelled` output through the full trimnalyser pipeline should produce identical `grim_cone_*` counts to `labels-for-analysis` (labels are unchanged; only which derivations get skipped when never touched by search should differ, and skipped ones were dead wood anyway).
3. **Decision** — if PAR-2 improves net and cone-label stats check out, fast-forward/replace `labels-for-analysis` with this branch (or an equivalent rebase) as the new pipeline reference, and flag the branch to Ciaran (PR or direct message) so the label fix can land upstream too.

**Deliverable:** PAR-2 benchmark table + cone-label cross-check + adoption decision for the reference Glasgow branch.

---

### M4.2 — Solver-side supplemental optimisations ✅ (implemented 2026-08-05; cluster A/B pending)

Two independent Glasgow patches identified 2026-08-04 while analysing why `lazy-adjacency-relabelled`
OOMs on dense targets (see the M4.1 A/B: 169 truncated vs 0 on `labels-for-analysis`). Both are
local, neither changes the proof format, and **M4.2b is the one that unblocks M4.1**.

Reference facts, recomputed from `gss/innards/supplemental_graphs.cc` and verified on `LV/g77`
(`n=610`, 82 562 edges, density 0.44, **bipartite 360/250**):

- `exact_path_p` = edge (v,w) iff `|N(v) ∩ N(w)| ≥ p`, self-loop on v iff `deg(v) ≥ p`. Our runs
  build `exact_path_1..4` and nothing else (`--n-exact-path-graphs` default 4; `distance2`/`distance3`/`k4`
  are never enabled by `runsipsolver`).
- On g77 the four are **byte-identical**: `exact_path_1 = … = exact_path_4 = K360 ⊎ K250`, i.e. the
  "same part" equivalence relation. The minimum common-neighbourhood over same-part pairs is **67**,
  so they would only start to differ at `--n-exact-path-graphs 68`.

#### M4.2a — Detect identical supplemental graphs and skip the redundant propagators

**Claim.** If `T_g == T_{g-1}` (target side only), slot `g` is entirely redundant: `P_g ⊆ P_{g-1}` holds
by construction (≥g implies ≥g-1), so every constraint, degree check and NDS check of slot `g` is
dominated by slot `g-1`.

**What is wasted today.** No data-driven guard exists — the `supports_*` guards
(`homomorphism_traits.cc`) are static, on `params` only. Three hot loops pay 4× on g77:

| Site | Cost |
|---|---|
| `homomorphism_searcher.cc:448` | `d.values &= target_graph_row(g,t)` — 3 no-op bitset ANDs per unassigned vertex per assignment |
| `homomorphism_model.cc:344` | `deg_g(p) ≤ deg_g(t)` re-checked per slot |
| `homomorphism_model.cc:460–596` | `patterns_ndss`/`targets_ndss` — 4 identical neighbourhood-degree sequences computed and sorted |

**Implementation.** After the plan loop in `build_supplemental_graphs` (`homomorphism_model.cc:821`),
compare target rows slot-by-slot and record an `_active_graphs` list; the three loops iterate it
instead of `1..max_graphs`. `max_graphs` is the bitset stride and stays fixed, so the defensive
invariant at `:825` is untouched. `SVOBitset` has no `operator==` — needs a word-compare helper.

**Cost in the general (non-degenerate) case: negligible, and asymmetric in the right direction.**
It is an early-exit memcmp: when the graphs differ it stops at the first differing word. Full cost when
they match is `n·⌈n/64⌉` words per slot pair — ~1 ms on the largest target in the suite (images-PR15,
4838 nodes) — against an `O(n·d²)` build that just ran (45 M ops on g77). Three orders of magnitude below
what it guards.

**Expected win.** Search-time only, ~4× on the supplemental filtering for the bipartite dense targets
(g77, g84). **Not** an OOM fix: on g77 supplemental *emission* is 191 s of the 202 s runtime and the
search is 102 nodes. The win shows up on long searches and on runs without proof logging.

#### M4.2b — Stop the lazy pending closures from copying per-target data (the real 60 GB)

**Root cause, `homomorphism_proofs.cc:319–322`.** The pending closure captures **by value**:

```cpp
register_supplemental({slot,p,q,t}, p, t,
    [this, slot, p, q, t, between_p_and_q, n_t, two_away_from_t, d_n_t]() { … });
```

`n_t`, `d_n_t` and `two_away_from_t` depend only on `(t, slot)` — **not** on `(p,q)` — yet they are
rebuilt and copied inside the `for p / for q / for t` nest. On g77, `two_away_from_t` alone is
~359 pairs `(w, N(t)∩N(w))` with `|N(t)∩N(w)| ≈ 200`, i.e. **~290 KB retained per closure**. For
`LVg8g77` (pattern 30 nodes): ≤ 870 ordered pairs × 610 targets ≈ 5·10⁵ closures ≈ **150 GB** of
intended retention; the process is killed at 60 GB, ~40 % in — matching the measured "crosses 50 GB
at t≈166 s, before model build finishes". The `.pbp` line for the same constraint is ~5 KB, so the
290 KB / 5 KB ratio *is* the measured ~21× eager-disk-to-lazy-RAM exchange rate. Eager builds the
same vectors and discards them each iteration — hence flat 1 GB RSS at +3.3 MB/s.

**Fix.** The closure only needs `(slot, p, q, t)`. `ProcessedGraphsData` is alive for the whole search,
so recompute `n_t`/`d_n_t`/`two_away_from_t` at materialisation time (rare, `O(deg)` each), or share one
struct per `(t, slot)` via `shared_ptr` (610 structs instead of 5·10⁵ copies). ~290 KB → ~32 bytes per
entry. Bonus: also removes the `O(pattern²)` rebuild of those vectors during model build. **No proof
output changes** — same derivations, same order.

**Superseded hypothesis.** The earlier lead "lazy registers one closure per exact-path graph, so
`ep_distinct = 1` means a free 4×" is **closed, negative**: `register_supplemental` is keyed on
`(slot,p,q,t)` and dedups, and subsumption elision (`prove_supplemental_subsumption`, default true,
`homomorphism.hh:113`) reduces `emit_for` to the single highest slot *before* registration. Proof size
has no 4× left either — on top of the elision, `emit_exact_path_graph` consults a text-keyed dedup cache
(`homomorphism_proofs.cc:118–127`, `proof.cc:710–721`) that collapses identical slots across `g`.

#### Both implemented 2026-08-05 — local validation done, cluster A/B outstanding

Two commits on `lazy-adjacency-relabelled` (local, not pushed — `origin` is `ciaranm/…`):

| | commit | files |
|---|---|---|
| M4.2b | `68b1c9b` stop the lazy pending closures copying their per-target data | `homomorphism_proofs.{cc,hh}` |
| M4.2a | `f75a30e` skip supplemental graph slots an earlier slot already subsumes, + `a1c412b` read them from a flat array in the hot loop | `homomorphism_model.{cc,hh}`, `homomorphism_searcher.cc`, `svo_bitset.hh` |

**M4.2b as built.** Closure keeps `(slot,p,q,t)` + a `shared_ptr` to `between_p_and_q`; the per-target
vectors are rebuilt at materialisation time from the `ProcessedGraphsData`, with a **single-entry memo on
`t`** — one materialisation batch is one `(p,t)` antecedent, so the memo hits for the whole batch while
retaining one target's data. One subtlety the plan did not anticipate: `build_supplemental_graphs` strips
the `g=0` self-loops for the duration of the build and restores them afterwards, so the rebuild has to
re-strip them (`loop_stripped_target_row`) or it would not reproduce what the eager path saw.

**M4.2a as built.** `active_graphs` on the model (all slots until `build_supplemental_graphs` narrows it),
iterated by the searcher's `g`-loop and by the three degree/NDS loops. Guarded to exact-path runs, where
the nesting `P_g ⊆ P_{g-1}` holds by construction; under `degree_and_nds_are_exact` (induced isomorphism)
the pattern sides must match too, since an equality test can fail on the smaller side while passing on the
larger. `SVOBitset` gained `operator==`, comparing `n_words` words (not the whole short buffer the `&=`
loops run over, whose padding a default-constructed bitset never initialises).

**Local validation (WSL, 4 GB `ulimit -v`, LV g77 = the smallest instances on that target).**

- Proof identity: `LVg10g12` `.opb`/`.pbp` byte-identical to the pre-patch binary, both `--staged` (as
  `runsipsolver` invokes it) and unstaged. The unstaged run is the one that matters — staged concludes in
  Stage 1 on this instance and never builds a supplemental, while unstaged emits 6088 `pathg` lines.
- `LVg3g77` byte-identical between the M4.2b-only and M4.2a+b binaries, at identical `nodes = 715` and
  `propagations = 180382` — the skipped slots really were dead code.
- Full `ctest` suite: 42/42, including the VeriPB-checked `proof_supplementals` / `proof_distance3` /
  `proof_nds` / `proof_random_sweep`. (These need `VERIPB_EXECUTABLE=~/veripb-dev/target/release/veripb`;
  the `veripb` 2.2.2 on `PATH` fails every proof test on this branch's 3.0 syntax.)
- `./trimnalyser LVg10g12 overwrite resolv nosys` reproduces 890 KB / 188 KB / 80 KB / 12 KB and fixpoint
  after 0 iterations.

**M4.2b measured, LV instances on target g77, 4 GB cap, before → after:**

| instance | before | after |
|---|---|---|
| LVg3g77 | died at 4.19 GB after 32 s | UNSAT, **218 MB** peak, 31 s |
| LVg4g77 | died at 4.19 GB | UNSAT, 320 MB, 19 s |
| LVg5g77 | died at 4.18 GB | UNSAT, 183 MB, 12 s |
| LVg6g77 | died at 4.16 GB | UNSAT, 486 MB, 64 s |
| LVg8g77 | died at 4.12 GB | UNSAT, 573 MB, 44 s |

Every one of these was a truncated-proof instance; all five now conclude. `LVg10g12` unstaged also drops
48 MB → 13 MB and 0.43 s → 0.13 s, from the removed `O(pattern²)` rebuild at registration.

**M4.2a measured — the win is real, ~+20 %, and it needed a long search to see.** First attempt failed to
find one: the *natural* g77 instances search 102–715 nodes and their runtime is dominated by building the
supplementals (which M4.2a does not skip) and writing the proof, so no-proof runs gave 0.90 s → 0.85 s,
inside noise. Sweeping all LV patterns against the dense targets with `--timeout 15` found the searches
that are long enough. Where the slots collapse:

| target | collapses | instance |
|---|---|---|
| g77, g84 | `exact_path_2/3/4` (3 of 4) | LVg12g84, LVg38g84, LVg67g77 |
| g93 | `exact_path_4` only (1 of 4) | LVg8g93, LVg24g93 |
| g76, g64, g12 | none — **controls** | LVg67g76, LVg24g64 |

Throughput A/B, no proof logging, 5 interleaved reps per arm, nodes reached in a 20 s budget (a sound
metric because both binaries walk the identical deterministic tree — verified: same `nodes` and
`propagations` when they run to completion):

| instance | subsumed | metric | baseline | M4.2a | Δ | ranges disjoint |
|---|---|---|---:|---:|---:|---|
| LVg38g84 | 3 | nodes@20 s | 111 743 | 134 390 | **+20.3 %** | yes |
| LVg12g84 | 3 | nodes@20 s | 557 222 | 666 218 | **+19.6 %** | yes |
| LVg67g77 | 3 | nodes@20 s | 2 637 | 2 813 | **+6.7 %** | yes |
| LVg24g93 | 1 | nodes@20 s | 63 742 | 64 986 | +2.0 % | no |
| LVg8g93 | 1 | nodes@20 s | 571 594 | 571 198 | −0.1 % | no |
| LVg67g76 | none (ctrl) | nodes@20 s | 8 946 | 9 340 | +4.4 % | no (14 % own spread) |
| LVg24g64 | none (ctrl) | wall ms | 1 559 | 1 527 | +2.1 % | no |

**The gain tracks the number of collapsed slots and vanishes on the controls** — that dose–response, not
the raw percentage, is what rules out noise and binary-layout luck. One collapsed slot buys nothing,
because it is `exact_path_4`, the sparsest on the *pattern* side: few pattern pairs have that bit set, so
there is almost nothing to skip. This also bounds the original "4×" claim correctly — 4× applies to the
supplemental filtering alone, which is ~20 % of total search work here, not to the search.

**A regression found and fixed on the way (commit `a1c412b`).** The first version had the searcher iterate
`model.active_graphs()` — an out-of-line call plus two dependent loads (`unique_ptr<Imp>`, then the
vector's heap buffer) per `propagate_adjacency_constraints`. On LVg24g64, which subsumes nothing and runs
65k nodes/s, that cost **5.9 %** (1523 → 1613 ms, 4 of 5 runs slower than every baseline run). That is the
dangerous case: 92 of 115 LV targets subsume nothing, so it would have been a silent global slowdown for a
win on five targets. Reading a flat `std::array` member on the model instead removed the regression *and*
roughly doubled the win (g84 +11.9 % → +19.6 %). **Lesson: this benchmark needs its zero-subsumption
controls; the win cases alone would have shipped the regression.**

**Still to do:**

1. Cluster: re-run the `scripts/ab_dense_targets.sh` arms on the 405 dense-target instances; success =
   truncated count back to ~0 while keeping lazy's 1.7 GB → 0.5 GB median proof gain.
2. ~~Cluster: measure search-node throughput for M4.2a~~ — done locally, +20 % on g84 (see above). Cluster would only add breadth.
3. If both land, re-open the M4.1 adoption decision: lazy would then be strictly better than eager.
4. Decide whether to push to `ciaranm/glasgow-subgraph-solver` or keep the two commits local.

**Longer-term, not scheduled.** The degenerate case says `N_g(t)` takes only *two* distinct values over
all 610 targets — an equivalence relation. An extension variable `y[q,P] ≡ ⋁_{u∈P} x[q,u]` (VeriPB `red`)
would turn each width-360 adjacency constraint into width 2 (~2.85 GB → ~100 MB on g77). That is the
clean form of the "complement encoding" idea, and detecting a disjoint-union-of-cliques supplemental is
exactly its trigger. Changes the proof format, so it is the invasive one.

**Deliverable:** two Glasgow patches on `lazy-adjacency-relabelled`, dense-target A/B showing the
truncated count collapse, and a proof-identity check on LVg10g12.

---

## Paper scope decision (2026-07-23)

**Decision:** scope the paper as a characterisation-only contribution — cone-vs-full label composition (M3.5.7) + per-family resolv/pattern-shrinkage statistics (already in `paper/notes.tex` §Proof Fingerprints) — with M4/M4.1 heuristic work explicitly left as future work, not a required result.

**Why not an "improvements" paper right now:**
- No positive M4.1 result exists yet: our own per-vertex lazy prototype never beat `--staged`; Ciaran's adopted mechanism (`lazy-adjacency-relabelled`) hasn't been PAR-2-benchmarked.
- M3.5.6 (oracle replay, done) already showed the cone signal doesn't trivially translate into a branching win — geomean node ratios 0.93 (LV) / 0.85 (bio) / **1.41 (images, worse)** — so "actionable" claims need to be earned, not assumed.
- The resolv loop is currently a descriptive per-family statistic (pattern shrinkage %), not an evaluated MUS-extraction technique — no minimality bound, no baseline comparison. Fine as a supporting result, not a standalone technique claim.
- Cone size itself is heuristic-derived (Grim backward reachability), not proven minimal — "X% dead wood" claims are stated relative to Grim's cone, not a formal optimum.

**Immediate next step:** full run launched 2026-07-27 (cluster-side, `lazy-adjacency-relabelled`, single-arm) to confirm/refresh the cone-vs-full and resolv numbers before write-up. Harvest with `bash scripts/harvest.sh` on the compute node, then `bash scripts/harvest_pull.sh` locally.

**Contingency:** if characterisation alone is judged too thin post-rerun, next lever is **M5 (cross-solver)** — comparing against RI/VF2/McSplit to add a second axis of results, rather than waiting on M4/M4.1 to land. As of 2026-08-12 there is a second option in that slot: **LAD, which produces proofs**, so it can test whether the per-family proof fingerprints are instance properties or Glasgow artefacts — a better fit for a proof-characterisation paper than another PAR-2 column. It needs a pilot first; see "M5-proof" for the capability limits.

---

## M5 — Cross-solver comparison

Glasgow (default vs heuristic-selected) vs RI vs VF2/McSplit. Fixed 180s timeout; PAR-2 score; stratified by family and cluster. Key question: do heuristics learned on LV transfer to phase/scalefree/si?

### M5-proof — LAD as a second proof-producing arm (available 2026-08-12, pilot-only)

RI/VF2/McSplit produce no proofs, so they can only be compared on solve time. **LAD now emits VeriPB proofs**, which makes a different comparison possible: every characterisation result we have (cone depth, `pol_frac`/`ia_frac` shapes, resolv shrinkage, the images-vs-meshes fingerprint) is currently **single-solver**, so we cannot tell whether "mesh shape = single-wave algebraic certificate, image shape = propagation cascade" is a property of the *instance family* or of *Glasgow's proof style*. A second proof producer separates those.

Repo: `~/ladveri` / `git@github.com:ArthurGontierPro/ladveri.git`. Read `PROOF_TODO.md` and `doc/` there first.

**What it can do today.** Every inference in its pinned configuration is discharged and checked end-to-end by CakeML: 14/14 curated cases, 588 proofs over three random seeds, zero broken proofs, zero unchecked assertions. Proofs are pure `rup`/`pol`.

**What it cannot do — read before planning any run:**

- **Never run on a real benchmark instance.** All validation is small random graphs (patterns ≤ 9 vertices). No proof-size numbers, no verification-time numbers, no evidence of where it falls over. A newSIP pilot is exactly the missing step (their TODO #11).
- **No deletions.** The proof buffer is flat and accumulating, so proofs grow unboundedly — expect this to bite at benchmark scale (their TODO #10).
- **Requires `-c 0`** (clique filtering unlogged) and **`-f 0` or `-f 1` pinned**, never `-f 2` adaptive.
- **Restarts forced off** under `-P`.
- **Clique instances silently produce no proof at all** — the shortcut fires before proof logging starts and exits. 12 of 600 sweep instances. Any harness must detect "no `.pbp` produced" and classify it, not treat it as a failure.
- **Non-induced, undirected, unlabelled only**; first-solution only (no enumeration).
- Instances must be **cake-clean**: no trailing blank line, degree counts matching successor counts exactly, edges present in both directions. Cake's LAD parser is stricter than LAD's own — note our `writecoreladfile` output has not been checked against it.

**Comparison caveat — proof size is not directly comparable.** Glasgow emits its own OPB; LAD emits no model at all, writing against the constraint labels of the verified `cake_pb_iso` encoder. Different variable and constraint sets, so raw byte counts compare encodings as much as solvers. Normalise per node or per elimination, or compare growth curves. Glasgow also uses dominance; LAD's proofs never do.

**Status 2026-08-12 — harness built, pilot pending.** LAD now runs on real newSIP instances: `LVg10g12` verifies end-to-end (dev VeriPB + trusted CakeML) in ~6 s with zero unchecked assertions. The runner is `~/ladveri/proof/bench/bench.py`; read `~/ladveri/proof/bench/README.md` before using it.

#### The two planned runs

Both emit one CSV row per (instance, solver), named exactly as we name instances, so they join onto `cluster_results.csv` on `instance`.

**Run A — `--mode nopl`, no proof logging, clique reasoning ON both sides.** Measures verdict agreement, nodes, wall-clock. Deliberately *not* a controlled ablation: "clique reasoning" is different machinery on each side (Glasgow clique *detection* = whole-pattern shortcut to a dedicated clique solver, `--cliques` = clique *size* constraints; LAD `-c > 0` = clique *count* domination plus `filterMaxClique` *size* domination). Write it up as "both solvers as you would actually run them".

**Run B — `--mode pl`, proof logging + checking, parity flags pinned.** Both solvers: clique reasoning off, restarts off, single-threaded, non-induced, first solution. Measures the above plus proof bytes and VeriPB verification time.

```sh
proof/bench/bench.py --mode nopl --families LV --out nopl.csv --jobs 32
proof/bench/bench.py --mode pl   --families LV --out pl.csv   --jobs 32
```

Resumable — re-running the same command skips rows already present, so a killed cluster run resumes cleanly.

#### Three traps in the run design

1. **`--restarts none` must be pinned on Glasgow by hand.** Glasgow's default for a decision problem is Luby restarts, and proof logging does *not* disable them (the only restart guard is for counting). LAD forces restarts off under `-P`. Miss this and Run B compares a restarting solver against a non-restarting one. Note our existing `runsipsolver` (`src/solver.jl:158`) does **not** pass it — correct for our own runs, wrong for this comparison.
2. **`bio` must be excluded from both runs.** It is genuinely directed (68 asymmetric pairs in `001.txt`). CakePB rejects it, and LAD reads it as undirected *without warning* — on `bio 001 -> 002` Glasgow says SAT and LAD says UNSAT. Including it would manufacture thousands of spurious disagreements from our own misuse. `bench.py` hard-errors on the family. This costs us the largest family in the 6-29 run (11,914 instances).
3. **Clique instances give LAD no proof at all**, and this fires on real data — `LVg2g4` produces nothing because `LV/g4` is K₁₀. Rows are marked `no-proof(clique)`; count them separately, never as failures.

#### M5-proof-trim — trimnalyse LAD proofs as we do Glasgow's

The end goal, after Run B produces proofs worth trimming: feed LAD `.pbp` files through the existing cone extraction / resolv loop and compare the proof fingerprints against Glasgow's on the *same instances*. That is the result the single-solver characterisation cannot reach — whether `pol_frac`/`ia_frac`, cone depth and resolv shrinkage are properties of the instance family or of Glasgow's proof style.

Two things to check before assuming the trimmer just works on LAD proofs:

- **LAD emits no OPB.** It writes only `.pbp`, against the constraint labels of the verified `cake_pb_iso` encoder — so the model must come from `cake_pb_iso pat tgt > enc.opb`. Our pipeline assumes the solver produced both files (`runsipsolver` checks for `.opb` *and* `.pbp`). Either generate the OPB in the harness, or implement LAD's TODO #9 (emit our own OPB), which exists precisely for this.
- **Variable naming differs.** LAD uses `x<p>_<t>`, which `parsevarname` (`src/solver.jl`) already parses — that part should carry over unchanged. Label-based provenance (M3.5.1–3) will *not*: those labels are Glasgow-specific, so cone-leaf classification needs a LAD-side equivalent or must be restricted to the structural columns.

**Suggested order:** Run A first (cheap, no proof machinery, immediately says whether the solvers agree at all), then Run B on LV only, then reassess. Do not schedule meshes or images until LV verification times are known — a single mesh instance encodes to ~21 MB of OPB before any proof is written, and LAD has no proof deletions.

---

## M6 — Integration into solvers

Lightweight graph-feature probe at Glasgow startup selects heuristic config. Submit as Glasgow PR or local patch. Map to equivalent knobs in RI/VF2.

---

## Dependency graph

```
M1 → M2 → M2.5 → M3 (taxonomy) ✅
                    └─ M3.5.1–3 (CP provenance) ✅
                          ├─ M3.5.4 (supplemental classifier) 🔜 CURRENT
                          ├─ M3.5.5 (branching order variance) ✅
                          │     └─ M3.5.6 (oracle replay) ✅ — static override marginal, tiebreaker for M4
                          └─ M3.5.7 (trimmed vs full proof) ✅ — cone_vs_full data in 6-22 + 6-29 runs
                                └─ M4.1 (lazy supplemental generation) 🔜 — Glasgow modification, feeds M4 flags
                                      ├─ M4.2a (identical-supplemental memcmp → skip propagators) ✅ — +20% node throughput on g84
                                      ├─ M4.2b (lazy closure capture-by-value → RAM fix) ✅ — 4.2G OOM → 218M on LVg3g77
                                      └─ M4 (heuristic learning, depends on M3.5.4 + M3.5.7 + M4.1)
                                            └─ M5 (cross-solver)
                                                  ├─ M5-proof (LAD arm) 🔜 — independent of M4
                                                  │     ├─ Run A (nopl: solver compare)  🔜 CURRENT
                                                  │     ├─ Run B (pl: proof + checking)  🔜
                                                  │     └─ M5-proof-trim (LAD proofs through the cone/resolv loop)
                                                  └─ M6 (integration)
```
