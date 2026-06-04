# TrimAnalyser Code Audit Report

**Codebase:** `src/` (12 files, ~2,700 lines of Julia)
**Scope:** Correctness, performance, robustness, maintainability

---

## 4. Performance Concerns

### Background: the trimming heuristic pipeline

The two-queue system in `ruptrail` / `activate!` is itself a trimming heuristic, not
just bookkeeping. When `do_rup!(i)` is called during the backward traversal, `cone`
already reflects all proof steps marked necessary by earlier iterations. `activate!`
reads `cone[eid]` and routes the equation to `pq_prio` (already in cone) or
`pq_nonprio` (not yet). `ruptrail` drains `pq_prio` fully before taking one step from
`pq_nonprio` — preferring propagation from constraints already known to be needed.
This steers the conflict toward antecedents already in the cone and directly limits
cone growth.

The full heuristic chain is:
**outer backward traversal → `cone` accumulation → `activate!` routing →
`pq_prio`/`pq_nonprio` ordering → first conflict found → `conflicttrail(mode)` analysis
→ which antecedents enter the cone**

`cone` is written only by `push_frontier!` in the outer `getcone!` loop — never inside
`ruptrail`. Any performance optimisation that produces bit-identical slack values leaves
the entire chain unaffected.

**Note — `propagate!` inconsistency:** the initial contradiction search (`propagate!`,
called once for the UNSAT case) uses a flat `trues(n)` bitset and a linear forward scan
with no two-queue priority — and hardcodes `Grim()` for conflict analysis regardless of
the active mode. This is benign in practice because at that call site `cone` has exactly
one entry (`firstcontradiction`), so the priority distinction is trivial. It is however
architecturally inconsistent with `ruptrail` and should be unified if `propagate!` is
ever called with a non-empty cone.

---

### 4.1 `update_slack_on_assign!` O(k) inner scan — `types.jl:193–213`

For each variable assignment, for each equation containing that variable (`d` equations
via the inverse index), the function re-scans all literals of the equation (`k`
literals) to locate variable `v` by linear search. Total cost: O(k·d) per assignment.

**Fix:** extend `PBSystem` construction with a `var_lit_idx::Vector{Int32}` array
(same shape as `var_eqs`), where `var_lit_idx[j]` is the flat literal index of variable
`v` within equation `var_eqs[j]`. Built during the existing inverse-index pass at zero
extra cost (one assignment per literal). Then `update_slack_on_assign!` becomes O(d)
with a direct index lookup and no inner loop.

The slack values written to `slack_cache`/`slack_rev_cache` are bit-identical. No
interaction with `activate!` routing or `conflicttrail` mode.

### 4.2 `init_slack_cache!` O(n·k) rebuild on every RUP step — `trimmer.jl:281`

`ruptrail` calls `init_slack_cache!(t, sys)` at the start of every RUP step.
`reset!(trail)` zeros all assignments immediately before, so `init_slack_cache!` always
runs against an all-zero `assi` vector. With all variables unassigned the initial slack
is a pure function of the constraint system:

- `slack_fwd[e]  = sum(coefs[e]) - rhs[e]`
- `slack_rev[e]  = rhs[e] - 1`   (since total − (total − rhs + 1) = rhs − 1)

Both are constants of `PBSystem`. Adding `initial_slack_fwd::Vector{Int32}` and
`initial_slack_rev::Vector{Int32}` to `PBSystem` (computed once at construction)
reduces `init_slack_cache!` to two `copyto!` calls — O(n) memcopy instead of O(n·k)
arithmetic. Trail reset and per-step isolation are unchanged.

**Why the originally-documented options are wrong for this context:**
- *Option A (base_trail + replay level-0):* there are no persistent level-0
  propagations — each `ruptrail(sys, i, ...)` uses constraints `1:i`, a different set
  per step. There is no stable base trail to replay from.
- *Option B (lazy dirty bitmap):* since `reset!` zeros all assignments before every RUP
  step, every constraint is dirty. Marking everything dirty and recomputing everything
  is identical cost to the current code.

The fix produces bit-identical slack values and has no effect on `activate!` routing or
`conflicttrail` mode.

### 4.3 `findfullassi` naive O(n²) unit propagation — `parser.jl:372–389`

The `TODO` comment on line 374 acknowledges this. The outer `while changes` loop
re-scans all `1:c-1` constraints until fixpoint — quadratic in constraint count when
many variables are unset. Called at parse time for every `soli`/`solx` step.

**Fix (if needed):** build a temporary `Vector{Vector{Int}}` inverse index from
`FlatEqStore` restricted to constraints `1:c`, then run BFS propagation from the
initially-assigned variables. Cost O(propagation chain) instead of O(n²). No CDCL
watch-list machinery needed — this is a one-shot snapshot propagation, not incremental.

**Why the originally-documented options are wrong:**
- *Option A (CDCL watch-list):* watch-lists are maintained incrementally across
  clause-learning iterations. Here we need a single snapshot propagation at parse time;
  a temporary inverse index is sufficient and simpler.
- *Option B (reuse PBSystem):* `PBSystem` does not exist at parse time. `findbound`
  and `solbreakingctr` are called during `readproof`, before `PBSystem` is constructed.

**Measure first:** `soli`/`solx` steps are rare (one per enumerated solution; most
proofs have zero). Profile before investing in this fix.

---

## 5. Code Quality

### 5.1 `conflicttrail` duplicated between `Grim` and `Clit` ✅ fixed

Extracted `_arrange_falsified_lits!` dispatch helpers; replaced two ~100-line methods
with one unified body in `trimmer.jl`.

### 5.2 Instance prefix list duplicated four times ✅ fixed

Consolidated into `is_instance_name()` in `TrimAnalyser.jl`; replaced four inline
copies in `config.jl` and `orchestrator.jl`.

### 5.3 `filesize` shadows `Base.filesize` ✅ fixed

Removed the shadow; all callers transparently use `Base.filesize`.

### 5.4 `processred` inserts two entries with identical data ✅ fixed

`redid == length(store)` after `push_eq!`, so the second write was always overwriting
the first with the same value. Removed the redundant `redwitness[redid]` assignment.

### 5.5 `pol_weaken!` uses linear search ✅ fixed

Replaced `findfirst(==(Int32(var)), vars)` with `searchsortedfirst` (vars are sorted
by variable index from `readlits`).

### 5.6 Uncaught OOB risk in `solvepol_flat!` ✅ fixed

Added `j >= length(st)` guard before the `st[j+1]` access.

---

## 6. Minor / Style Issues ✅ fixed

| Location | Fix applied |
|---|---|
| `utilities.jl` | Removed spurious 4-space indentation |
| `parser.jl` | Bare string `throw(...)` → `error(...)`; fixed "assignement" typo |
| `writer.jl:244` | Added clarifying comments on the `lastindex` decrement/increment pair |

---

## 7. Summary

| Severity | Count | Status | Key Items |
|---|---|---|---|
| **Bug (wrong output)** | 3 | ✅ fixed | `~` never written in pol (`writer.jl:85`), Int32 overflow in multiply/saturate (`pol.jl:88`), rhs_adj overflow in add (`pol.jl:33,161`) |
| **Potential crash** | 2 | ✅ fixed | RED subproof guard (`trimmer.jl`), heap internals replaced with `empty!` |
| **Dead code** | 3 | ✅ fixed | `ruptrail_bfs`+`conflicttrail_bfs` removed, `Dumping` module removed, RED skeleton kept |
| **Performance** | 3 | 🔜 pending | O(k·d) assignment update → `var_lit_idx` fix (§4.1), O(n·k) slack rebuild → precomputed initial slack (§4.2), O(n²) soli propagation → BFS with temp inverse index, measure first (§4.3) |
| **Maintainability** | 6 | ✅ fixed | `conflicttrail` deduplicated, prefix list consolidated, `filesize` shadow removed, dual redwitness entry removed, linear weaken → `searchsortedfirst`, OOB guard added |