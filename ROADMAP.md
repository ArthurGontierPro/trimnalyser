# TrimAnalyser — Research Roadmap

TrimAnalyser currently supports the LV and BIO benchmark families, extracts UNSAT cores via the resolv loop, and outputs a 45-column CSV per run. The roadmap below turns that foundation into a systematic study of proof structure and subgraph isomorphism heuristics, ending with upstream solver patches.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-09:** M1 and M2 complete. M3 is current.

---

## M1 — Full newSIP benchmark coverage ✅

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

## M2 — Proof-to-feature extraction ✅

**Goal:** Enrich the CSV with proof-structural and graph-structural features to power downstream analysis (M3 clustering).

### Proof features (extend `src/output.jl`)

**Step composition**
- `rup_frac`, `pol_frac`, `ia_frac`, `red_frac` — fraction of each step type in the trimmed proof

**Cone depth distribution** (beyond max/mean — encodes proof *shape*)
- `cone_depth_max`, `cone_depth_mean` — range and centre
- `cone_depth_p50`, `cone_depth_p90` — where is most of the work?
- `cone_depth_entropy` — Shannon entropy of the per-depth step counts; low = concentrated (ladder/chain), high = spread (wide pyramid)
- `cone_bottom_frac` — fraction of PBP steps at depth ≤ 2; high means almost all reasoning is direct propagation from axioms, low means deep multi-step inference chains
- `cone_bottleneck_depth` — shallowest depth band where step count drops below a threshold (≤ 5); measures the "waist" of the proof DAG, i.e. the minimum cut depth

**Cone width distribution** (shape orthogonal to depth)
- `cone_width_max` — peak number of steps at any single depth
- `cone_width_cv` — coefficient of variation of per-depth counts; near-zero = uniform ("ladder" as in LVg15g20), high = spiky ("multi-wave" as in bio083147)

**RUP / POL depth profiles** (proof strategy fingerprint)

The interplay between RUP and POL across depth levels encodes the solver's proof strategy:
- *pure RUP*: all propagation, no algebraic derivation needed
- *POL bottom-heavy*: algebraic warm-up near axioms, then propagation cascades up
- *POL top-heavy*: propagation first, algebraic reasoning closes the final gap
- *interleaved*: alternating derivation and propagation bursts throughout

Features:
- `rup_depth_cv` — coefficient of variation of RUP step counts across depth bands; near-zero = RUP concentrated at one level (a burst), high = spread uniformly
- `pol_depth_mean`, `pol_depth_cv` — centroid and spread of POL in depth space
- `pol_depth_frac_bot` — fraction of POL steps in the bottom depth quartile (warm-up pattern indicator)
- `pol_depth_frac_top` — fraction of POL steps in the top depth quartile (closing pattern indicator)
- `pol_ante_mean`, `pol_ante_max` — average and max antecedent count per POL step; measures how heavy each algebraic derivation is (accessible directly from `systemlink` for k>0 steps)
- `pol_opb_frac` — fraction of POL antecedents that are OPB axioms vs derived steps; low value means POL is building on a chain of prior derivations, not directly on axioms
- `pol_before_rup_burst` — boolean: does any depth band contain a POL step immediately followed at depth+1 by a RUP count > 5× the per-depth mean? Captures the "POL unlocks propagation" pattern

**Compression and weakening**
- `literal_weakening_rate` — `(cone_literals − smol_literals) / cone_literals`

**Resolv loop**
- Shrinkage curve: per-iteration `(core_pattern_nodes, core_target_nodes)` — expose fully
- `resolv_pat_shrinkage`, `resolv_tar_shrinkage` — total fractional reduction
- `fixpoint_reason` — `stabilized` vs `iter_cap`

### Graph features (new `scripts/graph_features.jl`)

Split into **per-graph** properties (computed once per LAD file, joined by instance) and **per-instance relational** properties (pattern vs target ratios, computed at pair level). The relational features are the primary predictors of SIP hardness.

**Per-graph (prefix `pat_` / `tar_`)**
- `nodes`, `edges`, `density`
- Degree sequence: `deg_min`, `deg_max`, `deg_mean`, `deg_var`
- `diameter`, `radius` (BFS)
- `clustering`, `triangles`
- `girth` — length of shortest cycle; governs how tight cycle-based domain filtering is
- Flags: `regular`, `bipartite`, `planar`

**Per-instance relational** (pattern ÷ target)
- `node_ratio` = `pat_nodes / tar_nodes` — how tight is the embedding problem
- `density_ratio` = `pat_density / tar_density` — sparse-in-dense vs equal-density
- `max_degree_ratio` = `pat_deg_max / tar_deg_max` — degree headroom
- `diameter_ratio` = `pat_diameter / tar_diameter`
- `degree_compat_frac` — fraction of pattern nodes whose degree ≤ `tar_deg_max`; the simplest necessary condition for a valid mapping; values near 1 = structurally compatible, values < 1 = trivially UNSAT from degree alone

**Deliverable:** CSV grows by ~35 columns; `analyze_results.py` and `quick_stats.py` updated to display them.

### Proof-cone visualisation (bonus, already partially done)

DOT files (`cone.hist`, `cone.bfs`, `cone.topk`) are written per instance. The hist variant is the most analytically useful — it shows the per-depth step-count profile with step-type breakdown. The DAG variants (bfs, topk) are hard to read at scale; their main use is manual inspection of specific outlier instances.

---

## M3 — Graph taxonomy and heuristic fingerprinting 🔜 CURRENT

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
