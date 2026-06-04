# TrimAnalyser — Research Roadmap

TrimAnalyser currently supports the LV and BIO benchmark families, extracts UNSAT cores via the resolv loop, and outputs a 45-column CSV per run. The roadmap below turns that foundation into a systematic study of proof structure and subgraph isomorphism heuristics, ending with upstream solver patches.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

---

## M1 — Full newSIP benchmark coverage

**Goal:** Run TrimAnalyser on all 9 families in the newSIP benchmark, not just LV and BIO.

All families use the same LAD graph format (`first line = node count; subsequent lines = degree n1 n2 ...`), so no parser changes are required. The only work is instance enumeration and path resolution in `src/orchestrator.jl`.

| Family | Layout | Pairing rule |
|--------|--------|-------------|
| images-CVIU11 | `images-CVIU11/patterns/patternN` + `…/targets/targetN` | match by N |
| images-PR15 | `images-PR15/patternN` (targets TBD) | match by N |
| meshes-CVIU11 | `meshes-CVIU11/patterns/patternN` + `…/targets/targetN` | match by N |
| phase | `phase/*-pattern` + `phase/*-target` siblings | pair by base name |
| scalefree | `scalefree/A.NN/pattern` + `scalefree/A.NN/target` | one pair per directory |
| si | `si/<group>/<instance>/pattern` + `…/target` (deeply nested) | one pair per instance dir |

**Deliverable:** `./trimnalyser --threads 192,1 solve resolv verif allgraphs` runs across all families; results land in the CSV with a new `family` column for stratified analysis.

---

## M2 — Proof-to-feature extraction

**Goal:** Enrich the CSV with proof-structural and graph-structural features to power downstream analysis.

### Proof features (extend `src/output.jl`)

- Step-type breakdown: fraction of RUP / POL / RED / IA steps in the trimmed proof
- Cone depth: max and mean depth of the backward-reachability DAG
- Literal weakening rate: `(cone_literals − smol_literals) / cone_literals`
- Resolv shrinkage curve: per-iteration `(core_pattern_nodes, core_target_nodes)` — already partially tracked, expose fully
- Fixpoint reason: did the resolv loop stop because the core stabilised or hit the iteration cap?

### Graph features (new `scripts/graph_features.jl`)

Compute static properties of each pattern/target graph and join them into the CSV by instance name:

- Node count, edge count, density
- Degree sequence statistics (min, max, mean, variance)
- Diameter and radius (BFS)
- Clustering coefficient, triangle count
- Is-regular / is-bipartite / is-planar flags

**Deliverable:** CSV grows by ~20 columns; `analyze_results.py` and `quick_stats.py` updated to display them.

### Bonus: proof-cone visualisation

Extend the existing DOT output in `src/output.jl` to annotate cone nodes by step type (colour) and depth (label). Useful for manual inspection of hard or surprising instances.

---

## M3 — Graph taxonomy and heuristic fingerprinting

**Goal:** Characterise which graph families and structural properties predict proof difficulty and solver behaviour.

### First pass — manual analysis

Use the enriched CSV to answer:

- Which families produce the largest and deepest proofs?
- Does the RUP / POL / RED mix cluster by family?
- Is core shrinkage correlated with graph density, degree variance, or diameter?
- Does `--no-supplementals` help or hurt on phase / scalefree vs LV?

Tools: `analyze_results.py` HTML report + ad-hoc Julia or pandas notebooks.

### Second pass — automated clustering

- Cluster instances by `(graph_features, proof_features)` using k-means or hierarchical clustering
- Visualise clusters in the HTML report (PCA or t-SNE projection)
- Identify the most discriminating features per cluster

**Deliverable:** A taxonomy document — cluster descriptions, representative instances, identifying features. Also: scalability plots of proof size and core shrinkage vs node count within each family, to guide `maxnodes` cutoffs on the cluster.

---

## M4 — Multi-axis heuristic learning

**Goal:** Learn which Glasgow configuration performs best for each cluster.

### Heuristic dimensions

| Axis | Examples |
|------|---------|
| Search | Variable / value ordering, supplemental graph use (`--no-supplementals`), restarts |
| Preprocessing | Degree-based domain filtering aggressiveness, active propagators |
| Propagation order | Propagator priority when domains change; early vs late symmetry breaking |

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
