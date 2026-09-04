# `veripb trim` cannot resolve a label that a *proof step* introduced, when it is used as an `ia` hint

Branch `feature_trimmer`, tip `e98c4a31` ("Fix duplicate attachment during autoproving.",
2026-08-11). Reproduced today, 2026-09-04.

## Summary

`veripb trim` rejects, at parse time, a proof that `veripb` (main, 3.0.2) verifies:

```
Error: Syntax error while parsing proof file!

Caused by:
    The label `@g2adj6_3_1` is not assigned to a constraint ID at line 5195 col 133.
    @g1adj6_3_1 ia 1 ~x6_3 1 x1_1 ... >= 1 : @g2adj6_3_1
                                             ^^^^^^^^^^^
```

`@g2adj6_3_1` is defined **two lines earlier**, at 5193.

The evidence below points at one specific gap: **the hint-list parser for `ia` resolves
labels against the formula's label table only. A label introduced by a proof step is
invisible to it.** The `pol` operand parser resolves both, which is why the same proof
gets 5,000 lines in before this shows up.

## Reproducing

```
veripb_ft trim LVg10g22.opb LVg10g22.pbp LVg10g22.ft.opb -e LVg10g22.ft.pbp
```

`LVg10g22.first5195.pbp` in this bundle is the proof truncated to the failing line — the
failure is at parse time, so nothing after line 5195 is needed, and it is 331 KB instead
of 19 MB. It fails identically.

## The four lines

```
5192  setlvl 0;
5193  @g2adj6_3_1 ia 1 ~x6_3 1 x1_1 ... >= 1 : 13828 ;
5194  wiplvl 1;
5195  @g1adj6_3_1 ia 1 ~x6_3 1 x1_1 ... >= 1 : @g2adj6_3_1 ;
```

## What we ruled out, and what is left

Four experiments, in the order we ran them.

**1. It is not the level change.** Deleting line 5194 (`wiplvl 1;`) changes nothing — the
label defined on the immediately preceding line is still unresolved:

```
$ sed '5194d' LVg10g22.first5195.pbp > no-wiplvl.pbp
$ veripb_ft trim LVg10g22.opb no-wiplvl.pbp -e /tmp/out.pbp
    The label `@g2adj6_3_1` is not assigned to a constraint ID at line 5194 col 133.
```

**2. It is not labels-in-hints in general.** Replacing the hint with a label the *formula*
defines makes the error disappear; parsing then runs to the end of the truncated file:

```
$ sed '5195s/: @g2adj6_3_1 ;/: @adj6_3_0 ;/' LVg10g22.first5195.pbp > swap.pbp
$ veripb_ft trim LVg10g22.opb swap.pbp -e /tmp/out.pbp
    Expected a top level rule name or `output` but found end of file (EOF) at line 5196 col 1.
```
`@adj6_3_0` is in `LVg10g22.opb`; `@g2adj6_3_1` is not.

**3. It is not proof-defined labels in general either.** A proof-defined label used as a
`pol` operand resolves fine, 2,000 lines earlier in the same file:

```
3013  @g2adj0_2_2 ia 1 ~x0_2 >= 1 : 11918 ;      <- defined by a proof step
3016  @elimdegpol0_2 pol @g2adj0_2_2 @inj2 + s ; <- used as a pol operand, accepted
```

**4. Line 5195 is the first place in this proof where a proof-defined label is used as a
hint.** There are 675 `: @…` hint references in the file and the trimmer never reaches the
second one. So this is not a rare corner — it is the first occurrence of the pattern.

Putting 2, 3 and 4 together: `pol` operands resolve against both tables, `ia` hints resolve
against the formula's table only.

## Cross-check: `feature/trimmer-base` does not have this bug

The same proof, same machine, `feature/trimmer-base` @ `af219d36`:

```
$ veripb_tb trim LVg10g22.opb LVg10g22.pbp -e LVg10g22.tb.pbp
Running VeriPB version 3.0.2
s VERIFIED UNSATISFIABLE
```

So the rewrite already handles it. Reporting it against `feature_trimmer` in case that
branch is still the one being maintained, and because the two resolve differently.

## Where the proof comes from

The Glasgow subgraph solver (`--staged --no-clique-detection --prove`) on the LV
subgraph-isomorphism instance `LVg10g22` — pattern `LV/g10` into target `LV/g22`, UNSAT. 199,072 proof lines,
144,333 labelled steps, 38,411 `setlvl`/`wiplvl`. Nothing exotic — it is our default
configuration, and we are running 171 instances through both trimmers right now. We are
happy to send the failure counts and any other instance that trips it.

## A separate, much smaller observation

`trim` accepts an `output_formula` positional but never writes it on any of our proofs, so
the trimmed proof stays against the full original `.opb`. Is problem reformulation simply
not implemented for `trim` yet? We ask because it decides how we count "size of the
certificate" when we compare trimmers — model + proof, or proof alone. (In
`feature/trimmer-base` the positional is on `check` only, which suggests the answer is
"not for trim".)

## Bundle contents

| file | |
|---|---|
| `LVg10g22.opb` | the formula, 1.0 MB |
| `LVg10g22.first5195.pbp` | proof truncated to the failing line, 331 KB — reproduces on its own |
| `LVg10g22.pbp` | the full proof, 19 MB (in the `-full` archive only) |
| `transcript.txt` | every command above with its actual output, and the version strings |
