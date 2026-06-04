#!/usr/bin/env julia
# Compute static graph features for all instances in a proofs directory.
# Reads LAD files from the benchmark graph directory; outputs a CSV joinable
# to cluster_results.csv by instance name.
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

function graph_features(adj; max_diameter_n=500)
    st = basic_stats(adj)
    tri = count_triangles(adj)
    cc  = global_clustering(adj, tri)
    bip = check_bipartite(adj)
    diam, rad = diameter_radius(adj; max_n=max_diameter_n)
    (n=st.n, m=st.m, density=st.density,
     deg_min=st.deg_min, deg_max=st.deg_max, deg_mean=st.deg_mean, deg_var=st.deg_var,
     is_regular=st.is_regular, is_bipartite=bip,
     triangles=tri, clustering=cc,
     diameter=diam, radius=rad)
end

# ── CSV output ───────────────────────────────────────────────────────────────────

const GRAPH_COLS = [
    "instance",
    "pat_nodes", "pat_edges", "pat_density",
    "pat_deg_min", "pat_deg_max", "pat_deg_mean", "pat_deg_var",
    "pat_is_regular", "pat_is_bipartite",
    "pat_triangles", "pat_clustering",
    "pat_diameter", "pat_radius",
    "tar_nodes", "tar_edges", "tar_density",
    "tar_deg_min", "tar_deg_max", "tar_deg_mean", "tar_deg_var",
    "tar_is_regular", "tar_is_bipartite",
    "tar_triangles", "tar_clustering",
    "tar_diameter", "tar_radius",
]

fmt(x::Nothing) = ""
fmt(x::Bool)    = x ? "true" : "false"
fmt(x::Float64) = string(x)
fmt(x)          = string(x)

function features_row(ins, pat_f, tar_f)
    row = Any["\"$ins\""]
    for f in (pat_f, tar_f)
        push!(row, fmt(f.n), fmt(f.m), fmt(f.density),
              fmt(f.deg_min), fmt(f.deg_max), fmt(f.deg_mean), fmt(f.deg_var),
              fmt(f.is_regular), fmt(f.is_bipartite),
              fmt(f.triangles), fmt(f.clustering),
              fmt(f.diameter), fmt(f.radius))
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

    # Collect base instances (exclude .coreN files and verification files)
    all_out = filter(f -> endswith(f, ".out") &&
                          !endswith(f, ".smolverif.out") &&
                          !endswith(f, ".verif.out") &&
                          !occursin(".core", f),
                     readdir(proofs_dir))
    instances = [splitext(f)[1] for f in all_out]
    println("Found $(length(instances)) instances")

    n_ok = n_skip = n_err = 0
    open(output_csv, "w") do io
        println(io, join(GRAPH_COLS, ","))
        for (i, ins) in enumerate(instances)
            i % 500 == 0 && println("Processing $i/$(length(instances))...")
            pat_path, tar_path = instance_lad_paths(ins, graphs_dir)
            if pat_path === nothing || !isfile(pat_path) || !isfile(tar_path)
                n_skip += 1
                continue
            end
            try
                pat_f = graph_features(read_lad(pat_path))
                tar_f = graph_features(read_lad(tar_path))
                println(io, join(features_row(ins, pat_f, tar_f), ","))
                n_ok += 1
            catch e
                printstyled("  error on $ins: $e\n"; color=:red)
                n_err += 1
            end
        end
    end
    println("Done — $n_ok rows, $n_skip skipped (no LAD), $n_err errors → $output_csv")
end

main()
