#!/usr/bin/env julia
# Aggregate .var_order files into per-instance stats and per-family similarity.
# Runs ON THE CLUSTER — reads all <instance>.var_order files from a proofs dir.
# Outputs: var_order_stats.csv (one row per instance)
#          var_order_family_summary.csv (one row per family)
#
# Usage:
#   julia scripts/aggregate_var_order.jl <proofs_dir> [output_prefix]
#
# output_prefix defaults to "var_order"; produces <prefix>_stats.csv and
# <prefix>_family_summary.csv.

function instance_family(instance)
    startswith(instance, "LV")     && return "LV"
    startswith(instance, "bio")    && return "bio"
    startswith(instance, "cviu11") && return "images-CVIU11"
    startswith(instance, "pr15")   && return "images-PR15"
    startswith(instance, "mesh11") && return "meshes-CVIU11"
    startswith(instance, "ph_")    && return "phase"
    startswith(instance, "sf_")    && return "scalefree"
    startswith(instance, "si__")   && return "si"
    return "unknown"
end

function base_instance(instance)
    m = match(r"^(.+)\.core\d+$", instance)
    m === nothing ? instance : m[1]
end

struct VarOrder
    instance::String
    family::String
    ranks::Vector{Int}   # vertex IDs sorted by count desc
    counts::Vector{Int}  # corresponding counts
end

function read_var_order(path, instance)
    ranks  = Int[]
    counts = Int[]
    for line in eachline(path)
        parts = split(line)
        length(parts) >= 2 || continue
        vid = tryparse(Int, parts[1])
        cnt = tryparse(Int, parts[2])
        vid === nothing && continue
        cnt === nothing && continue
        push!(ranks, vid)
        push!(counts, cnt)
    end
    fam = instance_family(base_instance(instance))
    VarOrder(instance, fam, ranks, counts)
end

function shannon_entropy(counts::Vector{Int})
    total = sum(counts)
    total == 0 && return 0.0
    h = 0.0
    for c in counts
        c == 0 && continue
        p = c / total
        h -= p * log2(p)
    end
    h
end

function gini(counts::Vector{Int})
    n = length(counts)
    n == 0 && return 0.0
    s = sort(counts)
    total = sum(s)
    total == 0 && return 0.0
    cum = 0.0
    for (i, c) in enumerate(s)
        cum += (2i - n - 1) * c
    end
    cum / (n * total)
end

function kendall_tau(a::VarOrder, b::VarOrder)
    shared = intersect(Set(a.ranks), Set(b.ranks))
    length(shared) < 2 && return missing
    pos_a = Dict(v => i for (i, v) in enumerate(a.ranks) if v in shared)
    pos_b = Dict(v => i for (i, v) in enumerate(b.ranks) if v in shared)
    verts = collect(shared)
    n = length(verts)
    concordant = 0
    discordant = 0
    for i in 1:n, j in (i+1):n
        u, v = verts[i], verts[j]
        da = pos_a[u] - pos_a[v]
        db = pos_b[u] - pos_b[v]
        s = sign(da) * sign(db)
        if s > 0
            concordant += 1
        elseif s < 0
            discordant += 1
        end
    end
    pairs = n * (n - 1) ÷ 2
    pairs == 0 && return missing
    (concordant - discordant) / pairs
end

const STATS_COLUMNS = [
    "instance", "family",
    "vo_n_pat",
    "vo_top1_pat", "vo_top1_count", "vo_top1_frac",
    "vo_top3_pats", "vo_top3_frac",
    "vo_rank_entropy", "vo_max_entropy",
    "vo_gini",
    "vo_total_count"
]

function compute_stats(vo::VarOrder)
    n = length(vo.ranks)
    total = sum(vo.counts)
    top1_pat   = n >= 1 ? vo.ranks[1] : -1
    top1_count = n >= 1 ? vo.counts[1] : 0
    top1_frac  = total > 0 ? top1_count / total : 0.0
    top3_pats  = join(vo.ranks[1:min(3, n)], ";")
    top3_count = sum(vo.counts[1:min(3, n)])
    top3_frac  = total > 0 ? top3_count / total : 0.0
    h = shannon_entropy(vo.counts)
    h_max = n > 1 ? log2(n) : 0.0
    g = gini(vo.counts)
    (n, top1_pat, top1_count, top1_frac, top3_pats, top3_frac, h, h_max, g, total)
end

function format_row(vo::VarOrder, stats)
    n, top1_pat, top1_count, top1_frac, top3_pats, top3_frac, h, h_max, g, total = stats
    string(
        vo.instance, ",", vo.family, ",",
        n, ",",
        top1_pat, ",", top1_count, ",",
        round(top1_frac; digits=4), ",",
        top3_pats, ",",
        round(top3_frac; digits=4), ",",
        round(h; digits=4), ",",
        round(h_max; digits=4), ",",
        round(g; digits=4), ",",
        total
    )
end

const MAX_PAIRS = 200

function family_tau_summary(family_orders::Vector{VarOrder})
    n = length(family_orders)
    n < 2 && return (n_instances=n, n_pairs=0, mean_tau=NaN, std_tau=NaN, min_tau=NaN, max_tau=NaN)
    pairs = Tuple{Int,Int}[]
    if n * (n - 1) ÷ 2 <= MAX_PAIRS
        for i in 1:n, j in (i+1):n
            push!(pairs, (i, j))
        end
    else
        seen = Set{Tuple{Int,Int}}()
        while length(pairs) < MAX_PAIRS
            i = rand(1:n)
            j = rand(1:n)
            i == j && continue
            key = i < j ? (i, j) : (j, i)
            key in seen && continue
            push!(seen, key)
            push!(pairs, key)
        end
    end
    taus = Float64[]
    for (i, j) in pairs
        t = kendall_tau(family_orders[i], family_orders[j])
        t === missing && continue
        push!(taus, t)
    end
    isempty(taus) && return (n_instances=n, n_pairs=0, mean_tau=NaN, std_tau=NaN, min_tau=NaN, max_tau=NaN)
    mt = sum(taus) / length(taus)
    st = length(taus) > 1 ? sqrt(sum((t - mt)^2 for t in taus) / (length(taus) - 1)) : 0.0
    (n_instances=n, n_pairs=length(taus), mean_tau=mt, std_tau=st, min_tau=minimum(taus), max_tau=maximum(taus))
end

# ── Main ──────────────────────────────────────────────────────────────────────

if length(ARGS) < 1
    println("Usage: julia scripts/aggregate_var_order.jl <proofs_dir> [output_prefix]")
    println("  output_prefix defaults to \"var_order\"")
    exit(1)
end

proofdir = ARGS[1]
prefix = length(ARGS) >= 2 ? ARGS[2] : "var_order"
stats_csv   = prefix * "_stats.csv"
summary_csv = prefix * "_family_summary.csv"

all_files = readdir(proofdir)
vo_files = filter(f -> endswith(f, ".var_order"), all_files)
println("Found $(length(vo_files)) .var_order files")

orders = VarOrder[]
for f in vo_files
    instance = f[1:end-length(".var_order")]
    path = joinpath(proofdir, f)
    vo = read_var_order(path, instance)
    isempty(vo.ranks) && continue
    push!(orders, vo)
end
println("Parsed $(length(orders)) non-empty var_order files")

sort!(orders, by = o -> o.instance)

open(stats_csv, "w") do io
    println(io, join(STATS_COLUMNS, ","))
    for vo in orders
        stats = compute_stats(vo)
        println(io, format_row(vo, stats))
    end
end
println("Wrote $stats_csv")

by_family = Dict{String, Vector{VarOrder}}()
for vo in orders
    push!(get!(Vector{VarOrder}, by_family, vo.family), vo)
end

open(summary_csv, "w") do io
    println(io, "family,n_instances,n_pairs,mean_tau,std_tau,min_tau,max_tau")
    for fam in sort!(collect(keys(by_family)))
        s = family_tau_summary(by_family[fam])
        println(io,
            fam, ",", s.n_instances, ",", s.n_pairs, ",",
            isnan(s.mean_tau) ? "" : round(s.mean_tau; digits=4), ",",
            isnan(s.std_tau)  ? "" : round(s.std_tau;  digits=4), ",",
            isnan(s.min_tau)  ? "" : round(s.min_tau;  digits=4), ",",
            isnan(s.max_tau)  ? "" : round(s.max_tau;  digits=4))
    end
end
println("Wrote $summary_csv")
println("=== Done ===")
