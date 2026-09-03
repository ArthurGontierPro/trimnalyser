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

        # ── Sentinel index ────────────────────────────────────────────────────────────
        # `.timeoutNNN` and `.memoutNNN` used to be located by a full `readdir` of the
        # proofs directory — once per instance, per call, from every thread. A finished
        # column's directory holds a quarter of a million files, so that scan grew into
        # the dominant cost of a run rather than a lookup.
        #
        # The index is built once by `index_sentinels!` and kept current by
        # `mark_timeout!`/`mark_memout!`, the only two places a sentinel is created. It
        # is monotone: entries only ever rise, exactly as the filesystem's do.
        #
        # `_sentinels_ready[]` false means "not indexed", and both lookups fall back to
        # the old scan. Single-instance mode leaves it false on purpose: one cheap call
        # beats a startup pass. Never flip it true over a partial index — a false
        # POSITIVE here silently drops an instance from a table cell, which is the same
        # trap the `.memoutNNN` note below warns about. A false negative only costs a
        # re-attempt, so a sentinel written by a trim subprocess (which has its own
        # index, unused) being missed by the parent is the safe direction.
    const _timeout_idx     = Dict{String,Int}()
    const _memout_idx      = Dict{String,Int}()
    const _sentinel_lk     = ReentrantLock()
    const _sentinels_ready = Ref(false)

    function index_sentinels!()
        lock(_sentinel_lk) do
            empty!(_timeout_idx); empty!(_memout_idx)
            if isdir(_cfg[].proofs)
                for f in readdir(_cfg[].proofs)
                    m = match(r"^(.+)\.timeout(\d+)$", f)
                    if m !== nothing
                        k = String(m.captures[1]); v = parse(Int, m.captures[2])
                        _timeout_idx[k] = max(get(_timeout_idx, k, 0), v)
                        continue
                    end
                    m = match(r"^(.+)\.memout(\d+)$", f)
                    if m !== nothing
                        k = String(m.captures[1]); v = parse(Int, m.captures[2])
                        _memout_idx[k] = max(get(_memout_idx, k, 0), v)
                    end
                end
            end
            _sentinels_ready[] = true
        end
        return (length(_timeout_idx), length(_memout_idx)) end

    function timed_out_at_current_st(ins)
        if _sentinels_ready[]
            return lock(_sentinel_lk) do
                get(_timeout_idx, ins, 0) >= _cfg[].solvertimeout
            end
        end
        pref = ins * ".timeout"
        for f in readdir(_cfg[].proofs)
            startswith(f, pref) || continue
            t = tryparse(Int, f[length(pref)+1:end])
            t !== nothing && t >= _cfg[].solvertimeout && return true
        end
        false end

        # Memory twin of timed_out_at_current_st: a `.memoutNNN` sentinel records the
        # maxmem= limit (GB) in force when the instance was OOM killed or produced a
        # truncated proof. Re-running is pointless unless the new limit is larger.
    function memout_at_current_maxmem(ins)
        if _sentinels_ready[]
            return lock(_sentinel_lk) do
                g = get(_memout_idx, ins, 0)
                g >= _cfg[].maxinstmem_gb ? (true, g) : (false, 0)
            end
        end
        pref = ins * ".memout"
        for f in readdir(_cfg[].proofs)
            startswith(f, pref) || continue
            g = tryparse(Int, f[length(pref)+1:end])
            g !== nothing && g >= _cfg[].maxinstmem_gb && return (true, g)
        end
        (false, 0) end

    memout_sentinel(ins)      = _cfg[].proofs * ins * ".memout" * string(round(Int, _cfg[].maxinstmem_gb))
    timeout_sentinel(ins, t)  = _cfg[].proofs * ins * ".timeout" * string(t)

        # The only two places a sentinel is created. Route every `touch` through them so
        # the index cannot drift from the directory.
    function mark_timeout!(ins, t)
        touch(timeout_sentinel(ins, t))
        lock(_sentinel_lk) do; _timeout_idx[ins] = max(get(_timeout_idx, ins, 0), t) end
        return end

    function mark_memout!(ins)
        touch(memout_sentinel(ins))
        g = round(Int, _cfg[].maxinstmem_gb)
        lock(_sentinel_lk) do; _memout_idx[ins] = max(get(_memout_idx, ins, 0), g) end
        return end

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
                # Capture this BEFORE the cleanup below deletes the file.
                partial = filesize(_cfg[].proofs * ins * pbp) > 0
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins: no conclusion (truncated proof) — skipping\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                # A truncated proof is the solver dying mid-write, which in practice is always
                # an OOM: record it like any other memout so the next run with the same
                # maxmem= does not re-solve it from scratch. Only when a partial .pbp is
                # actually on disk — pbpconclusion() also returns "" for a MISSING file,
                # and sentinelling that would permanently skip an instance never solved.
                partial && mark_memout!(ins)
                return
            end
        end
        let sz = (isfile(_cfg[].proofs*ins*opb) ? filesize(_cfg[].proofs*ins*opb) : 0) +
                    (isfile(_cfg[].proofs*ins*pbp) ? filesize(_cfg[].proofs*ins*pbp) : 0)
            if sz > 50 * 1024^3
                printstyled("  $ins too large ($(round(sz/1024^3; digits=1)) GB) — skipping\n"; color=:yellow)
                # Delete it. This branch used to return with the proof still on disk,
                # which is the one skip path that LEAKS: every instance too big to trim
                # left its tens of GB behind for the rest of the run. Invisible on the
                # Glasgow grid, where the branch essentially never fires; fatal for LAD,
                # whose proofs have no deletions and grow with search length, so the
                # instances that trip 50 GB are common rather than exceptional.
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
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
