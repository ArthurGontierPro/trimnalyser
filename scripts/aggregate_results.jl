#!/usr/bin/env julia
# Aggregate trimming results into a CSV file

using Printf

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

# Column names for the CSV
const CSV_COLUMNS = [
    "instance", "family",
    # Input stats
    "inp_opb_size", "inp_pbp_size", "inp_total_size",
    "inp_literals", "inp_variables",
    "inp_opb_nbeq", "inp_pbp_nbeq", "inp_total_nbeq",
    # Grim (DFS) results
    "grim_parse_time", "grim_trim_time", "grim_write_time", "grim_total_time",
    "grim_opb_cone", "grim_pbp_cone", "grim_total_cone",
    "grim_cone_literals", "grim_smol_literals", "grim_cone_variables",
    "grim_opb_size", "grim_pbp_size", "grim_total_size",
    # Gclt (clit) results
    "gclt_trim_time",
    "gclt_opb_cone", "gclt_pbp_cone", "gclt_total_cone",
    "gclt_cone_literals", "gclt_smol_literals", "gclt_cone_variables",
    # Gbfs (BFS) results
    "gbfs_trim_time",
    "gbfs_opb_cone", "gbfs_pbp_cone", "gbfs_total_cone",
    "gbfs_cone_literals", "gbfs_smol_literals", "gbfs_cone_variables",
    # Verification
    "veri_smol_time", "veri_total_time",
    "veri_opb_size", "veri_pbp_size", "veri_total_size",
    # Solver stats (if available)
    "pattern_vertices", "target_vertices", "runtime_ms", "status", "solver_nodes", "solver_propagations",
    # UNSAT core statistics (if core files exist)
    "core_pattern_nodes", "core_target_nodes", "core_pattern_total", "core_target_total",
    # Instance classification
    "is_sat", "is_unsat", "has_proof",
    "skip_reason", "proof_truncated", "truncation_reason",
    # Error tracking
    "has_error", "error_type", "error_details",
    # Resolv iterations
    "resolv_iterations",
    # Per-iteration size changes (JSON arrays for flexibility)
    "iter_sizes_total", "iter_sizes_opb", "iter_sizes_pbp",
    # Per-iteration constraint/variable/literal tracking
    "iter_nbeq", "iter_var", "iter_lit",
    # M2: step-type breakdown in trimmed cone (grim)
    "grim_cone_rup", "grim_cone_pol", "grim_cone_red", "grim_cone_ia",
    # M2: cone depth stats
    "grim_cone_depth_max", "grim_cone_depth_mean",
    # M2: cone depth distribution
    "grim_cone_depth_p50", "grim_cone_depth_p90", "grim_cone_depth_entropy",
    "grim_cone_bottom_frac", "grim_cone_bottleneck_depth",
    "grim_cone_width_max", "grim_cone_width_cv",
    "grim_rup_depth_cv",
    "grim_pol_depth_mean", "grim_pol_depth_cv",
    "grim_pol_depth_frac_bot", "grim_pol_depth_frac_top",
    "grim_pol_ante_mean", "grim_pol_ante_max", "grim_pol_opb_frac",
    "grim_pol_before_rup_burst",
    # M2: resolv shrinkage curve and stop reason
    "resolv_iter_pat_nodes", "resolv_iter_tar_nodes", "resolv_stop_reason"
]

function parse_out_file(filepath)
    data = Dict{String, Any}()
    isfile(filepath) || return data

    for line in eachline(filepath)
        # Input stats
        occursin("inp OPB SIZE ", line)      && (data["inp_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("inp PBP SIZE ", line)      && (data["inp_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("inp SIZE ", line)          && (data["inp_total_size"] = tryparse(Int, split(line)[end]))
        occursin("inp LIT ", line)           && (data["inp_literals"] = tryparse(Int, split(line)[end]))
        occursin("inp VAR ", line)           && (data["inp_variables"] = tryparse(Int, split(line)[end]))

        # Grim stats
        occursin("grim PARSE TIME ", line)   && (data["grim_parse_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim TRIM TIME ", line)    && (data["grim_trim_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim WRITE TIME ", line)   && (data["grim_write_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim TIME ", line)         && (data["grim_total_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim OPB NBEQ ", line)     && (data["inp_opb_nbeq"] = tryparse(Int, split(line)[end]))
        occursin("grim PBP NBEQ ", line)     && (data["inp_pbp_nbeq"] = tryparse(Int, split(line)[end]))
        occursin("grim NBEQ ", line)         && (data["inp_total_nbeq"] = tryparse(Int, split(line)[end]))
        # Use exact matching with regex to avoid substring conflicts
        match(r"^grim CONE LIT (\d+)", line) !== nothing   && (data["grim_cone_literals"] = tryparse(Int, match(r"^grim CONE LIT (\d+)", line).captures[1]))
        match(r"^grim CONE VAR (\d+)", line) !== nothing   && (data["grim_cone_variables"] = tryparse(Int, match(r"^grim CONE VAR (\d+)", line).captures[1]))
        match(r"^grim OPB CONE (\d+)", line) !== nothing   && (data["grim_opb_cone"] = tryparse(Int, match(r"^grim OPB CONE (\d+)", line).captures[1]))
        match(r"^grim PBP CONE (\d+)", line) !== nothing   && (data["grim_pbp_cone"] = tryparse(Int, match(r"^grim PBP CONE (\d+)", line).captures[1]))
        match(r"^grim CONE (\d+)$", line) !== nothing      && (data["grim_total_cone"] = tryparse(Int, match(r"^grim CONE (\d+)$", line).captures[1]))
        match(r"^grim SMOL LIT (\d+)", line) !== nothing   && (data["grim_smol_literals"] = tryparse(Int, match(r"^grim SMOL LIT (\d+)", line).captures[1]))
        occursin("grim OPB SIZE ", line)     && (data["grim_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("grim PBP SIZE ", line)     && (data["grim_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("grim SIZE ", line)         && (data["grim_total_size"] = tryparse(Int, split(line)[end]))

        # Gclt stats
        occursin("gclt TRIM TIME ", line)    && (data["gclt_trim_time"] = tryparse(Float64, split(line)[end]))
        match(r"^gclt CONE LIT (\d+)", line) !== nothing   && (data["gclt_cone_literals"] = tryparse(Int, match(r"^gclt CONE LIT (\d+)", line).captures[1]))
        match(r"^gclt CONE VAR (\d+)", line) !== nothing   && (data["gclt_cone_variables"] = tryparse(Int, match(r"^gclt CONE VAR (\d+)", line).captures[1]))
        match(r"^gclt OPB CONE (\d+)", line) !== nothing   && (data["gclt_opb_cone"] = tryparse(Int, match(r"^gclt OPB CONE (\d+)", line).captures[1]))
        match(r"^gclt PBP CONE (\d+)", line) !== nothing   && (data["gclt_pbp_cone"] = tryparse(Int, match(r"^gclt PBP CONE (\d+)", line).captures[1]))
        match(r"^gclt CONE (\d+)$", line) !== nothing      && (data["gclt_total_cone"] = tryparse(Int, match(r"^gclt CONE (\d+)$", line).captures[1]))
        match(r"^gclt SMOL LIT (\d+)", line) !== nothing   && (data["gclt_smol_literals"] = tryparse(Int, match(r"^gclt SMOL LIT (\d+)", line).captures[1]))

        # Gbfs stats
        occursin("gbfs TRIM TIME ", line)    && (data["gbfs_trim_time"] = tryparse(Float64, split(line)[end]))
        match(r"^gbfs CONE LIT (\d+)", line) !== nothing   && (data["gbfs_cone_literals"] = tryparse(Int, match(r"^gbfs CONE LIT (\d+)", line).captures[1]))
        match(r"^gbfs CONE VAR (\d+)", line) !== nothing   && (data["gbfs_cone_variables"] = tryparse(Int, match(r"^gbfs CONE VAR (\d+)", line).captures[1]))
        match(r"^gbfs OPB CONE (\d+)", line) !== nothing   && (data["gbfs_opb_cone"] = tryparse(Int, match(r"^gbfs OPB CONE (\d+)", line).captures[1]))
        match(r"^gbfs PBP CONE (\d+)", line) !== nothing   && (data["gbfs_pbp_cone"] = tryparse(Int, match(r"^gbfs PBP CONE (\d+)", line).captures[1]))
        match(r"^gbfs CONE (\d+)$", line) !== nothing      && (data["gbfs_total_cone"] = tryparse(Int, match(r"^gbfs CONE (\d+)$", line).captures[1]))
        match(r"^gbfs SMOL LIT (\d+)", line) !== nothing   && (data["gbfs_smol_literals"] = tryparse(Int, match(r"^gbfs SMOL LIT (\d+)", line).captures[1]))

        # Verification
        occursin("veri smol TIME ", line)    && (data["veri_smol_time"] = tryparse(Float64, split(line)[end]))
        occursin("veri TIME ", line)         && (data["veri_total_time"] = tryparse(Float64, split(line)[end]))
        occursin("veri OPB SIZE ", line)     && (data["veri_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("veri PBP SIZE ", line)     && (data["veri_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("veri SIZE ", line)         && (data["veri_total_size"] = tryparse(Int, split(line)[end]))

        # M2: step-type breakdown
        match(r"^grim CONE RUP (\d+)", line)   !== nothing && (data["grim_cone_rup"]   = tryparse(Int, match(r"^grim CONE RUP (\d+)", line).captures[1]))
        match(r"^grim CONE POL (\d+)", line)   !== nothing && (data["grim_cone_pol"]   = tryparse(Int, match(r"^grim CONE POL (\d+)", line).captures[1]))
        match(r"^grim CONE RED (\d+)", line)   !== nothing && (data["grim_cone_red"]   = tryparse(Int, match(r"^grim CONE RED (\d+)", line).captures[1]))
        match(r"^grim CONE IA (\d+)", line)    !== nothing && (data["grim_cone_ia"]    = tryparse(Int, match(r"^grim CONE IA (\d+)", line).captures[1]))
        # M2: cone depth
        match(r"^grim CONE DEPTH MAX (\d+)", line)        !== nothing && (data["grim_cone_depth_max"]  = tryparse(Int,     match(r"^grim CONE DEPTH MAX (\d+)", line).captures[1]))
        match(r"^grim CONE DEPTH MEAN ([\d.]+)", line)    !== nothing && (data["grim_cone_depth_mean"] = tryparse(Float64, match(r"^grim CONE DEPTH MEAN ([\d.]+)", line).captures[1]))
        # M2: cone depth distribution
        let m = match(r"^grim CONE DEPTH P50 (\d+)", line);         m !== nothing && (data["grim_cone_depth_p50"]         = parse(Int,     m.captures[1])); end
        let m = match(r"^grim CONE DEPTH P90 (\d+)", line);         m !== nothing && (data["grim_cone_depth_p90"]         = parse(Int,     m.captures[1])); end
        let m = match(r"^grim CONE DEPTH ENTROPY ([\d.]+)", line);  m !== nothing && (data["grim_cone_depth_entropy"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE BOTTOM FRAC ([\d.]+)", line);    m !== nothing && (data["grim_cone_bottom_frac"]       = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE BOTTLENECK DEPTH (-?\d+)", line);m !== nothing && (data["grim_cone_bottleneck_depth"]  = parse(Int,     m.captures[1])); end
        let m = match(r"^grim CONE WIDTH MAX (\d+)", line);         m !== nothing && (data["grim_cone_width_max"]         = parse(Int,     m.captures[1])); end
        let m = match(r"^grim CONE WIDTH CV ([\d.]+)", line);       m !== nothing && (data["grim_cone_width_cv"]          = parse(Float64, m.captures[1])); end
        let m = match(r"^grim RUP DEPTH CV ([\d.]+)", line);        m !== nothing && (data["grim_rup_depth_cv"]           = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL DEPTH MEAN ([\d.]+)", line);      m !== nothing && (data["grim_pol_depth_mean"]         = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL DEPTH CV ([\d.]+)", line);        m !== nothing && (data["grim_pol_depth_cv"]           = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL DEPTH FRAC BOT ([\d.]+)", line);  m !== nothing && (data["grim_pol_depth_frac_bot"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL DEPTH FRAC TOP ([\d.]+)", line);  m !== nothing && (data["grim_pol_depth_frac_top"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL ANTE MEAN ([\d.]+)", line);       m !== nothing && (data["grim_pol_ante_mean"]          = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL ANTE MAX (\d+)", line);           m !== nothing && (data["grim_pol_ante_max"]           = parse(Int,     m.captures[1])); end
        let m = match(r"^grim POL OPB FRAC ([\d.]+)", line);        m !== nothing && (data["grim_pol_opb_frac"]           = parse(Float64, m.captures[1])); end
        let m = match(r"^grim POL BURST ([01])", line);             m !== nothing && (data["grim_pol_before_rup_burst"]   = parse(Int,     m.captures[1])); end
        # M2: resolv shrinkage curve
        let m = match(r"^resolv ITER \d+ PAT (\d+) TAR (\d+)$", line)
            if m !== nothing
                push!(get!(data, "resolv_iter_pat") do; Int[] end, parse(Int, m.captures[1]))
                push!(get!(data, "resolv_iter_tar") do; Int[] end, parse(Int, m.captures[2]))
            end
        end
        let m = match(r"^resolv STOP (\w+)", line)
            m !== nothing && (data["resolv_stop_reason"] = m.captures[1])
        end

        # Brim
        occursin("brim TIME ", line)         && (data["brim_time"] = tryparse(Float64, split(line)[end]))
        occursin("brim OPB SIZE ", line)     && (data["brim_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("brim PBP SIZE ", line)     && (data["brim_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("brim SIZE ", line)         && (data["brim_total_size"] = tryparse(Int, split(line)[end]))

        # Solver stats
        occursin("pattern_vertices", line)   && (data["pattern_vertices"] = tryparse(Int, match(r"=\s*(\d+)", line).captures[1]))
        occursin("target_vertices", line)    && (data["target_vertices"] = tryparse(Int, match(r"=\s*(\d+)", line).captures[1]))
        occursin("runtime", line)            && (data["runtime_ms"] = tryparse(Int, match(r"=\s*(\d+)", line).captures[1]))
        occursin("status", line)             && (data["status"] = match(r"=\s*(\w+)", line).captures[1])
        match(r"^nodes = (\d+)", line) !== nothing && (data["solver_nodes"] = tryparse(Int, match(r"^nodes = (\d+)", line).captures[1]))
        match(r"^propagations = (\d+)", line) !== nothing && (data["solver_propagations"] = tryparse(Int, match(r"^propagations = (\d+)", line).captures[1]))
    end

    return data
end

function parse_err_file(filepath)
    isfile(filepath) || return (false, "", "")

    content = read(filepath, String)
    isempty(strip(content)) && return (false, "", "")

    # Check for OOM (monitor writes "OOM at X.XG", orchestrator writes "OOM killed (exceeded X GB)")
    m = match(r"OOM at ([\d.]+G)", content)
    m !== nothing && return (true, "OOM", m.captures[1])
    m = match(r"OOM killed \(exceeded ([\d.]+ GB)\)", content)
    m !== nothing && return (true, "OOM", m.captures[1])

    # Check for timeout
    if occursin("Timeout", content)
        m = match(r"Timeout after (\d+s)", content)
        details = m !== nothing ? m.captures[1] : "unknown"
        return (true, "Timeout", details)
    end

    # Check for trunc error
    if occursin("trunc(Int32", content)
        m = match(r"trunc\(Int32, (\d+)\)", content)
        details = m !== nothing ? "value=$(m.captures[1])" : "unknown"
        return (true, "Int32Overflow", details)
    end

    # Check for bounds error
    if occursin("BoundsError", content)
        return (true, "BoundsError", "")
    end

    # Generic error
    return (true, "Unknown", strip(content)[1:min(100, end)])
end

function count_resolv_iterations(proofdir, instance)
    n = 0
    while isfile(joinpath(proofdir, instance * ".core$(n+1)" * ".out"))
        n += 1
    end
    return n
end

# Get sizes from each iteration's .out file
function get_iteration_sizes(proofdir, instance, n_iterations)
    sizes_total = []
    sizes_opb = []
    sizes_pbp = []

    for i in 1:n_iterations
        out_file = joinpath(proofdir, instance * ".core$i" * ".out")
        if isfile(out_file)
            data = parse_out_file(out_file)
            push!(sizes_total, get(data, "grim_total_size", nothing))
            push!(sizes_opb, get(data, "grim_opb_size", nothing))
            push!(sizes_pbp, get(data, "grim_pbp_size", nothing))
        else
            push!(sizes_total, nothing)
            push!(sizes_opb, nothing)
            push!(sizes_pbp, nothing)
        end
    end

    return (sizes_total, sizes_opb, sizes_pbp)
end

# Get constraint/variable/literal counts from each iteration's .out file
function get_iteration_metrics(proofdir, instance, n_iterations)
    nbeq_list = []
    var_list = []
    lit_list = []

    for i in 1:n_iterations
        out_file = joinpath(proofdir, instance * ".core$i" * ".out")
        if isfile(out_file)
            data = parse_out_file(out_file)
            push!(nbeq_list, get(data, "inp_total_nbeq", nothing))
            push!(var_list, get(data, "inp_variables", nothing))
            push!(lit_list, get(data, "inp_literals", nothing))
        else
            push!(nbeq_list, nothing)
            push!(var_list, nothing)
            push!(lit_list, nothing)
        end
    end

    return (nbeq_list, var_list, lit_list)
end

# Parse LAD file to get node count (first line of LAD format)
function parse_lad_node_count(filepath)
    isfile(filepath) || return nothing
    try
        return parse(Int, readline(filepath))
    catch
        return nothing
    end
end

# Get UNSAT core statistics from vis/ directory LAD files
function get_core_stats(proofdir, instance)
    vis_dir = joinpath(proofdir, "vis")
    isdir(vis_dir) || return (nothing, nothing, nothing, nothing)

    core_pat = joinpath(vis_dir, instance * ".core.pat.lad")
    core_tar = joinpath(vis_dir, instance * ".core.tar.lad")
    pat = joinpath(vis_dir, instance * ".pat.lad")  # original pattern
    tar = joinpath(vis_dir, instance * ".tar.lad")  # original target

    core_pat_nodes = parse_lad_node_count(core_pat)
    core_tar_nodes = parse_lad_node_count(core_tar)
    pat_total = parse_lad_node_count(pat)
    tar_total = parse_lad_node_count(tar)

    return (core_pat_nodes, core_tar_nodes, pat_total, tar_total)
end

# Detect skip reason from .err file and missing proof data
function detect_skip_reason(err_filepath, has_proof, status_val)
    # Check if SAT
    if status_val == "SAT"
        return "SAT"
    end

    # Check err file for skip reasons
    if isfile(err_filepath)
        content = read(err_filepath, String)
        occursin("proof truncated: no conclusion", content) && return "truncated_no_conclusion"
        occursin("proof truncated: output line missing", content) && return "truncated_no_output"
        occursin("proof truncated", content) && return "truncated"
    end

    # If UNSAT but no proof, likely timed out during solve/trim
    if status_val == "UNSAT" && !has_proof
        return "no_proof_generated"
    end

    return ""
end

# Get verification file sizes from .opb.smol and .pbp.smol files
function get_verification_sizes(proofdir, instance)
    veri_opb = veri_pbp = veri_total = nothing

    # Get actual smol file sizes
    opb_smol = joinpath(proofdir, instance * ".opb.smol")
    pbp_smol = joinpath(proofdir, instance * ".pbp.smol")
    if isfile(opb_smol) && isfile(pbp_smol)
        veri_opb = filesize(opb_smol)
        veri_pbp = filesize(pbp_smol)
        veri_total = veri_opb + veri_pbp
    end

    return (veri_opb, veri_pbp, veri_total)
end

function aggregate_results(proofdir::String, output_csv::String)
    println("Scanning directory: $proofdir")

    # Find all .out files (excluding verification files)
    all_files = readdir(proofdir)
    out_files = filter(f -> endswith(f, ".out") &&
                           !endswith(f, ".smolverif.out") &&
                           !endswith(f, ".verif.out"), all_files)

    instances = [splitext(f)[1] for f in out_files]

    println("Found $(length(instances)) instances")

    # Open CSV file
    open(output_csv, "w") do io
        # Write header
        println(io, join(CSV_COLUMNS, ","))

        # Process each instance
        for (i, instance) in enumerate(instances)
            if i % 100 == 0
                println("Processing $i/$(length(instances))...")
            end

            # Parse .out file
            out_file = joinpath(proofdir, instance * ".out")
            data = parse_out_file(out_file)

            # Parse .err file
            err_file = joinpath(proofdir, instance * ".err")
            has_error, error_type, error_details = parse_err_file(err_file)

            # Count resolv iterations
            resolv_iters = count_resolv_iterations(proofdir, instance)

            # Get iteration sizes
            iter_sizes_total, iter_sizes_opb, iter_sizes_pbp = get_iteration_sizes(proofdir, instance, resolv_iters)

            # Get iteration metrics (constraints, variables, literals)
            iter_nbeq, iter_var, iter_lit = get_iteration_metrics(proofdir, instance, resolv_iters)

            # Build row
            row = []
            push!(row, "\"$instance\"")
            push!(row, "\"$(instance_family(instance))\"")

            # Input stats
            push!(row, get(data, "inp_opb_size", ""))
            push!(row, get(data, "inp_pbp_size", ""))
            push!(row, get(data, "inp_total_size", ""))
            push!(row, get(data, "inp_literals", ""))
            push!(row, get(data, "inp_variables", ""))
            push!(row, get(data, "inp_opb_nbeq", ""))
            push!(row, get(data, "inp_pbp_nbeq", ""))
            push!(row, get(data, "inp_total_nbeq", ""))

            # Grim stats
            push!(row, get(data, "grim_parse_time", ""))
            push!(row, get(data, "grim_trim_time", ""))
            push!(row, get(data, "grim_write_time", ""))
            push!(row, get(data, "grim_total_time", ""))
            push!(row, get(data, "grim_opb_cone", ""))
            push!(row, get(data, "grim_pbp_cone", ""))
            push!(row, get(data, "grim_total_cone", ""))
            push!(row, get(data, "grim_cone_literals", ""))
            push!(row, get(data, "grim_smol_literals", ""))
            push!(row, get(data, "grim_cone_variables", ""))
            push!(row, get(data, "grim_opb_size", ""))
            push!(row, get(data, "grim_pbp_size", ""))
            push!(row, get(data, "grim_total_size", ""))

            # Gclt stats
            push!(row, get(data, "gclt_trim_time", ""))
            push!(row, get(data, "gclt_opb_cone", ""))
            push!(row, get(data, "gclt_pbp_cone", ""))
            push!(row, get(data, "gclt_total_cone", ""))
            push!(row, get(data, "gclt_cone_literals", ""))
            push!(row, get(data, "gclt_smol_literals", ""))
            push!(row, get(data, "gclt_cone_variables", ""))

            # Gbfs stats
            push!(row, get(data, "gbfs_trim_time", ""))
            push!(row, get(data, "gbfs_opb_cone", ""))
            push!(row, get(data, "gbfs_pbp_cone", ""))
            push!(row, get(data, "gbfs_total_cone", ""))
            push!(row, get(data, "gbfs_cone_literals", ""))
            push!(row, get(data, "gbfs_smol_literals", ""))
            push!(row, get(data, "gbfs_cone_variables", ""))

            # Verification
            push!(row, get(data, "veri_smol_time", ""))
            push!(row, get(data, "veri_total_time", ""))
            # Get verification file sizes from actual smol files
            veri_opb, veri_pbp, veri_total = get_verification_sizes(proofdir, instance)
            push!(row, veri_opb !== nothing ? veri_opb : "")
            push!(row, veri_pbp !== nothing ? veri_pbp : "")
            push!(row, veri_total !== nothing ? veri_total : "")

            # Solver stats
            push!(row, get(data, "pattern_vertices", ""))
            push!(row, get(data, "target_vertices", ""))
            push!(row, get(data, "runtime_ms", ""))
            status_val = get(data, "status", "")
            push!(row, status_val == "" ? "" : "\"$status_val\"")
            push!(row, get(data, "solver_nodes", ""))
            push!(row, get(data, "solver_propagations", ""))

            # UNSAT core statistics
            core_pat, core_tar, pat_total, tar_total = get_core_stats(proofdir, instance)
            push!(row, core_pat !== nothing ? core_pat : "")
            push!(row, core_tar !== nothing ? core_tar : "")
            push!(row, pat_total !== nothing ? pat_total : "")
            push!(row, tar_total !== nothing ? tar_total : "")

            # Instance classification
            # is_sat: solver found SAT
            # is_unsat: solver found UNSAT
            # has_proof: proof file exists (has trimming stats)
            is_sat = (status_val == "SAT")
            is_unsat = (status_val == "UNSAT")
            has_proof = haskey(data, "grim_total_time")  # if trimmer ran, we have proof
            push!(row, is_sat ? "true" : "false")
            push!(row, is_unsat ? "true" : "false")
            push!(row, has_proof ? "true" : "false")

            # Skip reason and truncation detection
            skip_reason = detect_skip_reason(err_file, has_proof, status_val)
            proof_truncated = startswith(skip_reason, "truncated")
            truncation_reason = proof_truncated ? skip_reason : ""
            push!(row, skip_reason == "" ? "" : "\"$skip_reason\"")
            push!(row, proof_truncated ? "true" : "false")
            push!(row, truncation_reason == "" ? "" : "\"$truncation_reason\"")

            # Error tracking
            push!(row, has_error ? "true" : "false")
            push!(row, has_error ? "\"$error_type\"" : "")
            push!(row, has_error && !isempty(error_details) ? "\"$error_details\"" : "")

            # Resolv iterations
            push!(row, resolv_iters)

            # Per-iteration sizes (as JSON arrays, escaped for CSV)
            # Format: [size1,size2,size3] or empty if no iterations
            function format_array(arr)
                if isempty(arr)
                    return ""
                else
                    # Filter out nothings and format
                    vals = [v !== nothing ? string(v) : "null" for v in arr]
                    return "\"[" * join(vals, ",") * "]\""
                end
            end
            push!(row, format_array(iter_sizes_total))
            push!(row, format_array(iter_sizes_opb))
            push!(row, format_array(iter_sizes_pbp))

            # Per-iteration metrics
            push!(row, format_array(iter_nbeq))
            push!(row, format_array(iter_var))
            push!(row, format_array(iter_lit))

            # M2: step-type breakdown
            push!(row, get(data, "grim_cone_rup", ""))
            push!(row, get(data, "grim_cone_pol", ""))
            push!(row, get(data, "grim_cone_red", ""))
            push!(row, get(data, "grim_cone_ia",  ""))

            # M2: cone depth
            push!(row, get(data, "grim_cone_depth_max",  ""))
            push!(row, get(data, "grim_cone_depth_mean", ""))

            # M2: resolv shrinkage curve and stop reason
            push!(row, format_array(get(data, "resolv_iter_pat", [])))
            push!(row, format_array(get(data, "resolv_iter_tar", [])))
            stop = get(data, "resolv_stop_reason", "")
            push!(row, stop == "" ? "" : "\"$stop\"")

            # Write row
            println(io, join(row, ","))
        end
    end

    println("Done! Results written to: $output_csv")
end

# Main
if length(ARGS) < 1
    println("Usage: julia aggregate_results.jl <proofs_directory> [output_csv]")
    println()
    println("Example: julia aggregate_results.jl /home/arthur_gla/veriPB/subgraphsolver/proofs/ results.csv")
    exit(1)
end

proofdir = ARGS[1]
output_csv = length(ARGS) >= 2 ? ARGS[2] : "results.csv"

aggregate_results(proofdir, output_csv)
