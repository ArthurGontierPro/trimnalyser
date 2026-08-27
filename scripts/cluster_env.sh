# ══════════════════════════════════════════════════════════════════════════════════════
# Pins every binary the pipeline resolves through the environment. SOURCE it, don't run it.
#
#     source scripts/cluster_env.sh
#
# Why this file exists: `gssbin(rev)` (src/config.jl) reads $GLASGOW_SUBGRAPH_SOLVER_<rev>
# and falls back to the single global binary when it is unset. The fallback is SILENT — an
# unset variable does not fail a run, it produces a table column that measures the wrong
# revision. Nine of the fourteen columns pin a revision, so eight of them were duplicates
# of gss-lazy until this file was sourced. bench_config.sh sources it automatically.
#
# The dict in src/config.jl is a `const` built at module load, so these must be exported
# BEFORE julia starts. Sourcing it after launching a run has no effect.
#
# Everything points into node-local /scratch: $HOME and /cluster are shared NFS, and the
# solver reads the benchmark graphs on every instance. Populate a node with setup_node.sh.
# ══════════════════════════════════════════════════════════════════════════════════════

: "${SCRATCH:=/scratch/arthur}"
export SCRATCH

# Every pin below is `:=`, not `=`: a value already exported on the command line WINS.
# bench_config.sh has always documented that ("Values already exported win, so an explicit
# override on the command line still takes effect") but plain `export VAR=...` made it
# false, so `CAKE_PB=/path/to/fixed ... bench_config.sh` silently ran the old binary. An
# unset variable still resolves to the /scratch default, so the anti-fallback guarantee
# that this file exists for is unchanged.

# The three pinned Glasgow revisions. Keep in sync with `gssbin(...)` in src/config.jl;
# scripts/cluster_dist.sh greps the same list out of that file, so they cannot drift.
: "${GLASGOW_SUBGRAPH_SOLVER_2180663:=$SCRATCH/glasgow_subgraph_solver_2180663}"
export GLASGOW_SUBGRAPH_SOLVER_2180663
: "${GLASGOW_SUBGRAPH_SOLVER_39ca857:=$SCRATCH/glasgow_subgraph_solver_39ca857}"
export GLASGOW_SUBGRAPH_SOLVER_39ca857
: "${GLASGOW_SUBGRAPH_SOLVER_1ff87ba:=$SCRATCH/glasgow_subgraph_solver_1ff87ba}"
export GLASGOW_SUBGRAPH_SOLVER_1ff87ba

# The un-suffixed fallback. Deliberately the same file as 1ff87ba (= gss-lazy, the default
# config) so that an unpinned code path degrades to the documented default rather than to
# whatever was built last.
: "${GLASGOW_SUBGRAPH_SOLVER:=$SCRATCH/glasgow_subgraph_solver}"
export GLASGOW_SUBGRAPH_SOLVER

: "${LAD_SOLVER:=$SCRATCH/lad}"
export LAD_SOLVER
: "${VERIPB:=$SCRATCH/veripb}"
export VERIPB
: "${CAKE_PB:=$SCRATCH/cake_pb}"
export CAKE_PB
: "${CAKE_PB_ISO:=$SCRATCH/cake_pb_iso}"
export CAKE_PB_ISO
: "${TRIMNALYSER_GRAPHS:=$SCRATCH/newSIPbenchmarks/}"
export TRIMNALYSER_GRAPHS

# TRAILING SLASHES ARE LOAD-BEARING on the two directory variables below. The code
# concatenates without a separator (`SIPgraphpath * family * "/" * name`, `logroot * ins`),
# and the defaults in src/TrimAnalyser.jl end in "/". Omitting it here produced
# "/scratch/arthur/newSIPbenchmarksLV/g10: unable to open file" — the solver failing on
# every instance, reported as "did not conclude in 60s".
#
# Logs must NOT be node-local: they are the run's only surviving record once the proof
# tree is deleted, and a nine-node run has to aggregate into one place.
export TRIMNALYSER_LOGS="${TRIMNALYSER_LOGS:-/cluster/arthur/logs/}"
