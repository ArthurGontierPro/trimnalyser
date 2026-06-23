# ══ Instance pipeline ══════════════════════════════════════════════════════════════════════════
    function pbpconclusion(ins, suffix=pbp)
        f = _cfg[].proofs*ins*suffix
        isfile(f) || return ""
        sz = filesize(f)
        open(f) do io
            seek(io, max(0, sz - 500))
            tail = read(io, String)
            m = match(r"conclusion\s+(\w+)", tail)
            m === nothing ? "" : m.captures[1]
        end end

    smol_complete(ins) = isfile(_cfg[].proofs*ins*".done") ||
                         (isfile(_cfg[].proofs*ins*smol_opb) && !isempty(pbpconclusion(ins, smol_pbp)))

    function timed_out_at_current_st(ins)
        pref = ins * ".timeout"
        for f in readdir(_cfg[].proofs)
            startswith(f, pref) || continue
            t = tryparse(Int, f[length(pref)+1:end])
            t !== nothing && t >= _cfg[].solvertimeout && return true
        end
        false end

        # Check if instance was previously OOM killed, return (was_killed, memory_info)
    function was_oom_killed(ins)
        errfile = _cfg[].proofs * ins * ".err"
        isfile(errfile) || return (false, "")
        content = read(errfile, String)
        # Look for "OOM at X.XG" pattern
        m = match(r"OOM at ([\d.]+G)", content)
        if m !== nothing
            return (true, m.captures[1])
        end
        # Fallback: old format "OOM killed"
        return (occursin("OOM killed", content) || occursin("OOM at", content), "")
    end

    function trimnalyseandcie(ins)
        # trim-only: called in subprocess mode (_cfg[].subprocess = true).
        # Orchestrator handles solve / verif / resolv / smol cleanup / .done.
        if !_cfg[].overwrite && smol_complete(ins)
            printstyled("  $ins already done — skipping\n"; color=:blue); return
        end
        let c = pbpconclusion(ins)
            if c == "SAT" || c == "NONE"
                touch(_cfg[].proofs * ins * ".sat")
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins $c — skipping\n"; color=:yellow); return
            end
            if isempty(c)
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins: no conclusion (truncated proof) — skipping\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                return
            end
        end
        let sz = (isfile(_cfg[].proofs*ins*opb) ? filesize(_cfg[].proofs*ins*opb) : 0) +
                    (isfile(_cfg[].proofs*ins*pbp) ? filesize(_cfg[].proofs*ins*pbp) : 0)
            if sz > 50 * 1024^3
                printstyled("  $ins too large ($(round(sz/1024^3; digits=1)) GB) — skipping\n"; color=:yellow)
                return
            end
        end
        if !_cfg[].nonorm
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(ins; mode=Grim())
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
            !isempty(coremsg) && println(coremsg)
        end
        if _cfg[].clit
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,_ = trimnalyse(ins; mode=Clit())
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
        end
        if !_cfg[].keepraw && !_cfg[].subprocess
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
        end
        end

        # mode: Grim() or Clit() — see mode structs in types.jl
    function trimnalyse(ins; mode=Grim())
        prefix = mode isa Clit ? "gclt" : "grim"
        parse_time = trim_time = write_time = 0 ; file = ins ; cone_stats = nothing
        parse_time = @elapsed begin
            store,systemlink,redwitness,solirecord,assertrecord,nbopb,varmap,ctrmap,ctrmap_evicted,output,conclusion,obj,prism = readinstance(_cfg[].proofs,file)
        end
        inp_lits = length(store.vars)
        writeout_parse(ins, parse_time, inp_lits, length(varmap), prefix)
        sys = PBSystem(store, length(varmap))  # zero-copy: PBSystem reuses FlatEqStore's flat arrays directly
        n = length(sys.rhs)
        full_step_counts = count_step_types_full(systemlink)
        cone     = falses(n)
        conelits = Dict{Int,Set{Int}}()
        trim_time = @elapsed begin
            getcone!(cone, conelits, sys, systemlink, nbopb, prism, redwitness, conclusion, obj, mode)
        end
        writeout_trim(ins, trim_time, cone, nbopb, prefix)
        step_counts = count_step_types(systemlink, cone, nbopb)
        writeout_step_types(ins, step_counts, full_step_counts, prefix)
        cone_depth  = compute_cone_depth(cone, systemlink, nbopb)
        all_true    = trues(n)
        full_depth  = compute_cone_depth(all_true, systemlink, nbopb)
        writeout_depth(ins, cone_depth, full_depth, prefix)
        cone_dist = compute_cone_depth_dist(cone, systemlink, nbopb, cone_depth.depth_arr)
        full_dist = compute_cone_depth_dist(all_true, systemlink, nbopb, full_depth.depth_arr)
        writeout_depth_dist(ins, cone_dist, full_dist, prefix)
        writeout_conelits(ins, sys, cone, conelits, inp_lits, prefix)
        cone_stats = conelits_stats(sys, cone, conelits)
        printconestat(cone, cone_stats)
        varmap_inv = Vector{String}(undef, length(varmap))
        for (k, v) in varmap; varmap_inv[v] = String(copy(k)); end
        if mode isa Grim
            cone_label = cone_label_stats(cone, ctrmap, ctrmap_evicted, nbopb)
            full_label = full_label_stats(ctrmap, ctrmap_evicted, nbopb, n)
            writeout_labels(ins, cone_label, full_label, prefix)
            cone_vo = cone_var_order(cone, varmap_inv, sys, nbopb)
            full_vo = full_var_order(varmap_inv, sys, nbopb)
            writeout_var_order(ins, cone_vo, full_vo, prefix)
        end
        if isempty(output)
            printstyled("  $ins: proof truncated (no output line) — skipping write\n"; color=:red)
            open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: output line missing") end
            return trunc(Int,parse_time),trunc(Int,trim_time),0,cone_stats,""
        end
        coremsg = (mode isa Grim && (_cfg[].core || _cfg[].resolv)) ? writeunsatcore(ins, sys, cone, conelits, varmap_inv, nbopb) : ""
        let expected = nbopb + length(systemlink), actual = length(sys.rhs)
            if expected != actual
                printstyled("  SYNC ERROR $ins: nbopb=$nbopb + systemlink=$(length(systemlink)) = $expected but sys.rhs=$actual (diff=$(expected-actual))\n"; color=:red)
            end
        end
        write_time = @elapsed begin
            writeconedel(_cfg[].proofs,file,sys,cone,conelits,systemlink,redwitness,solirecord,assertrecord,nbopb,varmap_inv,ctrmap,output,conclusion,obj,prism)
        end
        writeout_write(ins, parse_time, trim_time, write_time, prefix)
        return trunc(Int,parse_time),trunc(Int,trim_time),trunc(Int,write_time),cone_stats,coremsg end
