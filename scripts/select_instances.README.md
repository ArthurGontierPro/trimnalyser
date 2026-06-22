# select_instances.jl

Selects a representative subset of UNSAT instances from `cluster_results.csv` and `graph_features.csv` using stratified sampling across 6 axes. Produces an `instances.txt` file with `pattern_path<TAB>target_path` per line, ready for cluster runs.

## Usage

```bash
julia --project=scripts scripts/select_instances.jl <cluster_results.csv> <graph_features.csv> [output_file] [options]
```

### Examples

```bash
# Default: ~500 instances, 3 per stratum
julia --project=scripts scripts/select_instances.jl cluster_results.csv graph_features.csv instances.txt

# Larger set: ~700 instances
julia --project=scripts scripts/select_instances.jl cluster_results.csv graph_features.csv instances.txt --per-stratum=5

# Very large set: ~1200-1400 instances
julia --project=scripts scripts/select_instances.jl cluster_results.csv graph_features.csv instances.txt --per-stratum=10

# Different seed for a different random draw from the same strata
julia --project=scripts scripts/select_instances.jl cluster_results.csv graph_features.csv instances.txt --seed=123
```

### Options

| Option | Default | Description |
|---|---|---|
| `--per-stratum=N` | 3 | Max instances sampled per stratum. Higher = larger output set. |
| `--seed=S` | 42 | RNG seed for reproducible sampling. |

## Filtering

Only **base UNSAT instances with proof** are considered:
- `has_proof == true`
- No `.coreN` resolv iterations
- Rule-type fractions (`grim_rup_frac + pol + ia + red`) must sum to ~1.0 (drops rows with corrupted data)

## Stratification axes

### 1. Family
The benchmark family: `LV`, `bio`, `images-CVIU11`, `meshes-CVIU11`.

### 2. Proof size
Quartile bins on `grim_total_cone` (total proof steps in the trimmed cone): `small`, `medium`, `large`, `huge`.

### 3. Rule archetype
Based on the fraction of each rule type (RUP/POL/IA) in the cone:

| Bin | Condition |
|---|---|
| `pol_heavy` | POL fraction > 80% |
| `pol_ia_mix` | IA > 30% and POL > 30% |
| `has_rup` | RUP > 5% |
| `pol_only` | Everything else (low IA, low RUP) |

### 4. Label diversity
Count of distinct non-zero constraint-label types in the cone (e.g. `inj`, `g1adj`, `forb`, `hall`, `pathg1`, `nogood`, …). Binned as: `ldiv_1-3`, `ldiv_4-6`, `ldiv_7-10`, `ldiv_11+`.

### 5. Node ratio
`pattern_nodes / target_nodes` from graph features. Captures whether the pattern is much smaller than the target or similar in size:

| Bin | Range |
|---|---|
| `tiny_pat` | ratio ≤ 0.15 |
| `small_pat` | 0.15 < ratio ≤ 0.4 |
| `balanced` | 0.4 < ratio ≤ 0.7 |
| `large_pat` | ratio > 0.7 |

### 6. Search intensity
Fraction of cone steps that are `guess` or `nogood` labels (search-related proof steps):

| Bin | Range |
|---|---|
| `no_search` | < 0.0001% |
| `light_search` | < 1% |
| `mod_search` | 1–10% |
| `heavy_search` | > 10% |

## Output files

- **`instances.txt`** — One line per instance: `pattern_path\ttarget_path` (absolute paths resolved via the same logic as `src/solver.jl:parsegraphfiles`).
- **`instances_strata.csv`** — Diagnostic CSV with each selected instance's stratum assignment and raw metrics (`grim_total_cone`, rule fracs, guess/nogood counts, etc.).

## Using with trimnalyser

The generated `instances.txt` can be passed directly to the trimnalyser via the `instfile=` flag:

```bash
./trimnalyser --threads 92,1 solve resolv verif instfile=instances.txt st=18 tt=600
```

This runs the same parallel batch pipeline as `allgraphs`, but restricted to the selected instances. The trimnalyser reverse-maps the tab-separated paths back to instance names automatically. Plain instance-name files (one name per line, no tabs) are also accepted.

## How it works

1. Load and join `cluster_results.csv` with `graph_features.csv` on instance name.
2. Filter to clean base UNSAT instances.
3. Compute bin assignments for each of the 6 axes.
4. Cross all axes to form strata (theoretical max ~768, typically ~200 non-empty).
5. Sample up to `--per-stratum` instances uniformly at random from each non-empty stratum.
6. Resolve instance names to graph file paths and write output.

This guarantees that every observed combination of proof characteristics is represented, including rare profiles (e.g. heavy-search instances, RUP-heavy proofs) that would be undersampled by simple random selection.
