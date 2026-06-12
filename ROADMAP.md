# TrimAnalyser — Research Roadmap

TrimAnalyser currently supports the LV and BIO benchmark families, extracts UNSAT cores via the resolv loop, and outputs a 45-column CSV per run. The roadmap below turns that foundation into a systematic study of proof structure and subgraph isomorphism heuristics, ending with upstream solver patches.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-12:** M1, M2, and M2.5 complete. M3 is current (first-pass manual analysis done for LV, bio, images-CVIU11, meshes-CVIU11; phase/scalefree/si pending targeted re-run).

---

## M1 — Full newSIP benchmark coverage ✅

Instance enumeration for all 8 newSIP families added to `src/orchestrator.jl`. All families share the LAD graph format; pairing rules vary by directory layout (flat pairs, pattern×target cross-product, or one pair per subdirectory). See `allgraphinstances()` for the full mapping.

---

## M2 — Proof-to-feature extraction ✅

~100 CSV columns added across `src/output.jl` and `scripts/aggregate_results.jl`:
- Step-type fractions: `rup_frac`, `pol_frac`, `ia_frac`, `red_frac`
- Cone depth distribution: `cone_depth_max/mean/p50/p90/entropy`, `cone_bottom_frac`, `cone_bottleneck_depth`, `cone_width_max/cv`
- RUP/POL depth profiles: `pol_depth_mean/cv`, `pol_depth_frac_bot/top`, `pol_ante_mean/max`, `pol_opb_frac`, `pol_before_rup_burst`, `rup_depth_cv`
- Compression: `literal_weakening_rate`
- Resolv: `resolv_pat_shrinkage`, `resolv_tar_shrinkage`, `fixpoint_reason`

Graph features in `scripts/graph_features.jl`: per-graph (nodes/edges/density/deg stats/diameter/radius/girth/clustering/triangles/bipartite/regular) and relational (node_ratio, density_ratio, max_degree_ratio, diameter_ratio, degree_compat_frac).

---

## M2.5 — Pipeline timeout correctness ✅

Verif and resolv loop moved from subprocess into the orchestrator. Trim subprocess is now trim-only (GC-isolated Julia); solver and VeriPB run as external binaries in orchestrator threads with independent `st`/`tt`/`vt` budgets per resolv iteration. OOM monitor extended to cover Glasgow solver processes.

---

## M3 — Graph taxonomy and heuristic fingerprinting 🔜 CURRENT

**Goal:** Characterise which graph families and structural properties predict proof difficulty and solver behaviour.

### First pass — manual analysis (complete for LV, bio, images-CVIU11, meshes-CVIU11)

Full write-up lives in `paper/notes.tex`. Quick section map:
- Benchmark family descriptions: `notes.tex §3` (§3.1 LV, §3.2 Bio, §3.3 Images-CVIU11, §3.4 Meshes-CVIU11)
- Proof fingerprints per family: `notes.tex §4` (§4.1–§4.4)
- Structural drivers (graph → proof shape): `notes.tex §5` (`\label{sec:drivers}`)
- Solver heuristic implications: `notes.tex §6` (`\label{sec:solver-heuristics}`)
- Open questions: `notes.tex §7` (`\label{sec:open}`)

**Key finding: images-CVIU11 vs meshes-CVIU11** (`notes.tex §3.3–§3.4, §4.3–§4.4`)

Both families come from Damiand & Solnon, *Computer Vision and Image Understanding* 2011 (submap isomorphism paper). The graphs model different things:
- **images-CVIU11**: region adjacency graphs from segmented 2D images — irregular, variable degree
- **meshes-CVIU11**: adjacency graphs from 3D mesh combinatorial maps — regular, bounded degree (~4–6)

| Feature | images-CVIU11 | meshes-CVIU11 |
|---|---|---|
| avg `grim_pbp_cone` | **146 898** | 12 947 |
| avg `grim_opb_cone` | 82 249 | **101 049** |
| `ia_frac` | **~50%** | ~0% |
| `pol_frac` | ~50% | **~100%** |
| avg `cone_depth_max` | **93.6** | 2.0 |
| `cone_depth_entropy` | **2.18** | 0.01 |
| `cone_bottom_frac` | 0.655 | **1.000** |
| `pol_ante_mean` | 5.45 | **15.97** |
| `pol_opb_frac` | 0.83 | **1.00** |
| `pol_before_rup_burst` | **72%** | ~0% |
| `resolv_pat_shrinkage` | 0.13 | **0.38** |

**Mesh proof shape — "single-wave algebraic certificate":** Regular bounded-degree topology means UNSAT is certified by a direct POL combination of ~16 original OPB constraints. Depth ≈ 1, pure POL, OPB-heavy, no propagation chain needed.

**Image proof shape — "propagation cascade":** Irregular adjacency structure forces Glasgow to propagate domain reductions step by step. Each domain reduction is recorded as a `pol ; ia @prev_pol ax+by>=c ; del @prev_pol` triplet (IA = "implied and add"). These chain into a deep proof DAG (max depth 93). PBP-heavy, 50% IA, `pol_before_rup_burst` in 72% of instances.

**Core shrinkage difference:** Mesh conflicts are topologically local (a compact substructure), so resolv isolates them easily (shrinkage 0.38). Image conflicts are spread across the irregular adjacency, harder to localize (shrinkage 0.13).

Key structural drivers (`notes.tex §5`):
- **Width–depth tradeoff**: pol_ante_mean and cone_depth_max are inversely correlated across families; dense graphs produce wide shallow proofs, sparse graphs produce narrow deep proofs.
- **Clustering → proof flatness**: high clustering (meshes: 0.325) enables flat one-wave algebraic certificates; zero clustering (bio) forces deep IA chains.
- **Node ratio → resolv effectiveness**: images (ratio 0.026, shrinkage 0.129) vs LV (ratio 0.30, shrinkage 0.495).

### Targeted re-run — phase, scalefree, si (`notes.tex §7 item 1`)

The current cluster run used `st=18 tt=600`, which is too tight for these harder families: phase (150-node target), scalefree (200-node target), si (200-node target). They are under-represented in the CSV (phase: 106, scalefree: 60, si: 605 rows) and most likely timed out before producing cone data.

Planned re-run (cluster only, not local — these instances require a proof run):
```bash
./trimnalyser --threads 92,1 solve resolv verif allgraphs minnodes=0 maxnodes=250 st=120 tt=3600 rand
```
Then re-aggregate and re-run `proof_survey.jl` to extend family profiles to all 8 families.

### Open questions for M3 completion (`notes.tex §7`)

- **Two-axis proof-structure classifier** (§7 item 2): `cone_depth_entropy × pol_frac` as the primary axes. `ia_frac` separates families well today but is coupled to the IA proof step, which may be eliminated in a future Glasgow proof format revision. `pol_frac` is a more robust substitute — it captures the same algebraic-vs-propagation axis and will remain valid after IA removal.
- **Images-CVIU11 coverage** (§7 item 6): only ~17% of instances have cone data. Determine the exact SAT / timeout / memout split from the status column before attributing this to graph structure.
- **Intra-family scaling laws** (§7 item 3): does proof size scale as $O(|V(P)|)$, $O(|V(T)|)$, or $O(|V(P)| \cdot |V(T)|)$ within each family? Relevant for setting cluster timeout budgets.
- **Bio bipartite structure** (§7 item 4, see TODO in `notes.tex §3.2`): 56% of bio pattern graphs are bipartite; a dedicated experiment exploiting bipartiteness in solver and trimmer.
- **Intra-LV sub-fingerprinting** (§7 item 5): `pat_deg_var` and `pat_is_bipartite` as axes that stratify LV into distinct sub-fingerprints.
- **Formal width–depth tradeoff** (§7 item 7): characterise the inverse relationship between `pol_ante_mean` and `cone_depth_max` in Glasgow proof terms.

Tools: `scripts/proof_survey.jl` HTML report + `paper/notes.tex` for written analysis.

### Second pass — automated clustering

- Cluster instances by `(graph_features, proof_features)` using k-means or hierarchical clustering; primary axes are `cone_depth_entropy` and `pol_frac` (see open question on two-axis classifier above)
- Visualise clusters in the HTML report (PCA or t-SNE projection)
- Identify the most discriminating features per cluster

**Depends on:** targeted phase/scalefree/si re-run above (extend the feature space before clustering).

**Deliverable:** A taxonomy document — cluster descriptions, representative instances, identifying features. Also: scalability plots of proof size and core shrinkage vs node count within each family, to guide `maxnodes` cutoffs on the cluster.

---

## M4 — Multi-axis heuristic learning

**Goal:** Learn which Glasgow configuration performs best for each cluster.

Grim is established as the best **trimming** heuristic and is fixed. The open question is the **solver** configuration: which Glasgow flags best match each proof fingerprint class.

### Heuristic dimensions

From the M3 proof fingerprints, two axes are the primary levers:

**Variable ordering** — which pattern vertex to branch on next:
- Most-constrained domain (standard)
- Degree-based (branch on highest-degree pattern vertex first)
- Graph-topology order (BFS from a high-betweenness seed — predicted useful for bio-like long-diameter instances)

**Preprocessing / propagation ordering** — how aggressively to reduce domains before and during search:
- Degree-based domain filtering: eliminate pattern vertices whose degree exceeds target max-degree (fast-paths ~19% of LV instances trivially; less relevant for images/bio)
- Triangle-aware propagation: enforce triangle-neighbourhood constraints jointly (predicted highly effective for mesh-like families given clustering 0.325; irrelevant for bio which has zero clustering)
- Supplemental graphs (`--no-supplementals`): controls auxiliary constraint propagation

**Family-specific predictions from M3** (hypotheses to test in M4 A/B evaluation; see `notes.tex §6` for rationale):

| Family class | Predicted best axis | Predicted ineffective |
|---|---|---|
| Mesh-like | Preprocessing first; triangle propagation | Variable ordering, deep search |
| LV-like | Degree pre-check + global neighbourhood propagator | Fine-grained variable ordering |
| Image-like | Variable ordering (most-constrained first) | Triangle propagation (low clustering) |
| Bio-like | BFS variable ordering from bottleneck vertex; multi-iter resolv | Degree pre-check (trivially compatible) |

### A/B testing framework (`scripts/heuristic_eval.jl`)

1. Takes a list of Glasgow flag combinations
2. Runs each on a benchmark subset (short timeout, ~10 s)
3. Collects solve time, node count, propagation count
4. Outputs a per-instance × per-config performance matrix

### Learning

- **Manual rules first:** use cluster profiles to hand-write a config selector (e.g. "if density > 0.15 and family = phase, use X")
- **Decision-tree model second:** train on cluster × config → performance; interpretable and auditable
- Cross-validate across families to measure transfer

**Deliverable:** A config-selector script that maps graph features → recommended Glasgow flags, evaluated by solver nodes and time on held-out instances.

---

## M5 — Cross-solver comparison

**Goal:** Establish whether the learned heuristics improve Glasgow, and whether other solvers benefit from the same insights.

**Baseline:** Glasgow (default) vs Glasgow (heuristic-selected) across all families.

**Comparison solvers:** Glasgow, RI, and at least one of VF2 / McSplit — exact set determined by integration effort.

**Protocol:** Fixed 180 s timeout; measure solved-instance count and PAR-2 score; stratify by family and cluster to identify where each solver excels and whether heuristics flip any rankings.

**Deliverable:** Summary comparison table + new `analyze_results.py` dashboard panel for cross-solver results.

**Key scientific question (heuristic transfer audit):** Do heuristics learned on LV generalise to phase / scalefree / si? This deserves a dedicated evaluation since it is the main transferability claim.

---

## M6 — Integration into solvers

**Goal:** Incorporate validated heuristics upstream.

### Glasgow (patch)

- Identify hooks for variable ordering, supplemental selection, and preprocessing level in the Glasgow source
- Add a lightweight graph-feature probe (computed before search) that selects the heuristic config at startup
- Submit as a Glasgow PR or maintain as a local patch

### Other SIP solvers (RI, VF2)

- Map heuristic dimensions to the equivalent knobs in each solver
- Adapt the config-selector to emit the correct flags per solver
- Benchmark to confirm gains transfer

**Deliverable:** Patched solver binaries (or config wrappers) that outperform defaults on the full newSIP benchmark suite.

---

## Dependency graph

```
M1 (benchmark coverage)
  └─ M2 (feature extraction)
        ├─ proof-cone visualisation
        ├─ scalability analysis
        └─ M3 (taxonomy: manual → clustering)
              └─ M4 (heuristic learning + A/B eval)
                    └─ M5 (cross-solver comparison)
                          ├─ heuristic transfer audit
                          └─ M6 (solver integration)
```
