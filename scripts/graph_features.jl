#!/usr/bin/env julia
# Compute static graph features for all instances in a proofs directory.
# Reads LAD files from the benchmark graph directory (base instances) or from
# vis/ (core instances — .coreN uses the previous iteration's core LAD files).
# Outputs a CSV joinable to cluster_results.csv by instance name.
#
# Usage:
#   julia scripts/graph_features.jl <proofs_dir> [graphs_dir] [output_csv]
#
# graphs_dir defaults to $TRIMNALYSER_GRAPHS or the local benchmark path.

const DEFAULT_GRAPHS = get(ENV, "TRIMNALYSER_GRAPHS",
    contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc") ?
    "/scratch/arthur/newSIPbenchmarks/" : "/home/arthur_gla/veriPB/newSIPbenchmarks/")

# ── LAD I/O ─────────────────────────────────────────────────────────────────────

function read_lad(path)
    adj = Vector{Vector{Int}}()
    open(path) do f
        n = parse(Int, readline(f))
        sizehint!(adj, n)
        for _ in 1:n
            parts = split(readline(f))
            push!(adj, [parse(Int, p) + 1 for p in parts[2:end]])
        end
    end
    adj
end

# ── Instance name → LAD file paths ──────────────────────────────────────────────
# Mirrors parsegraphfiles() in src/solver.jl — update both if families change.

function instance_lad_paths(ins, graphs_dir)
    g = graphs_dir
    if startswith(ins, "bio")
        pat = ins[4:end-3]; tar = ins[end-2:end]
        base = g * "biochemicalReactions/"
        return base * pat * ".txt", base * tar * ".txt"
    elseif startswith(ins, "LV")
        i = findlast('g', ins)
        base = g * "LV/"
        return base * "g" * ins[4:i-1], base * "g" * ins[i+1:end]
    elseif startswith(ins, "cviu11_p")
        m = match(r"^cviu11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "images-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "pr15_p")
        m = match(r"^pr15_p(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "images-PR15/"
        return base * "pattern" * m[1], base * "target"
    elseif startswith(ins, "mesh11_p")
        m = match(r"^mesh11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "meshes-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "ph_")
        base = g * "phase/"; bn = ins[4:end]
        return base * bn * "-pattern", base * bn * "-target"
    elseif startswith(ins, "sf_")
        base = g * "scalefree/" * ins[4:end] * "/"
        return base * "pattern", base * "target"
    elseif startswith(ins, "si__")
        parts = split(ins[5:end], "__"; limit=2)
        length(parts) != 2 && return nothing, nothing
        base = g * "si/" * parts[1] * "/" * parts[2] * "/"
        return base * "pattern", base * "target"
    end
    return nothing, nothing
end

# ── Graph metric computation ─────────────────────────────────────────────────────

function basic_stats(adj)
    n = length(adj)
    degrees = length.(adj)
    m = sum(degrees) ÷ 2
    density   = n <= 1 ? 0.0 : 2m / (n * (n - 1))
    deg_min   = n == 0 ? 0 : minimum(degrees)
    deg_max   = n == 0 ? 0 : maximum(degrees)
    deg_mean  = n == 0 ? 0.0 : sum(degrees) / n
    deg_var   = n == 0 ? 0.0 : sum((d - deg_mean)^2 for d in degrees) / n
    is_regular = n > 0 && deg_min == deg_max
    (n=n, m=m, density=density,
     deg_min=deg_min, deg_max=deg_max,
     deg_mean=round(deg_mean; digits=4), deg_var=round(deg_var; digits=4),
     is_regular=is_regular)
end

function bfs_dists(adj, src)
    n = length(adj)
    dist = fill(-1, n)
    dist[src] = 0
    q = [src]; head = 1
    while head <= length(q)
        v = q[head]; head += 1
        for u in adj[v]
            if dist[u] == -1
                dist[u] = dist[v] + 1
                push!(q, u)
            end
        end
    end
    dist
end

# Returns (diameter, radius) or (nothing, nothing) if disconnected or too large.
# Diameter = max eccentricity; radius = min eccentricity.
function diameter_radius(adj; max_n=500)
    n = length(adj)
    n == 0 && return (0, 0)
    n > max_n && return (nothing, nothing)
    ecc_max = ecc_min = -1
    for v in 1:n
        d = bfs_dists(adj, v)
        any(x -> x == -1, d) && return (nothing, nothing)  # disconnected
        e = maximum(d)
        if ecc_max == -1
            ecc_max = ecc_min = e
        else
            e > ecc_max && (ecc_max = e)
            e < ecc_min && (ecc_min = e)
        end
    end
    (ecc_max, ecc_min)
end

# Triangle count via sorted-adjacency intersection. Each triangle counted once.
function count_triangles(adj)
    n = length(adj)
    sorted = [sort(adj[v]) for v in 1:n]
    tri = 0
    for u in 1:n, v in sorted[u]
        v <= u && continue
        su = sorted[u]; sv = sorted[v]
        i = j = 1
        while i <= length(su) && j <= length(sv)
            if su[i] == sv[j]
                su[i] > v && (tri += 1)
                i += 1; j += 1
            elseif su[i] < sv[j]; i += 1
            else;                 j += 1
            end
        end
    end
    tri
end

# Global clustering coefficient: 3T / open_triplets.
function global_clustering(adj, triangles)
    open_triplets = sum(d * (d - 1) for d in length.(adj)) ÷ 2
    open_triplets == 0 && return 0.0
    round(3triangles / open_triplets; digits=6)
end

# Bipartite check via BFS 2-colouring.
function check_bipartite(adj)
    n = length(adj)
    color = fill(-1, n)
    for start in 1:n
        color[start] != -1 && continue
        color[start] = 0
        q = [start]; head = 1
        while head <= length(q)
            v = q[head]; head += 1
            for u in adj[v]
                if color[u] == -1
                    color[u] = 1 - color[v]
                    push!(q, u)
                elseif color[u] == color[v]
                    return false
                end
            end
        end
    end
    true
end

# ── Per-graph feature bundle ─────────────────────────────────────────────────────

# Girth via BFS from every node: O(V*(V+E)). Returns nothing if too large, -1 if acyclic.
function compute_girth(adj; max_n=500)
    n = length(adj)
    n < 3   && return -1
    n > max_n && return nothing
    girth  = typemax(Int)
    dist   = Vector{Int}(undef, n)
    parent = Vector{Int}(undef, n)
    queue  = Vector{Int}(undef, n)
    for src in 1:n
        fill!(dist, -1); fill!(parent, 0)
        dist[src] = 0; queue[1] = src; head = 1; tail = 1
        while head <= tail
            u = queue[head]; head += 1
            for v in adj[u]
                if dist[v] == -1
                    dist[v] = dist[u] + 1; parent[v] = u
                    tail += 1; queue[tail] = v
                elseif v != parent[u]
                    girth = min(girth, dist[u] + dist[v] + 1)
                    girth == 3 && return 3
                end
            end
        end
    end
    girth == typemax(Int) ? -1 : girth
end

function graph_features(adj; max_diameter_n=500)
    st = basic_stats(adj)
    tri = count_triangles(adj)
    cc  = global_clustering(adj, tri)
    bip = check_bipartite(adj)
    diam, rad = diameter_radius(adj; max_n=max_diameter_n)
    girth = compute_girth(adj; max_n=max_diameter_n)
    (n=st.n, m=st.m, density=st.density,
     deg_min=st.deg_min, deg_max=st.deg_max, deg_mean=st.deg_mean, deg_var=st.deg_var,
     is_regular=st.is_regular, is_bipartite=bip,
     triangles=tri, clustering=cc,
     diameter=diam, radius=rad, girth=girth,
     _degrees=length.(adj))
end

# Per-instance relational features (pattern vs target).
function relational_features(pf, tf)
    node_ratio     = round(pf.n / tf.n; digits=4)
    density_ratio  = tf.density > 0 ? round(pf.density / tf.density; digits=4) : nothing
    max_deg_ratio  = tf.deg_max > 0 ? round(pf.deg_max / tf.deg_max; digits=4) : nothing
    diam_ratio     = (pf.diameter !== nothing && tf.diameter !== nothing &&
                      pf.diameter > 0 && tf.diameter > 0) ?
                         round(pf.diameter / tf.diameter; digits=4) : nothing
    compat         = count(d <= tf.deg_max for d in pf._degrees)
    deg_compat_frac = round(compat / pf.n; digits=4)
    (node_ratio=node_ratio, density_ratio=density_ratio,
     max_degree_ratio=max_deg_ratio, diameter_ratio=diam_ratio,
     degree_compat_frac=deg_compat_frac)
end

# ── CSV output ───────────────────────────────────────────────────────────────────

const GRAPH_FEATURE_NAMES = [
    "nodes", "edges", "density",
    "deg_min", "deg_max", "deg_mean", "deg_var",
    "is_regular", "is_bipartite",
    "triangles", "clustering",
    "diameter", "radius", "girth",
]

const GRAPH_COLS = vcat(
    ["instance"],
    ["pat_$c" for c in GRAPH_FEATURE_NAMES],
    ["tar_$c" for c in GRAPH_FEATURE_NAMES],
    ["node_ratio", "density_ratio", "max_degree_ratio", "diameter_ratio",
     "degree_compat_frac"],
    ["core_pat_$c" for c in GRAPH_FEATURE_NAMES],
    ["core_tar_$c" for c in GRAPH_FEATURE_NAMES],
    ["core_node_ratio", "core_density_ratio", "core_max_degree_ratio",
     "core_diameter_ratio", "core_degree_compat_frac"],
    ["core_pat_node_shrink", "core_tar_node_shrink",
     "core_pat_density_shift", "core_tar_density_shift"],
)

fmt(x::Nothing) = ""
fmt(x::Bool)    = x ? "true" : "false"
fmt(x::Float64) = string(x)
fmt(x)          = string(x)

function push_graph_features!(row, f)
    push!(row, fmt(f.n), fmt(f.m), fmt(f.density),
          fmt(f.deg_min), fmt(f.deg_max), fmt(f.deg_mean), fmt(f.deg_var),
          fmt(f.is_regular), fmt(f.is_bipartite),
          fmt(f.triangles), fmt(f.clustering),
          fmt(f.diameter), fmt(f.radius), fmt(f.girth))
end

function push_relational!(row, rf)
    push!(row, fmt(rf.node_ratio), fmt(rf.density_ratio), fmt(rf.max_degree_ratio),
          fmt(rf.diameter_ratio), fmt(rf.degree_compat_frac))
end

function push_empty!(row, n)
    for _ in 1:n; push!(row, ""); end
end

function safe_ratio(a, b)
    (a === nothing || b === nothing || b == 0) ? nothing : round(a / b; digits=4)
end

function features_row(ins, pat_f, tar_f, core_pat_f, core_tar_f)
    row = Any["\"$ins\""]
    push_graph_features!(row, pat_f)
    push_graph_features!(row, tar_f)
    rf = relational_features(pat_f, tar_f)
    push_relational!(row, rf)
    n_feat = length(GRAPH_FEATURE_NAMES)
    if core_pat_f !== nothing && core_tar_f !== nothing
        push_graph_features!(row, core_pat_f)
        push_graph_features!(row, core_tar_f)
        crf = relational_features(core_pat_f, core_tar_f)
        push_relational!(row, crf)
        push!(row,
              fmt(safe_ratio(core_pat_f.n, pat_f.n)),
              fmt(safe_ratio(core_tar_f.n, tar_f.n)),
              fmt(core_pat_f.density - pat_f.density |> x -> round(x; digits=6)),
              fmt(core_tar_f.density - tar_f.density |> x -> round(x; digits=6)))
    else
        push_empty!(row, 2 * n_feat + 5 + 4)
    end
    row
end

# ── Main ─────────────────────────────────────────────────────────────────────────

function main()
    if length(ARGS) < 1
        println("Usage: julia graph_features.jl <proofs_dir> [graphs_dir] [output_csv]")
        exit(1)
    end

    proofs_dir  = ARGS[1]
    graphs_dir  = length(ARGS) >= 2 && isdir(ARGS[2]) ? ARGS[2] : DEFAULT_GRAPHS
    output_csv  = length(ARGS) >= 3 ? ARGS[3] :
                  (length(ARGS) >= 2 && !isdir(ARGS[2]) ? ARGS[2] : "graph_features.csv")

    endswith(graphs_dir, "/") || (graphs_dir *= "/")

    println("Proofs dir : $proofs_dir")
    println("Graphs dir : $graphs_dir")
    println("Output     : $output_csv")

    # Collect all instances (base + .coreN), excluding verification files
    all_out = filter(f -> endswith(f, ".out") &&
                          !endswith(f, ".smolverif.out") &&
                          !endswith(f, ".verif.out"),
                     readdir(proofs_dir))
    instances = [splitext(f)[1] for f in all_out]
    println("Found $(length(instances)) instances")

    vis_dir = joinpath(proofs_dir, "vis")

    n_ok = n_skip = n_err = n_core = 0
    open(output_csv, "w") do io
        println(io, join(GRAPH_COLS, ","))
        for (i, ins) in enumerate(instances)
            i % 500 == 0 && println("Processing $i/$(length(instances))...")

            # Resolve pattern/target LAD paths.
            # For .coreN instances, the graphs come from vis/ (previous iteration's core).
            pat_path = tar_path = nothing
            m = match(r"^(.+)\.core(\d+)$", ins)
            if m !== nothing
                base, n = m.captures[1], parse(Int, m.captures[2])
                prev_ins = n == 1 ? base : base * ".core$(n-1)"
                pat_path = joinpath(vis_dir, prev_ins * ".core.pat.lad")
                tar_path = joinpath(vis_dir, prev_ins * ".core.tar.lad")
            else
                pat_path, tar_path = instance_lad_paths(ins, graphs_dir)
            end

            if pat_path === nothing || !isfile(pat_path) || !isfile(tar_path)
                n_skip += 1
                continue
            end
            try
                pat_f = graph_features(read_lad(pat_path))
                tar_f = graph_features(read_lad(tar_path))
                core_pat_f = core_tar_f = nothing
                cp = joinpath(vis_dir, ins * ".core.pat.lad")
                ct = joinpath(vis_dir, ins * ".core.tar.lad")
                if isfile(cp) && isfile(ct)
                    core_pat_f = graph_features(read_lad(cp))
                    core_tar_f = graph_features(read_lad(ct))
                    n_core += 1
                end
                println(io, join(features_row(ins, pat_f, tar_f, core_pat_f, core_tar_f), ","))
                n_ok += 1
            catch e
                printstyled("  error on $ins: $e\n"; color=:red)
                n_err += 1
            end
        end
    end
    println("Done — $n_ok rows ($n_core with core features), $n_skip skipped (no LAD), $n_err errors → $output_csv")
end

main()
