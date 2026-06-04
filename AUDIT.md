# TrimAnalyser Code Audit Report

**Codebase:** `src/` (12 files, ~2,700 lines of Julia)
**Scope:** Correctness, performance, robustness, maintainability

---

## 1. Confirmed Bugs

### 1.1 `writepol` never emits `~` for negated literal axioms — `writer.jl:85`

The sign-detection check is wrong:
```julia
sign = mod((-t), 100) != 1
```
The encoding in `solvepol_flat!` (`pol.jl:245`) is:
- positive literal `x`:  `t = -100*var - 99`  → `mod(-t, 100) = 99`
- negated literal `~x`:  `t = -100*var - 100` → `mod(-t, 100) = 0`

Both `99 != 1` and `0 != 1` are `true`, so `sign` is always `true` and `~` is never
printed. The correct check is `mod((-t), 100) != 0`. Any proof containing a negated
literal axiom in a POL step produces incorrect output that won't verify.

**Fix:** Change `writer.jl:85` from `!= 1` to `!= 0`.

---

### 1.2 `pol_multiply!` silently overflows Int32 coefficients — `pol.jl:88`

```julia
scratch[2][i] *= Int32(multiplier)
```
`scratch[2]` holds Int32 coefficients. Multiplying by a large PB multiplier wraps
silently. Should use Int64 for the intermediate product before storing back.

Similarly in `pol_saturate!` (`pol.jl:126`):
```julia
coefs[i] > rhs && (coefs[i] = Int32(rhs))
```
If `rhs` (Int64) exceeds `typemax(Int32)` ≈ 2.1 × 10⁹, the `Int32(rhs)` truncation
silently corrupts the saturation result.

**Fix:** Widen the scratch coefficient arrays to `Vector{Int64}`, or clamp with
an explicit bounds check before converting.

---

### 1.3 `rhs_adj` accumulator can overflow Int32 in `pol_add!` — `pol.jl:33`

`rhs_adj` is declared `zero(Int32)` but accumulates many Int32 coefficient values.
If their sum exceeds `typemax(Int32)`, it wraps before being subtracted from the
Int64 `rhs` at line 70.

**Fix:** Declare `rhs_adj = zero(Int64)`.

---

## 2. Potential Crashes / Latent Panics

### 2.1 `push_frontier!` called with `j=0` for RED subproofs — `trimmer.jl:619`

`processred` always initialises `Red(w, 0:0, [])` and the range is never updated
elsewhere. When `getcone!` processes a rule of type `-10` (end-of-subproof), it does:
```julia
red = redwitness[i]
push_frontier!(frontier, on_frontier, cone, red.range.start)  # = 0
```
`cone[0]` on a 1-indexed Julia array throws `BoundsError`. This path is currently
unreachable because the parser skips `"end"` lines without pushing rule type `-10`,
so RED subproof handling is silently broken rather than actively crashing. Any future
parser extension that enables full RED subproof support will immediately crash here.

---

### 2.2 `ruptrail` reaches into `BinaryHeap` internals — `trimmer.jl:432`

```julia
empty!(rs.pq_prio.valtree); empty!(rs.pq_nonprio.valtree)
```
`valtree` is an implementation detail of `DataStructures.BinaryHeap`. If that field
is renamed or restructured in any `DataStructures.jl` update, this silently corrupts
state or throws a `FieldError`. Wrap in a helper or use a different approach to
clearing the heaps.

---

## 3. Unused / Dead Code

### 3.1 `ruptrail_bfs` — `trimmer.jl:454–522`

Explicitly marked dead code: *"DEAD CODE: BFS mode is no longer used. Kept for
historical reference."* At 70 lines with a complex multi-pass BFS algorithm, this
adds maintenance surface with zero benefit. Remove it.

### 3.2 `Dumping` module — `types.jl:2–17`

Debug serialization module left in source with `using .Dumping` commented out. The
module definition keeps a `Serialization` import in scope and leaves debug pathways
visible to readers. Move to a separate debug script if needed.

### 3.3 Rule types `-5` to `-10` are handled in `getcone!` and `writeconedel` but never emitted by the parser

The parser skips `"end"`, `"proofgoal"`, and subproof `"begin"` lines. The handling
of these rule types in the trimmer and writer is dead code until the parser is
extended, creating confusion about what proof formats are actually supported.

---

## 4. Performance Concerns

### 4.1 `update_slack_on_assign!` O(k) scan per equation — `types.jl:231–245`

For each variable assignment, for each equation containing that variable, the function
re-scans all literals of the equation to find the matching literal index. With `k`
literals per equation and `d` equations per variable, this is O(k·d). A supplementary
`var_lit_pos` map keyed by `(var, eq)` would make it O(d).

### 4.2 `init_slack_cache!` called on every RUP step — `trimmer.jl:361`

`ruptrail` calls `init_slack_cache!(t, sys)` at the start of every RUP step,
rebuilding the full slack cache from scratch. For large proofs with thousands of cone
steps this is significant. The base-trail caching used in BFS mode is the right fix
but was only applied to `Bfs`.

### 4.3 `findfullassi` naive O(n²) unit propagation — `parser.jl:372–389`

The `TODO` comment on line 375 acknowledges this. The loop re-scans all constraints
until fixpoint, quadratic in constraint count. This runs at parse time for every
`soli`/`solx` step.

---

## 5. Code Quality

### 5.1 `conflicttrail` duplicated between `Grim` and `Clit` — `trimmer.jl:160–273`

The two dispatch methods are ~100 lines each and share every line except:
- the `prio_sum`/`filter!` guard (Clit only, lines 249–258)
- the sort comparator (line 257 vs 192)

Extracting the shared loop body into a helper with the sort/filter logic passed as a
closure reduces ~100 lines of duplication to ~10.

### 5.2 Instance prefix list duplicated four times

The nine family prefixes (`"LV"`, `"bio"`, `"cviu11"`, `"pr15"`, `"mesh11"`, `"ph_"`,
`"sf_"`, `"si__"`) appear verbatim in `config.jl:44–48`, `orchestrator.jl` (OOM
monitor and `_run_main`), and `solver.jl`. Promote to a module-level constant
(a `Tuple` or `Set`) and reference it everywhere.

### 5.3 `filesize` shadows `Base.filesize` — `utilities.jl:27`

```julia
filesize(file) = stat(file).size
```
`Base.filesize(path::AbstractString)` already does exactly this. Remove the shadow
and use `Base.filesize` directly throughout.

### 5.4 `processred` inserts two entries with identical data — `parser.jl:309–310`

```julia
redwitness[redid] = Red(w, 0:0, [])
redwitness[length(store)] = Red(w, 0:0, [])
```
Two dictionary entries are created at keys `redid` and `length(store)`. When
`redid == length(store)` (edge case), the second write silently overwrites the first.
The dual-key lookup intent is not documented anywhere.

### 5.5 `pol_weaken!` uses linear search — `pol.jl:142`

```julia
i = findfirst(==(Int32(var)), vars)
```
Since equations are sorted by variable index (`readlits` calls `sort!`), this linear
scan can be replaced with `searchsortedfirst` for O(log n) lookup.

### 5.6 Uncaught OOB risk in `solvepol_flat!` — `pol.jl:252`

```julia
if !tok_in(st[j+1], ["*", "d"])
```
`j+1` is accessed inside a loop where `j` reaches `length(st)`. If the last token of
a POL step is a constraint ID, `st[j+1]` is out of bounds. A guard `j < length(st)`
is missing.

---

## 6. Minor / Style Issues

| Location | Issue |
|---|---|
| `utilities.jl:1–32` | Entire file is uniformly indented 4 spaces with no enclosing block, unlike every other file in `src/`. |
| `parser.jl:241` | `throw("trimmed SAT is the solution")` — bare string throw; use `error()`. |
| `parser.jl:345,401` | `throw(" assignement not propagated to full")` — typo ("assignement"), bare string throw. |
| `writer.jl:244` | `lastindex -= 1` / `lastindex += 1` pair inside the `-10` branch is hard to follow — the net effect depends on a `systemlink` field check that is not the same as the surrounding rule-type dispatch. Needs a comment. |
| `output.jl:358–371` | `prefixtikz`/`postfixtikz` print raw LaTeX to stdout from inside what looks like a display function; there is no documentation of what calls these or when. |
| `config.jl:37–38` | The default proof directory is derived from `abspath_base`, which is itself resolved from `ENV` or cluster detection. If `TRIMNALYSER_BASE` is set explicitly, the default proof path still changes with it implicitly — this coupling is non-obvious. |

---

## 7. Summary

| Severity | Count | Key Items |
|---|---|---|
| **Bug (wrong output)** | 3 | `~` never written in pol (`writer.jl:85`), Int32 overflow in multiply/saturate (`pol.jl:88,126`), rhs_adj overflow in add (`pol.jl:33`) |
| **Potential crash** | 2 | RED subproof `cone[0]` (`trimmer.jl:619`), heap internals access (`trimmer.jl:432`) |
| **Dead code** | 3 | `ruptrail_bfs`, `Dumping` module, rule types −5 to −10 |
| **Performance** | 3 | Slack rebuild per RUP step, O(k·d) assignment update, O(n²) soli propagation |
| **Maintainability** | 6 | `conflicttrail` duplication, duplicated prefix list, `Base.filesize` shadow, dual redwitness entries, linear weaken, OOB risk in pol tokeniser |

**Highest-priority fixes:**

1. **`writer.jl:85`** — one-character change (`!= 1` → `!= 0`); provably wrong, silently produces unverifiable proofs for any proof that weakens with a negated literal in a POL step.
2. **`pol.jl:88`** — widen coefficient arithmetic to Int64; silent overflow on large multipliers.
3. **`trimmer.jl:432`** — replace internal heap field access with a proper clear method.
