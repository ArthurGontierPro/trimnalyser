# TrimAnalyser — Research Roadmap

TrimAnalyser supports all 8 newSIP benchmark families, extracts UNSAT cores via the resolv loop, outputs ~160-column CSV per run, and maps proof cone leaves back to CP constructs via labelled Glasgow proofs.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-23:** M1–M2.5, M3.5.1–M3.5.3 complete. M3 first-pass analysis and full cluster run (15,431 instances, 6,920 resolv iterations) harvested 2026-06-22. M3.5.4 is current.

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

### M3.5.5 — Branching order aggregation and variance analysis 🔜 NEXT

**Goal:** Determine whether cone-derived branching orders vary meaningfully across instances within a family. If they don't, one canonical ordering per family suffices and M3.5.6 is low-priority; if they do, per-instance branching matters and M3.5.6 becomes high-priority.

**Problem:** `.var_order` files (~8,400 on cluster) contain the full ranked vertex lists but weren't harvested — only the scalar `grim_cone_uniq_pat`/`grim_cone_uniq_tar` counts reached the CSV. Pulling ~8,400 small files is wasteful; aggregate on the cluster instead.

**Steps:**

1. **`scripts/aggregate_var_order.jl`** — new script, runs on cluster. Reads all `<instance>.var_order` files from `/scratch/arthur/proofs/`. For each instance, computes:
   - `vo_n_pat`: number of ranked pattern vertices
   - `vo_top1_pat`, `vo_top1_frac`: most-frequent pattern vertex ID and its count / total count
   - `vo_top3_pats`: top-3 vertex IDs (comma-separated, for within-family comparison)
   - `vo_rank_entropy`: Shannon entropy of normalised count distribution (high = flat ordering, low = few vertices dominate)
   - `vo_gini`: Gini coefficient of counts (0 = uniform, 1 = one vertex has all)
   - `vo_top3_frac`: fraction of total count in top 3 vertices

   Outputs a single `var_order_stats.csv` (one row per instance).

2. **Within-family ordering similarity** — in the same script or a second pass: for each family, sample up to 200 instance pairs, compute Kendall tau on the shared vertex rankings. Output per-family `vo_mean_tau` and `vo_std_tau` to a summary table at the end of the CSV or a separate `var_order_family_summary.csv`.

3. **Integrate into harvest pipeline** — add `aggregate_var_order.jl` as step 2.5 in `scripts/harvest.sh`, add `var_order_stats.csv` to `scripts/harvest_pull.sh`.

4. **Interpret results:**
   - High `vo_mean_tau` (> 0.7) within a family → stable ordering, one canonical order per family suffices → M3.5.6 is low-value.
   - Low `vo_mean_tau` (< 0.4) → per-instance branching order matters → M3.5.6 becomes a priority for M4.
   - `vo_rank_entropy` close to max → flat ordering, branching order doesn't matter regardless.

**Deliverable:** `var_order_stats.csv` + `var_order_family_summary.csv`, interpretation in `paper/notes.tex §9`.

### M3.5.6 — Glasgow branching integration (future)

Read `.var_order` at startup as initial branching heuristic. Gated on M3.5.5: only worth pursuing if within-family Kendall tau is low (< 0.4) and rank entropy is not near-max. Hypothesis: preprocessing flags (M4) have larger impact than branching order.

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
                          ├─ M3.5.4 (supplemental classifier) ←── CURRENT
                          └─ M3.5.5 (branching order variance) ←── NEXT
                                └─ M3.5.6 (Glasgow branching integration, gated on M3.5.5)
                          └─ M4 (heuristic learning, depends on M3.5.4 + M3.5.5)
                                └─ M5 (cross-solver)
                                      └─ M6 (integration)
```
