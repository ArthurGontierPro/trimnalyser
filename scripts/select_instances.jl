#!/usr/bin/env julia
# Stratified sampling of representative UNSAT instances from cluster_results.csv + graph_features.csv.
# Produces instances.txt with "pattern_path\ttarget_path" per line.
#
# Axes: family, proof_size, rule_archetype, label_diversity, node_ratio, search_intensity
#
# Usage:
#   julia --project=scripts scripts/select_instances.jl cluster_results.csv graph_features.csv [instances.txt] [--per-stratum N] [--seed S]

using CSV, DataFrames, Statistics, Random

# ── CLI args ──────────────────────────────────────────────────────────────────

const results_csv  = ARGS[1]
const features_csv = ARGS[2]
const outfile       = length(ARGS) >= 3 && !startswith(ARGS[3], "-") ? ARGS[3] : "instances.txt"
global per_stratum = 3
global seed = 42
for a in ARGS
    m = match(r"^--per-stratum[= ]?(\d+)$", a)
    m !== nothing && (global per_stratum = parse(Int, m[1]))
    m = match(r"^--seed[= ]?(\d+)$", a)
    m !== nothing && (global seed = parse(Int, m[1]))
end

# ── Graph path resolution (mirrors src/solver.jl:parsegraphfiles) ─────────

const SIPgraphpath = get(ENV, "TRIMNALYSER_GRAPHS",
    contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc") ?
        "/scratch/arthur/newSIPbenchmarks/" : "/home/arthur_gla/veriPB/newSIPbenchmarks/")

function parsegraphfiles(ins::AbstractString)
    if startswith(ins, "bio")
        pat = ins[4:end-3]; tar = ins[end-2:end]
        base = SIPgraphpath * "biochemicalReactions/"
        return base * pat * ".txt", base * tar * ".txt"
    elseif startswith(ins, "LV")
        i = findlast('g', ins)
        pat = ins[4:i-1]; tar = ins[i+1:end]
        base = SIPgraphpath * "LV/"
        return base * "g" * pat, base * "g" * tar
    elseif startswith(ins, "cviu11_p")
        m = match(r"^cviu11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = SIPgraphpath * "images-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "pr15_p")
        m = match(r"^pr15_p(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = SIPgraphpath * "images-PR15/"
        return base * "pattern" * m[1], base * "target"
    elseif startswith(ins, "mesh11_p")
        m = match(r"^mesh11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = SIPgraphpath * "meshes-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "ph_")
        base_name = ins[4:end]
        base = SIPgraphpath * "phase/"
        return base * base_name * "-pattern", base * base_name * "-target"
    elseif startswith(ins, "sf_")
        dir = ins[4:end]
        base = SIPgraphpath * "scalefree/" * dir * "/"
        return base * "pattern", base * "target"
    elseif startswith(ins, "si__")
        parts = split(ins[5:end], "__"; limit=2)
        length(parts) != 2 && return nothing, nothing
        group, inst = parts[1], parts[2]
        base = SIPgraphpath * "si/" * group * "/" * inst * "/"
        return base * "pattern", base * "target"
    end
    return nothing, nothing
end

# ── Load & filter ─────────────────────────────────────────────────────────────

println("Loading CSVs...")
df = CSV.read(results_csv, DataFrame; stringtype=String)
gf = CSV.read(features_csv, DataFrame; stringtype=String)

for col in [:instance, :family]
    hasproperty(df, col) && (df[!, col] = replace.(df[!, col], "\"" => ""))
end
hasproperty(gf, :instance) && (gf[!, :instance] = replace.(gf[!, :instance], "\"" => ""))

filter!(r -> r.has_proof == true || r.has_proof == "true", df)
filter!(r -> !contains(r.instance, ".core"), df)

# Exclude instances with corrupted fraction data.
# grim_{rule}_frac uses grim_total_cone (opb+pbp) as denominator, so they do NOT sum to 1 when
# OPB constraints appear in the cone.  Use raw counts / grim_pbp_cone instead.
let pbp = coalesce.(df.grim_pbp_cone, 0)
    df[!, :_rule_sum] = coalesce.(df.grim_cone_rup, 0) .+ coalesce.(df.grim_cone_pol, 0) .+
                        coalesce.(df.grim_cone_ia, 0)  .+ coalesce.(df.grim_cone_red, 0)
    n_before = nrow(df)
    filter!(r -> coalesce(r.grim_pbp_cone, 0) > 0 &&
                 0.99 < r._rule_sum / r.grim_pbp_cone < 1.01, df)
    println("  $(nrow(df)) clean base UNSAT instances (dropped $(n_before - nrow(df)) with corrupt fracs)")
end

df = leftjoin(df, gf; on=:instance)
println("  $(count(!ismissing, df.node_ratio)) with graph features")

# ── Axis 1: family (as-is) ───────────────────────────────────────────────────

# ── Axis 2: proof size (grim_total_cone quartiles) ───────────────────────────

cone_vals = coalesce.(df.grim_total_cone, 0)
cone_qs = quantile(cone_vals, [0.25, 0.5, 0.75])
df[!, :size_bin] = map(cone_vals) do v
    v <= cone_qs[1] ? "small" : v <= cone_qs[2] ? "medium" : v <= cone_qs[3] ? "large" : "huge"
end

# ── Axis 3: rule archetype (from counts normalised by grim_pbp_cone) ──────────
# Use raw counts / pbp_cone so OPB constraints in the cone don't dilute the fracs.

function rule_archetype(row)
    pbp = coalesce(row.grim_pbp_cone, 0)
    pbp == 0 && return "pol_only"
    rf  = coalesce(row.grim_cone_rup, 0) / pbp
    pf  = coalesce(row.grim_cone_pol, 0) / pbp
    iaf = coalesce(row.grim_cone_ia,  0) / pbp
    pf > 0.8  ? "pol_heavy" :
    iaf > 0.3 ? (pf > 0.3 ? "pol_ia_mix" : "ia_heavy") :
    rf > 0.05 ? "has_rup" :
                "pol_only"
end
df[!, :archetype] = [rule_archetype(r) for r in eachrow(df)]

# ── Axis 4: label diversity ─────────────────────────────────────────────────

label_abs_cols = [c for c in names(df) if startswith(c, "grim_cone_") &&
                  !startswith(c, "grim_cone_frac_") &&
                  c ∉ ("grim_cone_rup", "grim_cone_pol", "grim_cone_red", "grim_cone_ia",
                       "grim_total_cone", "grim_opb_cone", "grim_pbp_cone",
                       "grim_cone_variables", "grim_cone_literals", "grim_smol_literals") &&
                  !contains(c, "depth") && !contains(c, "width") &&
                  !contains(c, "literal") && !contains(c, "uniq") &&
                  !contains(c, "bottom") && !contains(c, "bottleneck")]
println("  $(length(label_abs_cols)) label columns for diversity")

function count_labels(row)
    n = 0
    for c in label_abs_cols
        v = getproperty(row, Symbol(c))
        (!ismissing(v) && v isa Number && v > 0) && (n += 1)
    end
    n
end
df[!, :label_div] = [count_labels(r) for r in eachrow(df)]
df[!, :label_div_bin] = map(df.label_div) do n
    n <= 3 ? "ldiv_1-3" : n <= 6 ? "ldiv_4-6" : n <= 10 ? "ldiv_7-10" : "ldiv_11+"
end

# ── Axis 5: node ratio (pattern/target) ─────────────────────────────────────

df[!, :ratio_bin] = map(eachrow(df)) do row
    r = row.node_ratio
    (ismissing(r) || r === nothing) ? "unknown" :
    r <= 0.15 ? "tiny_pat" : r <= 0.4 ? "small_pat" : r <= 0.7 ? "balanced" : "large_pat"
end

# ── Axis 6: search intensity (guess + nogood / cone) ────────────────────────

df[!, :search_frac] = map(eachrow(df)) do row
    cone = coalesce(row.grim_total_cone, 0)
    cone == 0 && return 0.0
    g = coalesce(row.grim_cone_guess, 0)
    n = coalesce(row.grim_cone_nogood, 0)
    clamp((g + n) / cone, 0.0, 1.0)
end
df[!, :search_bin] = map(df.search_frac) do sf
    sf < 1e-6 ? "no_search" : sf < 0.01 ? "light_search" : sf < 0.1 ? "mod_search" : "heavy_search"
end

# ── Stratified sampling ──────────────────────────────────────────────────────

strat_cols = [:family, :size_bin, :archetype, :label_div_bin, :ratio_bin, :search_bin]

gdf = groupby(df, strat_cols)
println("\n$(length(gdf)) non-empty strata from $(nrow(df)) instances")

for col in strat_cols
    counts = combine(groupby(df, col), nrow => :n)
    sort!(counts, col)
    println("\n  $col:")
    for r in eachrow(counts)
        println("    $(r[col]): $(r.n)")
    end
end

rng = MersenneTwister(seed)

selected = DataFrame()
for (_, sub) in pairs(gdf)
    n = min(per_stratum, nrow(sub))
    idx = randperm(rng, nrow(sub))[1:n]
    append!(selected, sub[idx, :])
end
unique!(selected, :instance)

println("\n$(nrow(selected)) instances selected across $(length(gdf)) strata")

println("\nCoverage:")
for col in strat_cols
    bins = sort(unique(selected[!, col]))
    counts = [count(==(b), selected[!, col]) for b in bins]
    println("  $col: $(join(["$b($c)" for (b,c) in zip(bins, counts)], ", "))")
end

# ── Write instances.txt ──────────────────────────────────────────────────────

open(outfile, "w") do io
    resolved = 0
    for ins in sort(selected.instance)
        pat, tar = parsegraphfiles(ins)
        if pat === nothing
            @warn "Cannot resolve paths for $ins — skipping"
            continue
        end
        println(io, pat, "\t", tar)
        resolved += 1
    end
    println("\nWrote $resolved instance paths to $outfile")
end

# ── Diagnostic CSV ────────────────────────────────────────────────────────────

diag_file = replace(outfile, r"\.[^.]+$" => "") * "_strata.csv"
diag_cols = vcat(:instance, :family, strat_cols[2:end], :label_div, :search_frac,
                 :grim_total_cone, :grim_rup_frac, :grim_pol_frac, :grim_ia_frac, :grim_red_frac,
                 :grim_cone_guess, :grim_cone_nogood)
diag_df = selected[:, diag_cols]
sort!(diag_df, :instance)
CSV.write(diag_file, diag_df)
println("Wrote stratum diagnostic to $diag_file")
