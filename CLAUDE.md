# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Critical: Testing Constraints

**Laptop disk is full.** The proof benchmark set is gigantic and cannot fit locally.

- **Never** run without specifying an instance name or without reading memory first.
- **Standard local test** after any code change:
  ```bash
  ./trimnalyser LVg10g12 overwrite resolv
  ```
  Proof files are at `/home/arthur_gla/veriPB/subgraphsolver/proofs/`. This instance is 858 KB OPB + 24 MB PBP and exercises the full resolv loop.
- **Syntax-only check** (no execution, zero disk writes — only catches parse errors):
  ```bash
  julia --startup-file=no -e 'for f in readdir("src"; join=true); endswith(f,".jl") && Meta.parseall(read(f,String)); end; println("OK")'
  ```

## Common Commands

```bash
# Single instance
./trimnalyser LVg10g12 overwrite resolv

# Cluster full run
./trimnalyser --threads 192,1 solve resolv verif allgraphs maxnodes=3000 st=180 tt=6000 rand

# Aggregate cluster results into CSV
julia scripts/aggregate_results.jl /scratch/arthur/proofs/ cluster_results.csv

# Generate interactive HTML analysis
python3 scripts/analyze_results.py cluster_results.csv cluster_analysis.html

# Quick CSV statistics
python3 scripts/quick_stats.py cluster_results.csv

# Build sysimage (eliminates JIT startup, ~5s → ~0.1s)
julia --project=. build_sysimage.jl
```

Key flags: `solve` (run SIP solver first), `resolv` (iterative re-solve on UNSAT cores), `verif` (run VeriPB after trim), `overwrite` (re-trim if .smol already exists), `profile` (StatProfilerHTML), `allgraphs` (enumerate all benchmark pairs), `bfs`/`clit` (alternative trimming modes).
Timeout args: `st=N` (solver timeout seconds), `tt=N` (trim timeout seconds), `maxnodes=N` (filter graph pairs by size).

## Architecture: src/ (multi-file package)

The tool operates in two modes depending on how it is invoked:

**Orchestrator mode** (no instance in ARGS, or `allgraphs`): spawns one subprocess per instance via `julia bin/trimnalyser.jl <instance>`, with an OOM monitor thread watching `/proc/<pid>/status` every 10s and killing processes exceeding `maxmem=` GB.

**Subprocess mode** (instance name in ARGS): trims a single proof instance, writes `.smol.opb` + `.smol.pbp` output, then exits. SIGTERM is caught cleanly (exit 124) to prevent signal corruption of `@inbounds` code during timeout.

Subprocess output is routed via a `.subout` temp file so it doesn't interleave with orchestrator output.

### Source layout (use code folding; `end` stays on same line for short functions)

| File | Lines | Contents |
|------|-------|----------|
| `src/TrimAnalyser.jl` | 57 | Module root, static constants, include chain, precompile workload |
| `src/config.jl` | 73 | `Config` struct, `parse_config!`, `argflags` |
| `src/utilities.jl` | 32 | `available_memory`, file helpers |
| `src/types.jl` | 392 | Core structs: `FlatEqStore`, `SystemLink`, `PBSystem`, `Trail`, `Ante`, `PolScratch` |
| `src/parser.jl` | 417 | `readopb`, `readproof`, `tokenize!` |
| `src/pol.jl` | 263 | `PolScratch`, `solvepol_flat!` |
| `src/trimmer.jl` | 702 | `getcone!`, `propagate_level0!`, `conflicttrail`, `ruptrail` |
| `src/writer.jl` | 315 | `writeconedel`, `writeeq`, `writered`, `writepol` |
| `src/solver.jl` | 204 | `runsipsolver`, `resolvecore`, `writecoreladfile` |
| `src/output.jl` | 372 | `writeout_*`, `verify`, `printconestat`, statistics |
| `src/pipeline.jl` | 148 | `trimnalyseandcie`, `trimnalyse`, `smol_complete` |
| `src/orchestrator.jl` | 250 | `main()`, OOM monitor, instance enumeration |

### Key data structures

**`FlatEqStore`** — CSR-like flat storage for all parsed equations. Replaces `Vector{Eq}` to eliminate millions of heap allocations. Fields: `vars/coefs/signs/rhs` (flat arrays) + `row_ptr` (offsets). Used by both parser and POL evaluator.

**`SystemLink`** — CSR storage for proof step link data. `idx[i]` encodes: `k>0` → slice in flat `data[ptr[k]:ptr[k+1]-1]`; `k<0` → shared singleton constant (rule type); `k=0` → mutable `Vector{Int}` in `extra` dict (for RUP cone / RED refs). Zero allocation per step during parsing.

**`PBSystem`** — Dual-index CSR for the constraint system. Forward index: `row_ptr/vars/coefs/signs/rhs`; inverse index: `var_ptr/var_eqs` (all equations containing each variable). Built once from `FlatEqStore` for the trimmer.

**`PolScratch`** — Task-local scratch pool for POL evaluation. Stack-based expression evaluator that operates directly on flat arrays; pushes the final result into `FlatEqStore` without allocating any `Eq` or `Lit` structs. Retrieved via `task_local_storage(:pol_scratch)`.

**`Trail`** — Propagation trail with `pos[]` (step index per variable) and `assi[]` (assignment: 0=unset, 1=true, 2=false) for O(1) lookup.

**`Ante`** — Antecedent set: O(1) membership + O(k) iteration, used by `getcone!` to track which constraints justify each assignment.

### Parser internals

Files are read via `Mmap.mmap` → byte array. `tokenize!` splits into `ByteSpan` tokens (contiguous views, no copies). `varmap::Dict{Vector{UInt8},Int}` enables zero-allocation lookups with `ByteSpan` keys (same hash as `Vector{UInt8}`). New variables copy their bytes once (`copy(tmp)`) and are kept permanently. `varmap_inv::Vector{String}` is built at write time (not a hot path).

### Trimming algorithm

`getcone!` does backward reachability from the contradiction: traverses `systemlink` in reverse, accumulates the cone of needed proof steps, and runs `propagate_level0!` (unit propagation with `Trail`/`Ante`) to verify RUP steps. Three modes: `Grim` (standard DFS), `Clit` (cone-first + essentials filter), `Bfs` (BFS propagation).

### Resolv loop

`resolvecore` (`src/solver.jl`) iterates: extract UNSAT core → write reduced LAD graph → re-run Glasgow solver → trim new proof. Stops when the pattern graph no longer shrinks or a fixpoint is reached. Core graphs are written as `.lad` files; UNSAT core output is `.smol.opb`/`.smol.pbp`.

## Output files

- `<instance>.smol.opb` — trimmed constraint file
- `<instance>.smol.pbp` — trimmed proof file
- `<instance>.out` / `<instance>.err` — per-instance stdout/stderr logs (parsed by `scripts/aggregate_results.jl`)
- `cluster_results.csv` — aggregated metrics (60+ columns) from all `.out` files
