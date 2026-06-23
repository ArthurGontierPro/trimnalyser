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
    "veri_smol_verified",
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
    # M3.5.7: full-proof step types
    "grim_full_rup", "grim_full_pol", "grim_full_red", "grim_full_ia",
    # M2: cone depth stats
    "grim_cone_depth_max", "grim_cone_depth_mean",
    # M3.5.7: full-proof depth stats
    "grim_full_depth_max", "grim_full_depth_mean",
    # M2: cone depth distribution
    "grim_cone_depth_p50", "grim_cone_depth_p90", "grim_cone_depth_entropy",
    "grim_cone_bottom_frac", "grim_cone_bottleneck_depth",
    "grim_cone_width_max", "grim_cone_width_cv",
    "grim_cone_rup_depth_cv",
    "grim_cone_pol_depth_mean", "grim_cone_pol_depth_cv",
    "grim_cone_pol_depth_frac_bot", "grim_cone_pol_depth_frac_top",
    "grim_cone_pol_ante_mean", "grim_cone_pol_ante_max", "grim_cone_pol_opb_frac",
    "grim_cone_pol_before_rup_burst",
    # M3.5.7: full-proof depth distribution
    "grim_full_depth_p50", "grim_full_depth_p90", "grim_full_depth_entropy",
    "grim_full_bottom_frac",
    "grim_full_width_max", "grim_full_width_cv",
    "grim_full_rup_depth_cv",
    "grim_full_pol_depth_mean", "grim_full_pol_depth_cv",
    "grim_full_pol_ante_mean", "grim_full_pol_ante_max", "grim_full_pol_opb_frac",
    "grim_full_pol_before_rup_burst",
    # M2: step-type fractions (derived from counts / pbp_cone)
    "grim_rup_frac", "grim_pol_frac", "grim_ia_frac", "grim_red_frac",
    # M3.5.7: full step-type fractions
    "grim_full_rup_frac", "grim_full_pol_frac", "grim_full_ia_frac", "grim_full_red_frac",
    # M2: literal compression
    "grim_literal_weakening_rate",
    # M2: resolv shrinkage curve and stop reason
    "resolv_iter_pat_nodes", "resolv_iter_tar_nodes", "resolv_stop_reason",
    # M2: resolv total shrinkage (derived)
    "resolv_pat_shrinkage", "resolv_tar_shrinkage",
    # M3.5: CP constraint provenance — cone counts
    "grim_cone_al1", "grim_cone_am1", "grim_cone_inj",
    "grim_cone_g0adj", "grim_cone_g1adj", "grim_cone_g2adj", "grim_cone_g3adj", "grim_cone_gadj_other",
    "grim_cone_forb", "grim_cone_noedge",
    "grim_cone_elimdegpol", "grim_cone_elimdeg",
    "grim_cone_elimndspol", "grim_cone_elimndsconc", "grim_cone_elimnds",
    "grim_cone_loop",
    "grim_cone_ptbig", "grim_cone_hall",
    "grim_cone_prop", "grim_cone_guess", "grim_cone_nogood",
    "grim_cone_pathg1", "grim_cone_pathg2", "grim_cone_pathg3", "grim_cone_pathg_other",
    "grim_cone_d2g1", "grim_cone_d2g2", "grim_cone_d2g3", "grim_cone_d2g_other",
    "grim_cone_d3g1", "grim_cone_d3g2", "grim_cone_d3g3", "grim_cone_d3g_other",
    "grim_cone_reelimdegpol", "grim_cone_reelimdeg",
    "grim_cone_reelimndspol", "grim_cone_reelimndsconc",
    "grim_cone_unsatconc",
    "grim_cone_binback", "grim_cone_colpol",
    "grim_cone_hombd", "grim_cone_hompol", "grim_cone_hominj",
    "grim_cone_homdom", "grim_cone_homfin", "grim_cone_homcross",
    "grim_cone_mcspart", "grim_cone_mcsfin",
    "grim_cone_notconn", "grim_cone_cliqedge",
    "grim_cone_unlabeled",
    # M3.5.7: full-proof label counts
    "grim_full_al1", "grim_full_am1", "grim_full_inj",
    "grim_full_g0adj", "grim_full_g1adj", "grim_full_g2adj", "grim_full_g3adj", "grim_full_gadj_other",
    "grim_full_forb", "grim_full_noedge",
    "grim_full_elimdegpol", "grim_full_elimdeg",
    "grim_full_elimndspol", "grim_full_elimndsconc", "grim_full_elimnds",
    "grim_full_loop",
    "grim_full_ptbig", "grim_full_hall",
    "grim_full_prop", "grim_full_guess", "grim_full_nogood",
    "grim_full_pathg1", "grim_full_pathg2", "grim_full_pathg3", "grim_full_pathg_other",
    "grim_full_d2g1", "grim_full_d2g2", "grim_full_d2g3", "grim_full_d2g_other",
    "grim_full_d3g1", "grim_full_d3g2", "grim_full_d3g3", "grim_full_d3g_other",
    "grim_full_reelimdegpol", "grim_full_reelimdeg",
    "grim_full_reelimndspol", "grim_full_reelimndsconc",
    "grim_full_unsatconc",
    "grim_full_binback", "grim_full_colpol",
    "grim_full_hombd", "grim_full_hompol", "grim_full_hominj",
    "grim_full_homdom", "grim_full_homfin", "grim_full_homcross",
    "grim_full_mcspart", "grim_full_mcsfin",
    "grim_full_notconn", "grim_full_cliqedge",
    "grim_full_unlabeled",
    # M3.5: CP constraint provenance (fractions of OPB cone)
    "grim_cone_frac_inj", "grim_cone_frac_g0adj",
    "grim_cone_frac_g1adj", "grim_cone_frac_g2adj", "grim_cone_frac_g3adj",
    "grim_cone_frac_forb", "grim_cone_frac_noedge",
    "grim_cone_frac_elimdegpol", "grim_cone_frac_elimnds", "grim_cone_frac_elimdeg",
    "grim_cone_frac_hall",
    "grim_cone_frac_prop", "grim_cone_frac_guess", "grim_cone_frac_nogood",
    "grim_cone_frac_pathg1", "grim_cone_frac_pathg2", "grim_cone_frac_pathg3", "grim_cone_frac_pathg_other",
    "grim_cone_frac_d2g1", "grim_cone_frac_d2g2", "grim_cone_frac_d2g3", "grim_cone_frac_d2g_other",
    "grim_cone_frac_d3g1", "grim_cone_frac_d3g2", "grim_cone_frac_d3g3", "grim_cone_frac_d3g_other",
    # M3.5: variable order — cone and full
    "grim_cone_uniq_pat", "grim_cone_uniq_tar",
    "grim_full_uniq_pat", "grim_full_uniq_tar"
]

function _parse_frac(s)
    p = findfirst('/', s)
    p === nothing && return (tryparse(Int, s), nothing)
    (tryparse(Int, s[1:p-1]), tryparse(Int, s[p+1:end]))
end

function _parse_frac_label(line)
    tok = split(line)[end]
    _parse_frac(tok)
end

const _LABEL_NAMES = [
    "AL1", "AM1", "INJ", "G0ADJ", "FORB", "NOEDGE",
    "ELIMDEGPOL", "ELIMDEG", "ELIMNDS",
    "G1ADJ", "G2ADJ", "G3ADJ",
    "REELIMDEGPOL", "REELIMDEG", "REELIMNDSPOL", "REELIMNDSCONC",
    "UNSATCONC", "GADJ_OTHER", "ELIMNDSPOL", "ELIMNDSCONC",
    "LOOP", "PTBIG", "HALL", "PROP", "GUESS", "NOGOOD",
    "PATHG1", "PATHG2", "PATHG3", "PATHG_OTHER",
    "D2G1", "D2G2", "D2G3", "D2G_OTHER",
    "D3G1", "D3G2", "D3G3", "D3G_OTHER",
    "BINBACK", "COLPOL",
    "HOMBD", "HOMPOL", "HOMINJ", "HOMDOM", "HOMFIN", "HOMCROSS",
    "MCSPART", "MCSFIN", "NOTCONN", "CLIQEDGE"
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

        # Grim timing
        occursin("grim PARSE TIME ", line)   && (data["grim_parse_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim TRIM TIME ", line)    && (data["grim_trim_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim WRITE TIME ", line)   && (data["grim_write_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim TIME ", line)         && (data["grim_total_time"] = tryparse(Float64, split(line)[end]))
        occursin("grim OPB SIZE ", line)     && (data["grim_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("grim PBP SIZE ", line)     && (data["grim_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("grim SIZE ", line)         && (data["grim_total_size"] = tryparse(Int, split(line)[end]))

        # M3.5.7 fraction format: grim OPB cone/total, grim PBP cone/total, grim NBEQ cone/total
        let m = match(r"^grim OPB (\d+/\d+)$", line)
            if m !== nothing
                a, b = _parse_frac(m.captures[1])
                data["grim_opb_cone"] = a; data["inp_opb_nbeq"] = b
            end
        end
        let m = match(r"^grim PBP (\d+/\d+)$", line)
            if m !== nothing
                a, b = _parse_frac(m.captures[1])
                data["grim_pbp_cone"] = a; data["inp_pbp_nbeq"] = b
            end
        end
        let m = match(r"^grim NBEQ (\d+/\d+)$", line)
            if m !== nothing
                a, b = _parse_frac(m.captures[1])
                data["grim_total_cone"] = a; data["inp_total_nbeq"] = b
            end
        end

        # Step type fractions: grim RUP cone/full, etc.
        let m = match(r"^grim RUP (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_rup"] = a; data["grim_full_rup"] = b; end
        end
        let m = match(r"^grim POL (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_pol"] = a; data["grim_full_pol"] = b; end
        end
        let m = match(r"^grim RED (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_red"] = a; data["grim_full_red"] = b; end
        end
        let m = match(r"^grim IA (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_ia"] = a; data["grim_full_ia"] = b; end
        end

        # Depth — cone and full (parallel lines)
        let m = match(r"^grim CONE DEPTH MAX (\d+)", line); m !== nothing && (data["grim_cone_depth_max"] = parse(Int, m.captures[1])); end
        let m = match(r"^grim FULL DEPTH MAX (\d+)", line); m !== nothing && (data["grim_full_depth_max"] = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE DEPTH MEAN ([\d.]+)", line); m !== nothing && (data["grim_cone_depth_mean"] = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL DEPTH MEAN ([\d.]+)", line); m !== nothing && (data["grim_full_depth_mean"] = parse(Float64, m.captures[1])); end

        # Cone depth distribution
        let m = match(r"^grim CONE DEPTH P50 (\d+)", line);         m !== nothing && (data["grim_cone_depth_p50"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE DEPTH P90 (\d+)", line);         m !== nothing && (data["grim_cone_depth_p90"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE DEPTH ENTROPY ([\d.]+)", line);  m !== nothing && (data["grim_cone_depth_entropy"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE BOTTOM FRAC ([\d.]+)", line);    m !== nothing && (data["grim_cone_bottom_frac"]       = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE BOTTLENECK DEPTH (-?\d+)", line);m !== nothing && (data["grim_cone_bottleneck_depth"]  = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE WIDTH MAX (\d+)", line);         m !== nothing && (data["grim_cone_width_max"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE WIDTH CV ([\d.]+)", line);       m !== nothing && (data["grim_cone_width_cv"]          = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE RUP DEPTH CV ([\d.]+)", line);   m !== nothing && (data["grim_cone_rup_depth_cv"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL DEPTH MEAN ([\d.]+)", line); m !== nothing && (data["grim_cone_pol_depth_mean"]    = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL DEPTH CV ([\d.]+)", line);   m !== nothing && (data["grim_cone_pol_depth_cv"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL DEPTH FRAC BOT ([\d.]+)", line); m !== nothing && (data["grim_cone_pol_depth_frac_bot"] = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL DEPTH FRAC TOP ([\d.]+)", line); m !== nothing && (data["grim_cone_pol_depth_frac_top"] = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL ANTE MEAN ([\d.]+)", line);  m !== nothing && (data["grim_cone_pol_ante_mean"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL ANTE MAX (\d+)", line);      m !== nothing && (data["grim_cone_pol_ante_max"]      = parse(Int, m.captures[1])); end
        let m = match(r"^grim CONE POL OPB FRAC ([\d.]+)", line);   m !== nothing && (data["grim_cone_pol_opb_frac"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim CONE POL BURST ([01])", line);        m !== nothing && (data["grim_cone_pol_before_rup_burst"] = parse(Int, m.captures[1])); end

        # Full depth distribution
        let m = match(r"^grim FULL DEPTH P50 (\d+)", line);         m !== nothing && (data["grim_full_depth_p50"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim FULL DEPTH P90 (\d+)", line);         m !== nothing && (data["grim_full_depth_p90"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim FULL DEPTH ENTROPY ([\d.]+)", line);  m !== nothing && (data["grim_full_depth_entropy"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL BOTTOM FRAC ([\d.]+)", line);    m !== nothing && (data["grim_full_bottom_frac"]       = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL WIDTH MAX (\d+)", line);         m !== nothing && (data["grim_full_width_max"]         = parse(Int, m.captures[1])); end
        let m = match(r"^grim FULL WIDTH CV ([\d.]+)", line);       m !== nothing && (data["grim_full_width_cv"]          = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL RUP DEPTH CV ([\d.]+)", line);   m !== nothing && (data["grim_full_rup_depth_cv"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL POL DEPTH MEAN ([\d.]+)", line); m !== nothing && (data["grim_full_pol_depth_mean"]    = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL POL DEPTH CV ([\d.]+)", line);   m !== nothing && (data["grim_full_pol_depth_cv"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL POL ANTE MEAN ([\d.]+)", line);  m !== nothing && (data["grim_full_pol_ante_mean"]     = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL POL ANTE MAX (\d+)", line);      m !== nothing && (data["grim_full_pol_ante_max"]      = parse(Int, m.captures[1])); end
        let m = match(r"^grim FULL POL OPB FRAC ([\d.]+)", line);   m !== nothing && (data["grim_full_pol_opb_frac"]      = parse(Float64, m.captures[1])); end
        let m = match(r"^grim FULL POL BURST ([01])", line);        m !== nothing && (data["grim_full_pol_before_rup_burst"] = parse(Int, m.captures[1])); end

        # Literal/variable fractions
        let m = match(r"^grim LIT (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["grim_cone_literals"] = a; end
        end
        match(r"^grim SMOL LIT (\d+)", line) !== nothing && (data["grim_smol_literals"] = tryparse(Int, match(r"^grim SMOL LIT (\d+)", line).captures[1]))
        let m = match(r"^grim VAR (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["grim_cone_variables"] = a; end
        end

        # Label fractions: grim LABEL TAG cone/full
        for tag in _LABEL_NAMES
            let m = match(Regex("^grim LABEL $tag (\\d+/\\d+)\$"), line)
                if m !== nothing
                    a, b = _parse_frac(m.captures[1])
                    lc = lowercase(tag)
                    data["grim_cone_$lc"] = a
                    data["grim_full_$lc"] = b
                end
            end
        end
        let m = match(r"^grim UNLABELED (\d+/\d+)$", line)
            if m !== nothing
                a, b = _parse_frac(m.captures[1])
                data["grim_cone_unlabeled"] = a; data["grim_full_unlabeled"] = b
            end
        end

        # Variable order fractions
        let m = match(r"^grim UNIQ PAT (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_uniq_pat"] = a; data["grim_full_uniq_pat"] = b; end
        end
        let m = match(r"^grim UNIQ TAR (\d+/\d+)$", line)
            if m !== nothing; a, b = _parse_frac(m.captures[1]); data["grim_cone_uniq_tar"] = a; data["grim_full_uniq_tar"] = b; end
        end

        # Gclt fractions
        let m = match(r"^gclt OPB (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gclt_opb_cone"] = a; end
        end
        let m = match(r"^gclt PBP (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gclt_pbp_cone"] = a; end
        end
        let m = match(r"^gclt NBEQ (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gclt_total_cone"] = a; end
        end
        occursin("gclt TRIM TIME ", line) && (data["gclt_trim_time"] = tryparse(Float64, split(line)[end]))
        let m = match(r"^gclt LIT (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gclt_cone_literals"] = a; end
        end
        match(r"^gclt SMOL LIT (\d+)", line) !== nothing && (data["gclt_smol_literals"] = tryparse(Int, match(r"^gclt SMOL LIT (\d+)", line).captures[1]))
        let m = match(r"^gclt VAR (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gclt_cone_variables"] = a; end
        end

        # Gbfs fractions
        let m = match(r"^gbfs OPB (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gbfs_opb_cone"] = a; end
        end
        let m = match(r"^gbfs PBP (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gbfs_pbp_cone"] = a; end
        end
        let m = match(r"^gbfs NBEQ (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gbfs_total_cone"] = a; end
        end
        occursin("gbfs TRIM TIME ", line) && (data["gbfs_trim_time"] = tryparse(Float64, split(line)[end]))
        let m = match(r"^gbfs LIT (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gbfs_cone_literals"] = a; end
        end
        match(r"^gbfs SMOL LIT (\d+)", line) !== nothing && (data["gbfs_smol_literals"] = tryparse(Int, match(r"^gbfs SMOL LIT (\d+)", line).captures[1]))
        let m = match(r"^gbfs VAR (\d+/\d+)$", line)
            if m !== nothing; a, _ = _parse_frac(m.captures[1]); data["gbfs_cone_variables"] = a; end
        end

        # Verification
        occursin("veri smol TIME ", line)        && (data["veri_smol_time"] = tryparse(Float64, split(line)[end]))
        occursin("veri TIME ", line)             && (data["veri_total_time"] = tryparse(Float64, split(line)[end]))
        line == "veri smol VERIFIED"             && (data["veri_smol_verified"] = 1)
        line == "veri smol NOT VERIFIED"         && (data["veri_smol_verified"] = 0)
        occursin("veri OPB SIZE ", line)     && (data["veri_opb_size"] = tryparse(Int, split(line)[end]))
        occursin("veri PBP SIZE ", line)     && (data["veri_pbp_size"] = tryparse(Int, split(line)[end]))
        occursin("veri SIZE ", line)         && (data["veri_total_size"] = tryparse(Int, split(line)[end]))

        # Resolv shrinkage curve
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

    m = match(r"OOM at ([\d.]+G)", content)
    m !== nothing && return (true, "OOM", m.captures[1])
    m = match(r"OOM killed \(exceeded ([\d.]+ GB)\)", content)
    m !== nothing && return (true, "OOM", m.captures[1])

    if occursin("Timeout", content)
        m = match(r"Timeout after (\d+s)", content)
        details = m !== nothing ? m.captures[1] : "unknown"
        return (true, "Timeout", details)
    end

    if occursin("trunc(Int32", content)
        m = match(r"trunc\(Int32, (\d+)\)", content)
        details = m !== nothing ? "value=$(m.captures[1])" : "unknown"
        return (true, "Int32Overflow", details)
    end

    if occursin("BoundsError", content)
        return (true, "BoundsError", "")
    end

    return (true, "Unknown", strip(content)[1:min(100, end)])
end

function count_resolv_iterations(proofdir, instance)
    n = 0
    while isfile(joinpath(proofdir, instance * ".core$(n+1)" * ".out"))
        n += 1
    end
    return n
end

function get_iteration_sizes(proofdir, instance, n_iterations)
    sizes_total = []; sizes_opb = []; sizes_pbp = []
    for i in 1:n_iterations
        out_file = joinpath(proofdir, instance * ".core$i" * ".out")
        if isfile(out_file)
            data = parse_out_file(out_file)
            push!(sizes_total, get(data, "grim_total_size", nothing))
            push!(sizes_opb, get(data, "grim_opb_size", nothing))
            push!(sizes_pbp, get(data, "grim_pbp_size", nothing))
        else
            push!(sizes_total, nothing); push!(sizes_opb, nothing); push!(sizes_pbp, nothing)
        end
    end
    return (sizes_total, sizes_opb, sizes_pbp)
end

function get_iteration_metrics(proofdir, instance, n_iterations)
    nbeq_list = []; var_list = []; lit_list = []
    for i in 1:n_iterations
        out_file = joinpath(proofdir, instance * ".core$i" * ".out")
        if isfile(out_file)
            data = parse_out_file(out_file)
            push!(nbeq_list, get(data, "inp_total_nbeq", nothing))
            push!(var_list, get(data, "inp_variables", nothing))
            push!(lit_list, get(data, "inp_literals", nothing))
        else
            push!(nbeq_list, nothing); push!(var_list, nothing); push!(lit_list, nothing)
        end
    end
    return (nbeq_list, var_list, lit_list)
end

function parse_lad_node_count(filepath)
    isfile(filepath) || return nothing
    try; return parse(Int, readline(filepath)); catch; return nothing; end
end

function get_core_stats(proofdir, instance)
    vis_dir = joinpath(proofdir, "vis")
    isdir(vis_dir) || return (nothing, nothing, nothing, nothing)
    core_pat_nodes = parse_lad_node_count(joinpath(vis_dir, instance * ".core.pat.lad"))
    core_tar_nodes = parse_lad_node_count(joinpath(vis_dir, instance * ".core.tar.lad"))
    pat_total = parse_lad_node_count(joinpath(vis_dir, instance * ".pat.lad"))
    tar_total = parse_lad_node_count(joinpath(vis_dir, instance * ".tar.lad"))
    return (core_pat_nodes, core_tar_nodes, pat_total, tar_total)
end

function detect_skip_reason(err_filepath, has_proof, status_val)
    if status_val == "true"; return "SAT"; end
    if isfile(err_filepath)
        content = read(err_filepath, String)
        occursin("proof truncated: no conclusion", content) && return "truncated_no_conclusion"
        occursin("proof truncated: output line missing", content) && return "truncated_no_output"
        occursin("proof truncated", content) && return "truncated"
    end
    if status_val == "false" && !has_proof; return "no_proof_generated"; end
    return ""
end

function get_verification_sizes(proofdir, instance)
    opb_smol = joinpath(proofdir, instance * ".opb.smol")
    pbp_smol = joinpath(proofdir, instance * ".pbp.smol")
    if isfile(opb_smol) && isfile(pbp_smol)
        veri_opb = filesize(opb_smol); veri_pbp = filesize(pbp_smol)
        return (veri_opb, veri_pbp, veri_opb + veri_pbp)
    end
    return (nothing, nothing, nothing)
end

function format_array(arr)
    isempty(arr) && return ""
    vals = [v !== nothing ? string(v) : "null" for v in arr]
    return "\"[" * join(vals, ",") * "]\""
end

function aggregate_results(proofdir::String, output_csv::String)
    println("Scanning directory: $proofdir")

    all_files = readdir(proofdir)
    out_files = filter(f -> endswith(f, ".out") &&
                           !endswith(f, ".smolverif.out") &&
                           !endswith(f, ".verif.out"), all_files)

    instances = [splitext(f)[1] for f in out_files]
    println("Found $(length(instances)) instances")

    open(output_csv, "w") do io
        println(io, join(CSV_COLUMNS, ","))

        for (i, instance) in enumerate(instances)
            i % 100 == 0 && println("Processing $i/$(length(instances))...")

            out_file = joinpath(proofdir, instance * ".out")
            data = parse_out_file(out_file)

            err_file = joinpath(proofdir, instance * ".err")
            has_error, error_type, error_details = parse_err_file(err_file)

            resolv_iters = count_resolv_iterations(proofdir, instance)
            iter_sizes_total, iter_sizes_opb, iter_sizes_pbp = get_iteration_sizes(proofdir, instance, resolv_iters)
            iter_nbeq, iter_var, iter_lit = get_iteration_metrics(proofdir, instance, resolv_iters)

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
            push!(row, haskey(data, "veri_smol_verified") ? data["veri_smol_verified"] : "")
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
            is_sat = (status_val == "true")
            is_unsat = (status_val == "false")
            has_proof = haskey(data, "grim_total_time")
            push!(row, is_sat ? "true" : "false")
            push!(row, is_unsat ? "true" : "false")
            push!(row, has_proof ? "true" : "false")

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

            push!(row, format_array(iter_sizes_total))
            push!(row, format_array(iter_sizes_opb))
            push!(row, format_array(iter_sizes_pbp))
            push!(row, format_array(iter_nbeq))
            push!(row, format_array(iter_var))
            push!(row, format_array(iter_lit))

            # Step-type breakdown — cone and full
            push!(row, get(data, "grim_cone_rup", ""))
            push!(row, get(data, "grim_cone_pol", ""))
            push!(row, get(data, "grim_cone_red", ""))
            push!(row, get(data, "grim_cone_ia",  ""))
            push!(row, get(data, "grim_full_rup", ""))
            push!(row, get(data, "grim_full_pol", ""))
            push!(row, get(data, "grim_full_red", ""))
            push!(row, get(data, "grim_full_ia",  ""))

            # Cone depth
            push!(row, get(data, "grim_cone_depth_max",  ""))
            push!(row, get(data, "grim_cone_depth_mean", ""))
            # Full depth
            push!(row, get(data, "grim_full_depth_max",  ""))
            push!(row, get(data, "grim_full_depth_mean", ""))

            # Cone depth distribution
            push!(row, get(data, "grim_cone_depth_p50",        ""))
            push!(row, get(data, "grim_cone_depth_p90",        ""))
            push!(row, get(data, "grim_cone_depth_entropy",    ""))
            push!(row, get(data, "grim_cone_bottom_frac",      ""))
            push!(row, get(data, "grim_cone_bottleneck_depth", ""))
            push!(row, get(data, "grim_cone_width_max",        ""))
            push!(row, get(data, "grim_cone_width_cv",         ""))
            push!(row, get(data, "grim_cone_rup_depth_cv",     ""))
            push!(row, get(data, "grim_cone_pol_depth_mean",   ""))
            push!(row, get(data, "grim_cone_pol_depth_cv",     ""))
            push!(row, get(data, "grim_cone_pol_depth_frac_bot", ""))
            push!(row, get(data, "grim_cone_pol_depth_frac_top", ""))
            push!(row, get(data, "grim_cone_pol_ante_mean",    ""))
            push!(row, get(data, "grim_cone_pol_ante_max",     ""))
            push!(row, get(data, "grim_cone_pol_opb_frac",     ""))
            push!(row, get(data, "grim_cone_pol_before_rup_burst", ""))

            # Full depth distribution
            push!(row, get(data, "grim_full_depth_p50",        ""))
            push!(row, get(data, "grim_full_depth_p90",        ""))
            push!(row, get(data, "grim_full_depth_entropy",    ""))
            push!(row, get(data, "grim_full_bottom_frac",      ""))
            push!(row, get(data, "grim_full_width_max",        ""))
            push!(row, get(data, "grim_full_width_cv",         ""))
            push!(row, get(data, "grim_full_rup_depth_cv",     ""))
            push!(row, get(data, "grim_full_pol_depth_mean",   ""))
            push!(row, get(data, "grim_full_pol_depth_cv",     ""))
            push!(row, get(data, "grim_full_pol_ante_mean",    ""))
            push!(row, get(data, "grim_full_pol_ante_max",     ""))
            push!(row, get(data, "grim_full_pol_opb_frac",     ""))
            push!(row, get(data, "grim_full_pol_before_rup_burst", ""))

            # Step-type fractions — cone (derived)
            let pbp = get(data, "grim_pbp_cone", nothing)
                function stepfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && pbp !== nothing && pbp > 0) ? round(v / pbp; digits=4) : ""
                end
                push!(row, stepfrac("grim_cone_rup"))
                push!(row, stepfrac("grim_cone_pol"))
                push!(row, stepfrac("grim_cone_ia"))
                push!(row, stepfrac("grim_cone_red"))
            end

            # Step-type fractions — full (derived)
            let pbp_full = get(data, "inp_pbp_nbeq", nothing)
                function fullstepfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && pbp_full !== nothing && pbp_full > 0) ? round(v / pbp_full; digits=4) : ""
                end
                push!(row, fullstepfrac("grim_full_rup"))
                push!(row, fullstepfrac("grim_full_pol"))
                push!(row, fullstepfrac("grim_full_ia"))
                push!(row, fullstepfrac("grim_full_red"))
            end

            # Literal compression
            let cl = get(data, "grim_cone_literals", nothing),
                sl = get(data, "grim_smol_literals",  nothing)
                push!(row, (cl !== nothing && sl !== nothing && cl > 0) ?
                    round((cl - sl) / cl; digits=4) : "")
            end

            # Resolv shrinkage curve and stop reason
            iter_pat = get(data, "resolv_iter_pat", [])
            iter_tar = get(data, "resolv_iter_tar", [])
            push!(row, format_array(iter_pat))
            push!(row, format_array(iter_tar))
            stop = get(data, "resolv_stop_reason", "")
            push!(row, stop == "" ? "" : "\"$stop\"")

            # Resolv shrinkage totals (derived)
            let pat0 = get(data, "pattern_vertices", nothing),
                tar0 = get(data, "target_vertices",  nothing)
                push!(row, (pat0 !== nothing && pat0 > 0 && !isempty(iter_pat)) ?
                    round((pat0 - last(iter_pat)) / pat0; digits=4) : "")
                push!(row, (tar0 !== nothing && tar0 > 0 && !isempty(iter_tar)) ?
                    round((tar0 - last(iter_tar)) / tar0; digits=4) : "")
            end

            # Label counts — cone
            for lc in ["al1", "am1", "inj", "g0adj", "g1adj", "g2adj", "g3adj", "gadj_other",
                        "forb", "noedge", "elimdegpol", "elimdeg", "elimndspol", "elimndsconc", "elimnds",
                        "loop", "ptbig", "hall", "prop", "guess", "nogood",
                        "pathg1", "pathg2", "pathg3", "pathg_other",
                        "d2g1", "d2g2", "d2g3", "d2g_other",
                        "d3g1", "d3g2", "d3g3", "d3g_other",
                        "reelimdegpol", "reelimdeg", "reelimndspol", "reelimndsconc",
                        "unsatconc", "binback", "colpol",
                        "hombd", "hompol", "hominj", "homdom", "homfin", "homcross",
                        "mcspart", "mcsfin", "notconn", "cliqedge"]
                push!(row, get(data, "grim_cone_$lc", ""))
            end
            push!(row, get(data, "grim_cone_unlabeled", ""))

            # Label counts — full
            for lc in ["al1", "am1", "inj", "g0adj", "g1adj", "g2adj", "g3adj", "gadj_other",
                        "forb", "noedge", "elimdegpol", "elimdeg", "elimndspol", "elimndsconc", "elimnds",
                        "loop", "ptbig", "hall", "prop", "guess", "nogood",
                        "pathg1", "pathg2", "pathg3", "pathg_other",
                        "d2g1", "d2g2", "d2g3", "d2g_other",
                        "d3g1", "d3g2", "d3g3", "d3g_other",
                        "reelimdegpol", "reelimdeg", "reelimndspol", "reelimndsconc",
                        "unsatconc", "binback", "colpol",
                        "hombd", "hompol", "hominj", "homdom", "homfin", "homcross",
                        "mcspart", "mcsfin", "notconn", "cliqedge"]
                push!(row, get(data, "grim_full_$lc", ""))
            end
            push!(row, get(data, "grim_full_unlabeled", ""))

            # Label fractions of OPB cone (derived)
            let opb_cone = get(data, "grim_opb_cone", nothing)
                function labelfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && opb_cone !== nothing && opb_cone > 0) ? round(v / opb_cone; digits=4) : ""
                end
                push!(row, labelfrac("grim_cone_inj"))
                push!(row, labelfrac("grim_cone_g0adj"))
                push!(row, labelfrac("grim_cone_g1adj"))
                push!(row, labelfrac("grim_cone_g2adj"))
                push!(row, labelfrac("grim_cone_g3adj"))
                push!(row, labelfrac("grim_cone_forb"))
                push!(row, labelfrac("grim_cone_noedge"))
                push!(row, labelfrac("grim_cone_elimdegpol"))
                push!(row, labelfrac("grim_cone_elimnds"))
                push!(row, labelfrac("grim_cone_elimdeg"))
                push!(row, labelfrac("grim_cone_hall"))
                push!(row, labelfrac("grim_cone_prop"))
                push!(row, labelfrac("grim_cone_guess"))
                push!(row, labelfrac("grim_cone_nogood"))
                push!(row, labelfrac("grim_cone_pathg1"))
                push!(row, labelfrac("grim_cone_pathg2"))
                push!(row, labelfrac("grim_cone_pathg3"))
                push!(row, labelfrac("grim_cone_pathg_other"))
                push!(row, labelfrac("grim_cone_d2g1"))
                push!(row, labelfrac("grim_cone_d2g2"))
                push!(row, labelfrac("grim_cone_d2g3"))
                push!(row, labelfrac("grim_cone_d2g_other"))
                push!(row, labelfrac("grim_cone_d3g1"))
                push!(row, labelfrac("grim_cone_d3g2"))
                push!(row, labelfrac("grim_cone_d3g3"))
                push!(row, labelfrac("grim_cone_d3g_other"))
            end

            # Variable order — cone and full
            push!(row, get(data, "grim_cone_uniq_pat", ""))
            push!(row, get(data, "grim_cone_uniq_tar", ""))
            push!(row, get(data, "grim_full_uniq_pat", ""))
            push!(row, get(data, "grim_full_uniq_tar", ""))

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
