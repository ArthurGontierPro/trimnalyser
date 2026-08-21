#!/usr/bin/env julia
# Structure and encoding cost of Glasgow's supplemental graphs, per benchmark graph.
#
#   julia scripts/supplemental_stats.jl ~/newSIPbenchmarks/LV supplemental_stats.csv [g77 g84 ...]
#
# RUN ON THE COMPUTE NODE. This is dense linear algebra on up to 6671x6671 matrices;
# it saturates every core it is given and must never be run on the laptop.
#
# Definitions transcribed from gss/innards/supplemental_graphs.cc:
#   exact_path_p : edge (v,w) iff |N(v) & N(w)| >= p, for p = 1..NEP
#   distance3    : edge (v,w) iff dist(v,w) <= 3
#
# WHICH ONES ARE ACTUALLY BUILT (make_shape_graph_plan, homomorphism_model.cc:71, and the
# supports_* guards in homomorphism_traits.cc):
#   exact_path : built whenever supplementals are on and injectivity != NonInjective,
#                with number_of_exact_path_graphs = 4 by default (homomorphism.hh:80).
#   distance2  : ONLY when exact_path is unavailable, so never for SIP.
#   distance3  : requires params.distance3, i.e. the --distance3 flag. OFF by default.
#   k4         : requires params.k4, i.e. --k4. OFF by default.
# `runsipsolver` (src/solver.jl:158) passes only --no-clique-detection --staged --format lad,
# so **our runs build exact_path_1..4 and nothing else**. distance3 is computed here for
# reference only and must NOT be counted in the cost model.
#
# The cost columns are the size of the adjacency encoding that the proof log streams.
# For supplemental graph k, one clause per (pattern edge of P_k, target vertex t, direction):
#     x[p,t] -> OR over t' in N_k(t) of x[q,t']            width deg_k(t)+1
# so the target-side factor is sum_t (deg_k(t)+1) = 2|E(T_k)| + n, which is `cost_direct`.
# Written against the complement instead, using exactly-one on q:
#     for each t' not in N_k(t):  x[p,t] + x[q,t'] <= 1    width 2
# giving `cost_compl` = 2 * sum_t (n-1-deg_k(t)). Whichever is smaller is `cost_best`.
#
# Subsumption elision (prove_exact_path_graphs, default on) emits, per ORDERED pattern pair,
# only the highest exact-path index whose pattern edge holds — the narrowest target set. So
# `kept_p` counts the ordered pattern pairs whose highest index is exactly p, and the encoding
# cost of an instance is  sum_p kept_p(P) * cost_direct_p(T).

using LinearAlgebra, Printf

"Read a LAD file into a symmetric Bool adjacency matrix with no self-loops."
function readlad(path::AbstractString)
    tok = split(read(path, String))
    n = parse(Int, tok[1])
    A = falses(n, n)
    i = 2
    for v in 1:n
        d = parse(Int, tok[i]); i += 1
        for j in i:(i + d - 1)
            A[v, parse(Int, tok[j]) + 1] = true    # LAD is 0-indexed
        end
        i += d
    end
    A .|= A'
    for v in 1:n; A[v, v] = false; end
    return A
end

"Boolean matrix product via BLAS: `(X*Y) .> 0`, in Float32."
boolmul(X::AbstractMatrix{Bool}, Y::AbstractMatrix{Bool}) =
    (Float32.(X) * Float32.(Y)) .> 0.5f0

"Common-neighbour counts C[v,w] = |N(v) & N(w)|, diagonal zeroed."
function commonneighbours(A::AbstractMatrix{Bool})
    n = size(A, 1)
    C = round.(Int32, Float32.(A) * Float32.(A))
    for v in 1:n; C[v, v] = 0; end
    return C
end

"True iff E is a disjoint union of cliques (E plus the diagonal is transitive)."
function isequivalence(E::AbstractMatrix{Bool})
    n = size(E, 1)
    R = copy(E); for v in 1:n; R[v, v] = true; end
    return boolmul(R, R) == R
end

"All the per-supplemental-graph numbers for one graph."
function graphstats(A::AbstractMatrix{Bool})
    n = size(A, 1)
    npairs = n * (n - 1)
    C = commonneighbours(A)

    R = copy(A); for v in 1:n; R[v, v] = true; end
    D3 = boolmul(boolmul(R, R), R)
    for v in 1:n; D3[v, v] = false; end

    supp = Pair{String,BitMatrix}[]
    for p in 1:NEP
        push!(supp, "ep$p" => BitMatrix(C .>= Int32(p)))
    end
    push!(supp, "d3" => BitMatrix(D3))

    st = Dict{String,Any}("n" => n, "m" => count(A) ÷ 2,
                          "dens" => count(A) / npairs)
    # ordered pattern pairs whose highest exact-path index is exactly p (what elision keeps);
    # a pair with more than NEP common neighbours still tops out at index NEP.
    for p in 1:NEP
        st["kept$p"] = count(C .== Int32(p)) + (p == NEP ? count(C .> Int32(NEP)) : 0)
    end
    for (k, E) in supp
        degsum = count(E)                       # = sum_t deg_k(t)
        st["$(k)_m"] = degsum ÷ 2
        st["$(k)_dens"] = degsum / npairs
        # supplemental edges that are not already edges of G: with clustering 0 this is 1.0,
        # i.e. the supplemental graph adds a whole second graph rather than thickening G.
        st["$(k)_new_frac"] = count(E .& .!A) / max(degsum, 1)
        st["$(k)_cost_direct"] = float(degsum + n)
        st["$(k)_cost_compl"] = float(2 * (npairs - degsum))
        st["$(k)_cost_best"] = min(st["$(k)_cost_direct"], st["$(k)_cost_compl"])
        st["$(k)_is_equiv"] = isequivalence(E)
    end
    # How many of exact_path_1..NEP are literally the same constraint set.
    st["ep_distinct"] = length(unique([supp[p].second for p in 1:NEP]))
    return st
end

const NEP = 4          # number_of_exact_path_graphs, homomorphism.hh:80

const COLS = vcat(["graph", "n", "m", "dens"],
    [ "$(k)_$(f)" for k in vcat(["ep$p" for p in 1:NEP], ["d3"])
                  for f in ("m", "dens", "new_frac", "cost_direct", "cost_compl",
                            "cost_best", "is_equiv") ],
    ["kept$p" for p in 1:NEP], ["ep_distinct"])

function main()
    length(ARGS) >= 2 || error("usage: julia supplemental_stats.jl <bench_dir> <out.csv> [graphs...]")
    dir, out = ARGS[1], ARGS[2]
    graphs = length(ARGS) > 2 ? ARGS[3:end] : sort(readdir(dir))
    @printf("BLAS threads: %d, graphs: %d\n", BLAS.get_num_threads(), length(graphs))

    open(out, "w") do io
        println(io, join(COLS, ","))
        for (i, g) in enumerate(graphs)
            p = joinpath(dir, g)
            isfile(p) || continue
            t0 = time()
            A = readlad(p)
            st = graphstats(A)
            st["graph"] = g
            println(io, join([string(st[c]) for c in COLS], ","))
            flush(io)
            @printf("[%3d/%3d] %-6s n=%-5d m=%-8d ep1_dens=%.3f d3_dens=%.3f ep_distinct=%d  (%.1fs)\n",
                    i, length(graphs), g, st["n"], st["m"], st["ep1_dens"], st["d3_dens"],
                    st["ep_distinct"], time() - t0)
        end
    end
    println("wrote $out")
end

main()
