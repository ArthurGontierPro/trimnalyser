# TrimAnalyser — Research Roadmap

TrimAnalyser supports all 8 newSIP benchmark families, extracts UNSAT cores via the resolv loop, outputs ~160-column CSV per run, and maps proof cone leaves back to CP constructs via labelled Glasgow proofs.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-29:** M1–M2.5, M3.5.1–M3.5.3, M3.5.5, M3.5.6, M3.5.7 complete. M3.5.4 still open. Next: M3.5.4 supplemental classifier, then M4 (including M4.1 lazy supplemental generation experiment).

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

**Motivation:** The 6-29-fullrun cone_vs_full data shows that gNadj and pathgN constraints are near-pure dead wood: survival rates of 0.5–5%, yet for images-CVIU11 they represent **50% of all OPB proof steps** (pathg1 alone = 32%), and 13% for bio. These are generated en masse during preprocessing for all pattern nodes, almost entirely discarded by trimming. Glasgow currently generates all supplemental edges (g1adj/g2adj/g3adj) and all path-consistency constraints (pathg1/pathg2/pathg3) upfront during preprocessing, for every pattern node. Almost none of these are logically necessary for the UNSAT certificate.

**Proposal:** Modify Glasgow to generate supplemental and path constraints *lazily* — only when the corresponding pattern node is first touched during search (e.g., when its domain is reduced or it is selected for branching). Nodes that preprocessing eliminates without search never trigger supplemental generation.

**Expected gain:** For images-CVIU11 (pathg1 = 51.6% of proof, 1.5% survival) and bio (pathg1+pathg2 = 66% of proof, ~1–2% survival), lazy generation could reduce proof writing and propagation work by an order of magnitude for instances that reach deep search. The 61% "0 search nodes" instances would be unaffected (preprocessing still runs as-is).

**Open questions and risks:**

1. **Preprocessing power loss.** Path-consistency propagation during preprocessing is what makes many instances solvable without search. If pathgN generation is deferred, preprocessing loses filtering power, potentially converting "0-search-node" instances into full search instances. Need to measure: does preprocessing actually *use* pathgN for domain reduction, or does it generate them speculatively?

2. **Proof sequencing.** `pathg1`/`g1adj` are already PBP-derived constraints (not OPB axioms): Glasgow currently introduces them with a `pol` justification during preprocessing. Lazy generation just defers that introduction to later in the PBP sequence. VeriPB is sequential — as long as `@pathg1_X` is introduced before any step that uses it as an antecedent, the proof is valid, and lazy generation guarantees this by construction. The real constraint is architectural: Glasgow's current preprocessing is a batch pass over all nodes; making it lazy requires restructuring into on-demand callbacks triggered by the search.

3. **Volume ≠ time.** High pathg1 proof volume does not directly imply high CPU time. These constraints may be generated by a cheap linear sweep. Need Glasgow profiling (e.g., `perf` or instrumented timing per generation phase) to confirm that generation time scales with proof volume before investing in lazy generation.

4. **Definition of "touched".** "Node touched by search" needs a precise operational definition in Glasgow's internals. Candidates: (a) branching selects the node, (b) the node's domain is first reduced below a threshold, (c) a propagation step reads a constraint on the node. The choice affects both completeness and proof structure.

5. **Simpler baseline first (M3.5.4 path).** The simple version of this idea is a static `--no-supplementals` / `--no-path-consistency` flag: for families where M3.5.4 classifier predicts near-zero gNadj cone usage, disable these entirely. This requires no lazy infrastructure and should be benchmarked before implementing the lazy variant.

**Steps:**

1. **Profile Glasgow** — instrument generation time for supplemental and path phases; correlate with proof volume. Determines if lazy generation is worth implementing.
2. **Static ablation** — run Glasgow with `--supplementals=0` and without path-consistency on LV/bio/images subsets. Measure PAR-2 delta. This is the "worst case" of lazy generation (never generate) and establishes the lower bound on speedup.
3. **Lazy generation prototype** — modify Glasgow `labels-for-analysis` branch to defer gNadj/pathN generation to first domain-reduction event per node. Write proof introduction steps at deferral point.
4. **Benchmark** — compare lazy vs eager vs disabled on 6-29-fullrun instances. Primary metric: PAR-2 (solved instances × runtime). Secondary: proof size.
5. **Decision** — adopt lazy if PAR-2 improves on net across families, or if static disable suffices and avoids implementation complexity.

**Deliverable:** Benchmarked Glasgow variant (lazy or static-disable) + decision document for M4 main track flag recommendations.

---

## M5 — Cross-solver comparison

Glasgow (default vs heuristic-selected) vs RI vs VF2/McSplit. Fixed 180s timeout; PAR-2 score; stratified by family and cluster. Key question: do heuristics learned on LV transfer to phase/scalefree/si?

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
                                      └─ M4 (heuristic learning, depends on M3.5.4 + M3.5.7 + M4.1)
                                            └─ M5 (cross-solver)
                                                  └─ M6 (integration)
```
