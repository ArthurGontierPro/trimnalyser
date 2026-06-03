# ══ Config ══════════════════════════════════════════════════════════════════════════════
mutable struct Config
    inst           ::Union{String,Nothing}
    bfs            ::Bool
    clit           ::Bool
    atable         ::Bool
    clean          ::Bool
    rand           ::Bool
    sort_by_size   ::Bool
    verif          ::Bool
    profile        ::Bool
    nonorm         ::Bool
    core           ::Bool
    solve          ::Bool
    resolv         ::Bool
    allgraphs      ::Bool
    pack           ::Bool
    render         ::Bool
    overwrite      ::Bool
    nosup          ::Bool
    maxnodes       ::Int
    solvertimeout  ::Int
    trimtimeout    ::Int
    minfreemem     ::Int
    maxinstmem_gb  ::Float64
    proofs         ::String
end

const _cfg = Ref{Config}()

const argflags = Set(["bfs","clit","core","verif","no","rand","sort","clean","atable",
                      "profile","solve","resolv","allgraphs"])

function parse_config!(args=ARGS)
    argval(prefix, T, default) = (i = findfirst(x -> startswith(x, prefix), args);
                                   i !== nothing ? parse(T, args[i][length(prefix)+1:end]) : default)
    defaultproofs = _cluster ? "/scratch/arthur/proofs/" : abspath_base*"proofs/"
    proofs_dir = begin
        i = findfirst(x -> isdir(x), args)
        i !== nothing ? args[i] : defaultproofs
    end
    inst_val = begin
        i = findfirst(x -> isfile(proofs_dir*x*pbp) && isfile(proofs_dir*x*opb), args)
        i === nothing && (i = findfirst(x -> !isdir(x) && (startswith(x,"LV") || startswith(x,"bio")), args))
        i !== nothing ? args[i] : nothing
    end
    _cfg[] = Config(
        inst_val,
        "bfs"              in args,
        "clit"             in args,
        "atable"           in args,
        "clean"            in args,
        "rand"             in args,
        "sort"             in args,
        "verif"            in args,
        "profile"          in args,
        "no"               in args,
        "core"             in args,
        "solve"            in args,
        "resolv"           in args,
        "allgraphs"        in args,
        "pack"             in args,
        "render"           in args,
        "overwrite"        in args,
        "no-supplementals" in args,
        argval("maxnodes=", Int,     typemax(Int)),
        argval("st=",       Int,     5),
        argval("tt=",       Int,     45),
        argval("minmem=",   Int,     _cluster ? 100 : 4) * 1024^3,
        argval("maxmem=",   Float64, _cluster ? 50.0 : 8.0),
        proofs_dir,
    )
end
