# ══ Solver configuration grid (M7) ══════════════════════════════════════════════════════
# One entry per column of the paper's appendix tables (tab:configs-gss,
# tab:configs-gss-ablations, tab:configs-lad). `binary` lets configurations that differ
# only by solver revision coexist; `proves` marks the ones that log a proof at all.
struct SolverConfig
    kind   ::String            # "gss" | "lad"
    binary ::String
    flags  ::Vector{String}
    proves ::Bool
end

    # Per-revision binary override: $GLASGOW_SUBGRAPH_SOLVER_<rev>, else the single global.
gssbin(rev) = get(ENV, "GLASGOW_SUBGRAPH_SOLVER_" * rev, sipsolverpath)

const _gss_base = ["--staged", "--no-clique-detection"]

# ══════════════════════════════════════════════════════════════════════════════════════
# WHICH REVISION IS WHICH — read this before adding, re-pinning or quoting a column.
#
# Exactly two Glasgow builds may appear as a proof-logging column of the paper. Both
# carry the NDS proof-witness fix; anything that does not carry it must never reach a
# table, because without it Glasgow emits its neighbourhood-degree-sequence elimination
# lemmas as bare `rup` steps that no checker can replay.
#
#   PAPER COLUMN       REV       BRANCH HEAD                  IS
#   default logging    861a84f   labels-for-analysis          2180663 + NDS fix
#   lazy logging       1ff87ba   lazy-adjacency-relabelled    39ca857 + 4 commits + NDS fix
#                                                             (68b1c9b memory, f75a30e
#                                                              level-collapse, a1c412b,
#                                                              dffc858, then the NDS fix)
#
# The ablation grid varies one switch against `gss-lazy` (1ff87ba), so the ablation
# table's baseline column and tab:configs-gss's lazy column are the SAME measurement.
#
# HISTORICAL — pre-NDS-fix, kept only so old logs stay attributable. Never a paper
# column, never a comparison baseline: 2180663, 39ca857.
# SCAFFOLD — 84f1d3e is 39ca857 + the NDS fix alone. It exists to isolate that fix in an
# A/B and is not a paper column either; the fix's effect is recorded, the arm is done.
#
# Still unfixed anywhere: the @binback witness (Proof::backtrack_from_binary_variables),
# reachable only with clique detection on, so it bites `gss-lazy-cliques` and nothing
# else. Its column reports a real solver limitation, not a broken run.
# ══════════════════════════════════════════════════════════════════════════════════════
const SOLVER_CONFIGS = Dict{String,SolverConfig}(
    # ── tab:configs-gss. The two no-logging columns emit no proof, so the NDS fix cannot
    #    reach them and they stay on 2180663.
    "gss"            => SolverConfig("gss", gssbin("2180663"), String[],                                    false),
    "gss-noclique"   => SolverConfig("gss", gssbin("2180663"), ["--no-clique-detection"],                   false),
    "gss-default"    => SolverConfig("gss", gssbin("861a84f"), _gss_base,                                   true),
    "gss-lazy"       => SolverConfig("gss", gssbin("1ff87ba"), _gss_base,                                   true),
    # ── tab:configs-gss-ablations. One switch each against `gss-lazy`, same binary, so the
    #    baseline column IS gss-lazy and the two tables share it.
    "gss-lazy-nostaged"   => SolverConfig("gss", gssbin("1ff87ba"), ["--no-clique-detection"],              true),
    "gss-lazy-nosupp"     => SolverConfig("gss", gssbin("1ff87ba"), [_gss_base; "--no-supplementals"],      true),
    "gss-lazy-norestarts" => SolverConfig("gss", gssbin("1ff87ba"), [_gss_base; "--restarts"; "none"],      true),
    "gss-lazy-cliques"    => SolverConfig("gss", gssbin("1ff87ba"), [_gss_base; "--cliques"],               true),
    # ── HISTORICAL. Pre-NDS-fix builds and the A/B arm that isolated the fix. Kept so the
    #    logs already on disk stay attributable to a named configuration; a run of one is
    #    a deliberate act, never a paper column. See the header above.
    "gss-proof"      => SolverConfig("gss", gssbin("2180663"), _gss_base,                                   true),
    "gss-lazy-base"  => SolverConfig("gss", gssbin("39ca857"), _gss_base,                                   true),
    "gss-nostaged"   => SolverConfig("gss", gssbin("39ca857"), ["--no-clique-detection"],                   true),
    "gss-nosupp"     => SolverConfig("gss", gssbin("39ca857"), [_gss_base; "--no-supplementals"],           true),
    "gss-norestarts" => SolverConfig("gss", gssbin("39ca857"), [_gss_base; "--restarts"; "none"],           true),
    "gss-cliques"    => SolverConfig("gss", gssbin("39ca857"), [_gss_base; "--cliques"],                    true),
    "gss-proof-nds"      => SolverConfig("gss", gssbin("861a84f"), _gss_base,                               true),
    "gss-lazy-base-nds"  => SolverConfig("gss", gssbin("84f1d3e"), _gss_base,                               true),
    "gss-nostaged-nds"   => SolverConfig("gss", gssbin("84f1d3e"), ["--no-clique-detection"],               true),
    "gss-nosupp-nds"     => SolverConfig("gss", gssbin("84f1d3e"), [_gss_base; "--no-supplementals"],       true),
    "gss-norestarts-nds" => SolverConfig("gss", gssbin("84f1d3e"), [_gss_base; "--restarts"; "none"],       true),
    "gss-cliques-nds"    => SolverConfig("gss", gssbin("84f1d3e"), [_gss_base; "--cliques"],                true),
    # ── tab:configs-lad (M7.5; bio is hard-excluded for every lad-* key) ──
    "lad"            => SolverConfig("lad", ladsolverpath, ["-f", "2", "-c", "4"],                          false),
    "lad-clique"     => SolverConfig("lad", ladsolverpath, ["-f", "0", "-c", "2"],                          false),
    "lad-noclique"   => SolverConfig("lad", ladsolverpath, ["-f", "0", "-c", "0"],                          false),
    # `proves` alone selects proof logging: runladsolver supplies -P/-O with the file
    # names, so the bare -P must NOT appear here (it takes a FILE argument).
    "lad-alldiff-pl" => SolverConfig("lad", ladsolverpath, ["-f", "0", "-c", "0"],                          true),
    "lad-fc-pl"      => SolverConfig("lad", ladsolverpath, ["-f", "1", "-c", "0"],                          true),
)

const default_config = "gss-lazy"   # current hardcoded behaviour: --staged --no-clique-detection --prove

    # The active entry. Flags additionally carry the legacy `no-supplementals` arg.
solverconfig() = SOLVER_CONFIGS[_cfg[].config]

    # The append-only per-instance log. It lives OUTSIDE the proof tree: the proof
    # directory is deleted at last use, and the record must survive that. One file per
    # (instance, solver, configuration) so configurations never overwrite each other.
logpath(ins) = logroot * ins * "." * solverconfig().kind * "." * _cfg[].config * ".out"
logopen(f, ins) = open(f, logpath(ins), "a")

    # The solver's own stdout. Stays in the proof directory and is truncated per solve:
    # the SAT/UNSAT verdict is grepped out of it, so it must never carry a previous run's.
solveroutpath(ins) = _cfg[].proofs * ins * ".solverout"

    # Opens a run in the append-only log. Every re-run of any configuration appends its own
    # block, so a partial cluster run stays readable and no configuration destroys another's
    # record. Readers take the LAST block.
function runheader(ins)
    logopen(ins) do f
        println(f, "=== RUN ", Base.Libc.strftime("%Y-%m-%dT%H:%M:%S", time()),
                   " ", gethostname(), " ", _cfg[].config, " ===")
        # bio graphs are DIRECTED. LAD reads them as undirected without warning, so its
        # verdict answers a different question than Glasgow's (on bio 001->002 Glasgow
        # says SAT and LAD says UNSAT), and CakePB rejects the encoding outright so the
        # row can never be verified either. Stamped inside the run block, not inferred
        # from the instance name, so a reader who has only the log still cannot average
        # these into a solver comparison by accident. † in tab:configs-lad.
        solverconfig().kind == "lad" && startswith(ins, "bio") &&
            println(f, "lad VALIDITY DIRECTED_UNSOUND")
    end
end

    # One greppable KEY SUBKEY VALUE line, so a table cell can be filled from the log alone.
logstage(ins, key, val) = logopen(ins) do f; println(f, key, " ", val) end
solverflags()  = _cfg[].nosup && "--no-supplementals" ∉ solverconfig().flags ?
                     [solverconfig().flags; "--no-supplementals"] : solverconfig().flags

# ══ Config ══════════════════════════════════════════════════════════════════════════════
mutable struct Config
    inst           ::Union{String,Nothing}
    clit           ::Bool
    atable         ::Bool
    clean          ::Bool
    rand           ::Bool
    sort_by_size   ::Bool
    verif          ::Bool
    cake           ::Bool
    profile        ::Bool
    nonorm         ::Bool
    core           ::Bool
    solve          ::Bool
    resolv         ::Bool
    allgraphs      ::Bool
    instfile       ::Union{String,Nothing}
    pack           ::Bool
    render         ::Bool
    overwrite      ::Bool
    nosup          ::Bool
    keepraw        ::Bool
    subprocess     ::Bool
    minnodes       ::Int
    maxnodes       ::Int
    solvertimeout  ::Int
    nopltimeout    ::Int
    trimtimeout    ::Int
    veriftimeout   ::Int
    caketimeout    ::Int
    minfreemem     ::Int
    mindiskfree    ::Int
    maxinstmem_gb  ::Float64
    proofs         ::String
    config         ::String
end

const _cfg = Ref{Config}()

const argflags = Set(["clit","core","verif","cake","no","rand","sort","clean","atable",
                      "profile","solve","resolv","allgraphs","keepraw","subprocess"])

function parse_config!(args=ARGS)
    argval(prefix, T, default) = (i = findfirst(x -> startswith(x, prefix), args);
                                   i !== nothing ? parse(T, args[i][length(prefix)+1:end]) : default)
    config_val = let i = findfirst(x -> startswith(x, "config="), args)
        i === nothing ? default_config : String(args[i][8:end])
    end
    haskey(SOLVER_CONFIGS, config_val) ||
        error("unknown config=$config_val — valid keys: " * join(sort(collect(keys(SOLVER_CONFIGS))), ", "))
    # Namespaced per configuration: two configurations of one instance must not collide
    # on <ins>.opb in a single flat directory.
    proofroot     = _cluster ? "/scratch/arthur/proofs/" : abspath_base*"proofs/"
    defaultproofs = proofroot * SOLVER_CONFIGS[config_val].kind * "/" * config_val * "/"
    proofs_dir = begin
        i = findfirst(x -> isdir(x), args)
        # every path is built as proofs*ins*ext, so a dir given without its trailing
        # slash silently writes <dir><ins>.opb *beside* the directory instead of in it.
        i !== nothing ? (endswith(args[i], "/") ? args[i] : args[i] * "/") : defaultproofs
    end
    inst_val = begin
        i = findfirst(x -> isfile(proofs_dir*x*pbp) && isfile(proofs_dir*x*opb), args)
        i === nothing && (i = findfirst(x -> !isdir(x) && is_instance_name(x), args))
        i !== nothing ? args[i] : nothing
    end
    tt = argval("tt=", Int, 45)
    instfile_val = let i = findfirst(x -> startswith(x, "instfile="), args)
        i !== nothing ? String(args[i][10:end]) : nothing
    end
    _cfg[] = Config(
        inst_val,
        "clit"             in args,
        "atable"           in args,
        "clean"            in args,
        "rand"             in args,
        "sort"             in args,
        "verif"            in args,
        "cake"             in args,
        "profile"          in args,
        "no"               in args,
        "core"             in args,
        "solve"            in args,
        "resolv"           in args,
        "allgraphs"        in args,
        instfile_val,
        "pack"             in args,
        "render"           in args,
        "overwrite"        in args,
        "no-supplementals" in args,
        "keepraw"          in args,
        "subprocess"       in args,
        argval("minnodes=", Int,     0),
        argval("maxnodes=", Int,     typemax(Int)),
        argval("st=",       Int,     5),
        argval("stnopl=",   Int,     60),
        tt,
        argval("vt=",       Int,     tt),
        argval("ct=",       Int,     argval("vt=", Int, tt)),
        argval("minmem=",   Int,     _cluster ? 100 : 4) * 1024^3,
        # Disk admission gate. Sibling of minmem=, and for the same reason: nothing else
        # protects the node's DISK. LAD proofs carry no deletions and grow with search
        # length, so a full-benchmark LAD run writes proofs that are orders of magnitude
        # larger than Glasgow's, and ninety threads each holding one can fill /scratch
        # between two polls of anything coarser. 0 disables.
        argval("mindisk=",  Int,     _cluster ? 300 : 0) * 1024^3,
        argval("maxmem=",   Float64, _cluster ? 50.0 : 8.0),
        proofs_dir,
        config_val,
    )
    mkpath(_cfg[].proofs)
    mkpath(logroot)
    return _cfg[]
end
