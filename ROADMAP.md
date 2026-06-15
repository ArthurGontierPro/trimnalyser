# TrimAnalyser — Research Roadmap

TrimAnalyser supports all 8 newSIP benchmark families, extracts UNSAT cores via the resolv loop, outputs ~115-column CSV per run, and maps proof cone leaves back to CP constructs via labelled Glasgow proofs.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-15:** M1, M2, M2.5, M3.5.1–M3.5.3 complete. M3 is current. Cluster run in progress (medium-hard instances, 200–500 nodes, st=600 tt=5400).

---

## M1 — Full newSIP benchmark coverage ✅

Instance enumeration for all 8 newSIP families in `src/orchestrator.jl`. See `allgraphinstances()` for pairing rules per family layout.

---

## M2 — Proof-to-feature extraction ✅

~100 CSV columns across `src/output.jl` and `scripts/aggregate_results.jl`: step-type fractions, cone depth distribution, RUP/POL depth profiles, compression rate, resolv shrinkage. Graph features in `scripts/graph_features.jl`.

---

## M2.5 — Pipeline timeout correctness ✅

Verif and resolv moved into orchestrator threads with independent `st`/`tt`/`vt` budgets. OOM monitor covers Glasgow solver processes.

---

## M3 — Graph taxonomy and heuristic fingerprinting 🔜 CURRENT

**Goal:** Characterise which graph families and structural properties predict proof difficulty and solver behaviour.

### First pass — manual analysis (LV, bio, images-CVIU11, meshes-CVIU11)

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

### Targeted cluster run — in progress (2026-06-15)

```bash
julia --threads 64,1 trimnalyser.jl solve resolv verif allgraphs minnodes=200 maxnodes=500 st=600 tt=5400 rand
```

Targets medium-hard instances across all families. First run with M3.5 labels active (Glasgow recompiled). Timeouts calibrated on competition silver time (st=600 ≈ 500s silver; tt=5400 = 1.2× competition checker time 4500s).

**Expected outputs:** CP provenance fingerprints per family (proof_survey sections 7–11), supplemental graph depth profiles, elim-fraction vs depth correlation data, coverage of phase/scalefree/si families at higher node counts.

### Open questions (`notes.tex §7`)

- **Two-axis classifier:** `cone_depth_entropy × pol_frac` as primary family discriminants (more robust than `ia_frac` which may be removed in future proof formats).
- **Images-CVIU11 coverage:** only ~17% of instances have cone data — determine SAT/timeout/memout split.
- **Intra-family scaling:** proof size as O(|V(P)|), O(|V(T)|), or O(|V(P)|·|V(T)|)?
- **Intra-LV sub-fingerprinting:** `pat_deg_var` and `pat_is_bipartite` as stratification axes.

### Second pass — automated clustering (after cluster run)

Cluster by `(graph_features, proof_features)` using k-means / hierarchical; primary axes `cone_depth_entropy` and `pol_frac`. Visualise in proof_survey (PCA/t-SNE). Deliverable: taxonomy doc + scalability plots.

---

## M3.5 — CP constraint provenance and branching heuristic 🔜

**Goal:** Map cone leaves to CP constructs; identify which Glasgow components are proof-critical per family; derive branching heuristic.

### M3.5.1 — Label coverage in `proof.cc` ✅

Glasgow (branch `labels-for-analysis`, commits b5439ad + de50e8c) writes labels on all level-0 constraints:

| Label | Location | CP construct |
|---|---|---|
| `@al1<p>`, `@am1<p>` | OPB | At-least/at-most-one domain |
| `@inj<t>` | OPB | Injectivity |
| `@g0adj<p>_<t>_<q>` | OPB | Base adjacency |
| `@forb<p>_<t>` | OPB | Pre-search forbidden assignment |
| `@g<k>adj<p>_<t>_<q>` | PBP level-0 | Supplemental graph k≥1 adjacency |
| `@elimdeg<p>_<t>` | PBP level-0 | Degree-incompatibility elimination |
| `@elimnds<p>_<t>` | PBP level-0 | NDS-incompatibility elimination |
| `@loop<p>_<t>` | PBP level-0 | Loop incompatibility |

Search-level PBP steps are intentionally unlabeled (cone traversal reaches labeled leaves via backward reachability). Guard on `@elimdeg`/`@elimnds`: label emitted only on first derivation to prevent duplicate labels when multiple supplemental graph levels derive the same pair.

### M3.5.2 — Cone label analysis in trimmer ✅

`classify_label` + `cone_label_stats` + `writeout_cone_labels` in `src/output.jl`. New CSV columns: `grim_cone_{al1,am1,inj,g0adj,g1adj,g2adj,g3adj,forb,elimnds,elimdeg,loop,unlabeled}` (counts) + `grim_cone_frac_{inj,g0adj,g1adj,g2adj,g3adj,forb,elimnds,elimdeg}` (fractions of OPB cone).

### M3.5.3 — Branching heuristic sidecar ✅

Pattern vertex occurrence counts in OPB cone → `<instance>.var_order` (sorted descending). CSV: `grim_cone_uniq_pat`, `grim_cone_uniq_tar`.

### M3.5 analysis — pending cluster data

Five new sections in `proof_survey.jl` (sections 7–11) ready to populate:
- **§7** CP provenance table: mean/med/[Q1–Q3] per family per label category
- **§8** CP composition stacked bar: all categories fraction of OPB cone
- **§9** Supplemental depth: g0/g1/g2/g3 per family — which levels are proof-critical?
- **§10** Scatter elim\_frac × cone\_depth\_max — tests preprocessing→shallow-proof hypothesis
- **§11** Unlabeled count diagnostic

**Key question to answer:** For each family, which supplemental graph depths (g1/g2/g3) contribute meaningfully to the UNSAT cone? A near-zero gNadj fraction for a family means depth-N supplementals can be disabled without affecting proof validity — a direct `--supplementals` tuning knob for M4.

### M3.5.4 — Glasgow branching integration (future)

Read `.var_order` at startup as initial branching heuristic. Held until M3.5 cluster data confirms meaningful heuristic variation across instances. Hypothesis: preprocessing flags (M4) have larger impact than branching order.

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
M1 → M2 → M2.5 → M3 (taxonomy)
                    └─ M3.5 (CP provenance) ←── cluster run 2026-06-15
                          └─ M4 (heuristic learning)
                                └─ M5 (cross-solver)
                                      └─ M6 (integration)
```
