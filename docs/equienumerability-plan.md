# Trimming enumeration and equienumerability proofs

Branch `equienumerabilite`, started 2026-11-13.

Goal: trim the two sample proofs produced by Ciaran's split-components Glasgow build
(`/scratch/ciaran/split-proofs/proofs10s` on fataepyc-10, copies in
`~/veriPB/subgraphsolver/proofs/split-proofs10s/`), have VeriPB accept the trimmed proofs, then
measure how many cone literals can be trimmed.

| instance | solutions | output | conclusion |
|---|---|---|---|
| `g6-g72` | 0 | `NONE` | `ENUMERATION_COMPLETE 0 : -1` |
| `gen-s3-LV-g9` | 7956 | `EQUIENUMERABLE FILE` (`.tagged.opb`) | `NONE` |

Neither proof contains `solx` or `soli`. The count comes from the `.stmt` circuit, and the proof
rewrites the input formula into the encoding of that circuit.

## What VeriPB checks (read from `~/veripb-dev`, `d5644ca4`)

- `EQUIENUMERABLE` requires checked deletion everywhere, no solution logged, and no preserved
  variable in the domain of any witness (`Context::check_witness`).
- `output ... FILE` requires the final core set to equal the output file, both ways, and the
  final preserved set to equal the file's `preserved:` line (`rules/output.rs`).
- `preserved_add x : C` and `preserved_rm x : C` open two proof goals, `x => C` and `C => x`,
  checked with `only_core = true`. `C` may only mention variables preserved at that point.
- Checked deletion of a core constraint `D` with witness `w` opens the goal `D|w` plus one goal
  per core constraint touched by `w`, with `not D` as premise. A `: subproof ... qed : -1 ;`
  form gives the derivation explicitly.
- `red` opens goals over the whole database (core and derived) for constraints touched by the
  witness.

## Consequences for the trimmer

1. The input OPB cannot be trimmed under `EQUIENUMERABLE`, because removing an input constraint
   changes the solution count. `.smol.opb` is the whole OPB, `preserved:` line included.
2. The cone has many roots. Every constraint of the final core, every core deletion, every
   `preserved_*` step and every `core id` move is mandatory and stays in place. Only derived
   lemmas feeding them can be trimmed.
3. Constraints have a lifetime and a core/derived status. Propagation for a step may only use
   constraints alive at that step, and core-only for `preserved_*` goals.
4. Automatic `del` after last use must be limited to derived constraints.
5. Literal trimming must be off for any constraint that is, or becomes, core.

## Status, 2026-11-13

Both sample proofs trim and VeriPB (`~/veripb-dev`, 3.0.2) accepts the result.

| instance | proof | trimmed proof | proof lines | VeriPB on the trimmed proof |
|---|---|---|---|---|
| `g6-g72` | 12.8 MB | 582 KB (OPB 1.98 MB -> 573 KB) | 131,111 steps -> 5,846 | `s VERIFIED COMPLETE ENUMERATION OF 0 SOLUTIONS` |
| `gen-s3-LV-g9` | 2.04 MB | 1.14 MB (OPB unchanged) | 51,292 -> 41,395 | `s VERIFIED OUTPUT EQUIENUMERABLE` |
| `gen-s17-LV-g9` | 1.16 MB | 309 KB (OPB unchanged) | 21,850 -> 11,684 | `s VERIFIED OUTPUT EQUIENUMERABLE` |
| `gen-s3-LV-g36` | 6.68 MB | 1.54 MB (OPB unchanged) | 100,520 -> 41,802 | `s VERIFIED OUTPUT EQUIENUMERABLE` |

`gen-s3-LV-g45` has no `.pbp` (solver did not finish in 10 s).

Trim time on `gen-s3-LV-g36` (`grim TIME`): 1,648 s -> 36 s on 2026-11-14, output byte-identical.
The profile showed every assignment walking the variable's occurrence list over the whole
proof (7.8 M literals, 2,500 variables) while the constraints usable by one check are a small
live part of it. Three changes: `goal_lookup` finds a `preserved_*` goal as a core constraint
before any RUP (5,419 of 5,503 goals), as VeriPB's `autoprove` does; with database events
`ruptrail` builds an inverse index over the usable constraints of that check (`live_index!`);
the refutation path keeps the global index and stops at the check's limit. A first profile
cut at five minutes misled: the walk is backward, so it only saw the end of the proof.
`g6-g72` (refutation path) is unchanged in output and time (about 80 s).
Cone literals not needed, derived never-core class: 7,171/27,957 on `gen-s17-LV-g9`,
135,263/1,891,133 on `gen-s3-LV-g36`; blocked by the core rule: 98 and 365.

`gen-s3-LV-g9` by rule, full -> cone: rup 8,386 -> 7,105, pol 3,891 -> 771, ia 3,739 -> 394,
red 6,683 -> 6,597. Every `core`, `preserved_*`, `setlvl`, `wiplvl` and `qed` line is kept.

Cone literals on `gen-s3-LV-g9` (`grim SKEL LIT` in the log), literals the cone does not need
out of the literals of the cone constraints of each class:

| class | constraints | literals | not needed | written trimmed |
|---|---|---|---|---|
| derived, never core | 5,525 | 31,706 | 11,066 (35 %) | yes |
| moved to core | 9,342 | 21,882 | 699 | no |
| subproof premise | 2,566 | 6,101 | 449 | no |
| input (OPB) | 729 | 3,969 | 22 | no |

Levels, 2026-11-14: `writeskeleton` writes a `setlvl` lazily (just before a line that creates
a constraint) and drops a `wiplvl n` when nothing it wrote sits at a level >= n. Every kept
constraint keeps its original level. `gen-s3-LV-g36`: setlvl 5,462 -> 592, wiplvl 2,520 -> 283,
41,802 -> 34,695 lines, still `VERIFIED OUTPUT EQUIENUMERABLE` (same on the two others).

`LVg10g12` against `main` (trim only, same inputs): `.smol.pbp` byte-identical; `.smol.opb`
differs by one line, the `preserved:` line of the input, which the branch now copies.
Lazy-Glasgow OPBs do carry that line, so events are recorded for them too (+9 % memory).

Aggressive skeleton trimming, 2026-11-14 (default, `TRIM_SKEL_KEEPCORE=1` restores the old
behaviour). A core constraint deleted before the end is kept only if a check uses it; `core id`
roots only the final core; the checked deletion of a proof-born constraint is an obligation
only once the constraint is in the cone (`fire_del!`, fired when it is popped). Removing a
constraint from birth to death only removes goals for VeriPB. Goals of `del id D : w` are
classified by `witness_goals`: free when C|w holds under the literals `not D` fixes or is
syntactically implied by `not D`; a hard goal makes the whole core at that point a root.
On the three proofs every such goal is free (1,233 / 4,476 / 3,627), no fallback.

| instance | trimmed, core kept | aggressive | core constraints | `del ... : subproof` blocks |
|---|---|---|---|---|
| `gen-s17-LV-g9` | 272 KB, 8,320 lines | 264 KB, 7,890 | 1,243 -> 1,152 | 213 -> 122 |
| `gen-s3-LV-g9` | 1.07 MB, 35,743 lines | 950 KB, 28,900 | 9,342 -> 7,939 | 2,566 -> 1,163 |
| `gen-s3-LV-g36` | 1.46 MB, 34,695 lines | 1.44 MB, 33,688 | 3,296 -> 3,091 | 526 -> 321 |

All three still `VERIFIED OUTPUT EQUIENUMERABLE`. What goes is `rup` lemmas moved to the core
and deleted through a subproof without ever being used; no `red` is removed.

Per-check cost, 2026-11-14. Each check used to scan every constraint of the proof (usable set,
slack reset, queue reset), which is quadratic. `build_checkpoints!` records the live database
at intervals; `ruptrail` takes the usable constraints from the last checkpoint plus the ones
created since, and resets, initialises and indexes only those. Outputs byte-identical;
`gen-s3-LV-g36` 35 s -> 26 s, of which parsing 8 s, propagation 8 s for about 17,000 checks
(0.5 ms per check), the rest Julia start-up and compilation. Not measured on a large proof.
Memory is the next limit: the store keeps every literal of the proof (roughly 40 bytes of RAM
per byte of proof, estimated from these runs, not measured at scale).

### How it works

- `g6-g72` goes through the ordinary refutation path, rooted at the contradiction. Database
  events are parsed and ignored.
- `gen-s3-LV-g9` goes through the skeleton path (`skeleton(meta)`): `ProofMeta` records every
  database event, `build_lifetimes!` derives each constraint's death and core time, `getcone!`
  treats each event as a root (`process_event!`), `ruptrail` only uses constraints alive (and,
  for core-only goals, core) at the time of the check, and `writeskeleton` re-emits the events
  in place around the cone constraints.
- Numbering, learnt from `veripb --trace`: the negated constraint of a `del ... : subproof`
  takes the next id, inner lines follow, `qed` deletes them all and takes none.

### Not done

- Witness deletions and `red` goals are assumed trivial. They are in these two proofs (empty
  subproofs in the elaboration), and nothing re-checks it.
- In a `del id a b ;` of several core constraints, each check excludes all of them.
- `rup` hints are dropped on input and not written.
- Trim time is 33 s on a 2 MB proof (one full seeding pass per check, JIT included, not
  profiled).
- Only these two instances were run. The refutation path gives byte-identical output on
  `g6-g72` before and after the `ruptrail` change; `LVg10g12` was not re-run.

## Steps

### Step 1 — `g6-g72` (enumeration complete, zero solutions)

Essentially UNSAT. No subproofs, so constraint ids are already right.

- [x] parser: accept `core`, `preserved_add`, `preserved_rm`, `qed` without warnings
- [x] `getcone!`: root at the contradiction for `ENUMERATION_COMPLETE 0`
- [x] writer: copy the `preserved:` line into `.smol.opb`, write `output NONE` and the original
      conclusion with its hint renumbered
- [x] VeriPB accepts the trimmed proof

### Step 2 — constraint ids and subproofs

- [x] confirmed with `veripb --trace`: how ids are numbered inside a `del ... : subproof` block
- [x] parser: read `: subproof` / `qed : -1 ;`, give the negated constraint its id, record the
      block range and its owner
- [x] parser: record `del` (plain, witness, subproof), `core id`, `setlvl`/`wiplvl` as events
      with their position

### Step 3 — database model

- [x] per constraint: birth, death, core-from position
- [x] `ruptrail`: alive-at-step filter and a core-only switch
- [ ] preserved-set timeline (needed only to re-emit and to sanity-check)

### Step 4 — antecedents of the new steps

- [x] `preserved_add` / `preserved_rm`: two RUP goals, core only
- [ ] `del` with witness: goal `D|w` and one goal per core constraint touched by `w`
- [x] `del` with subproof: explicit `pol`, and `rup` scoped to the block
- [ ] `red` whose witness variable is not fresh: goals over the live database

### Step 5 — writer

- [x] whole OPB out, `preserved:` included
- [x] emit `core id`, `preserved_*`, `del` (three forms), subproof blocks, ids renumbered
- [x] derived-only automatic deletion, no literal trimming on core constraints
- [x] `output EQUIENUMERABLE FILE` / `conclusion NONE`
- [x] VeriPB accepts the trimmed `gen-s3-LV-g9` against the unchanged `.tagged.opb`

### Step 6 — measurements

- [x] cone size against proof size, split by rule kind
- [x] cone literals: how many literals are trimmed, on which constraints, and how many are
      blocked by the core rule of consequence 5

## Open points

- A deletion subproof is core-only too (`deletion.rs` sets `only_core` before the subproof,
  `rup.rs` and `cutting_planes.rs` reject a non-core id). Its own inner constraints are usable.
  The first version let inner `rup` lines use derived constraints; `gen-s3-LV-g9` passed by
  luck and `gen-s17-LV-g9` failed at a `del ... : subproof` `rup`. Fixed 2026-11-13 in
  `ruptrail` (`core_only` exempts the subproof range).
- Expected gain on `gen-s3-LV-g9`: of 51,292 lines, about 24,500 are mandatory skeleton and
  7,035 are levelled search lemmas.
