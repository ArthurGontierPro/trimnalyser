# ══ Config ══════════════════════════════════════════════════════════════════════════════
mutable struct Config
    inst           ::Union{String,Nothing}
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
    trimtimeout    ::Int
    veriftimeout   ::Int
    minfreemem     ::Int
    maxinstmem_gb  ::Float64
    proofs         ::String
end

const _cfg = Ref{Config}()

const argflags = Set(["clit","core","verif","no","rand","sort","clean","atable",
                      "profile","solve","resolv","allgraphs","keepraw","subprocess"])

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
        tt,
        argval("vt=",       Int,     tt),
        argval("minmem=",   Int,     _cluster ? 100 : 4) * 1024^3,
        argval("maxmem=",   Float64, _cluster ? 50.0 : 8.0),
        proofs_dir,
    )
end
