# ══ Flat POL Operations (Zero-Copy) ═════════════════════════════════════════

        # Push equation ID onto POL stack (lazy - no copy)
    @inline function pol_push_eq!(ps::PolScratch, id::Int)
        push!(ps.stack, Int32(id))
        ps.stack_depth += 1
    end

        # Push literal axiom onto POL stack
    function pol_push_literal!(ps::PolScratch, var::Int, sign::Bool)
        resize!(ps.vars, 1); ps.vars[1] = Int32(var)
        resize!(ps.coefs, 1); ps.coefs[1] = Int32(1)
        resize!(ps.signs, 1); ps.signs[1] = sign
        ps.rhs = 0
        idx = _pol_alloc_scratch!(ps)
        push!(ps.stack, Int32(-idx))
        ps.stack_depth += 1
    end

        # Addition: pop two equations, merge, push result
    function pol_add!(ps::PolScratch, store::FlatEqStore)
        ps.stack_depth >= 2 || error("pol stack underflow")
        id2 = pop!(ps.stack); ps.stack_depth -= 1
        id1 = pop!(ps.stack); ps.stack_depth -= 1

        v1, c1, s1, rhs1, r1 = _pol_get_arrays(ps, store, id1)
        v2, c2, s2, rhs2, r2 = _pol_get_arrays(ps, store, id2)

        resize!(ps.vars, 0); resize!(ps.coefs, 0); resize!(ps.signs, 0)
        sizehint!(ps.vars, length(r1) + length(r2))

        i, j = r1.start, r2.start
        rhs_adj = zero(Int64)

        while i <= r1.stop && j <= r2.stop
            if v1[i] < v2[j]
                push!(ps.vars, v1[i]); push!(ps.coefs, c1[i]); push!(ps.signs, s1[i]); i += 1
            elseif v1[i] > v2[j]
                push!(ps.vars, v2[j]); push!(ps.coefs, c2[j]); push!(ps.signs, s2[j]); j += 1
            else
                # Same variable: add coefficients
                # Invariant: all equations normalized (coefs > 0), so sign difference means cancellation
                var = v1[i]
                if s1[i] == s2[j]
                    c = c1[i] + c2[j]
                    c != 0 && (push!(ps.vars, var); push!(ps.coefs, c); push!(ps.signs, s1[i]))
                else
                    # Different signs: c1*x + c2*~x → adjust rhs
                    if c1[i] > c2[j]
                        push!(ps.vars, var); push!(ps.coefs, c1[i] - c2[j]); push!(ps.signs, s1[i])
                        rhs_adj += c2[j]
                    elseif c2[j] > c1[i]
                        push!(ps.vars, var); push!(ps.coefs, c2[j] - c1[i]); push!(ps.signs, s2[j])
                        rhs_adj += c1[i]
                    else
                        rhs_adj += c1[i]  # complete cancellation
                    end
                end
                i += 1; j += 1
            end
        end

        while i <= r1.stop
            push!(ps.vars, v1[i]); push!(ps.coefs, c1[i]); push!(ps.signs, s1[i]); i += 1
        end
        while j <= r2.stop
            push!(ps.vars, v2[j]); push!(ps.coefs, c2[j]); push!(ps.signs, s2[j]); j += 1
        end

        ps.rhs = rhs1 + rhs2 - rhs_adj
        idx = _pol_alloc_scratch!(ps)
        push!(ps.stack, Int32(-idx))
        ps.stack_depth += 1
    end

        # Multiplication: mutate top of stack in-place
    function pol_multiply!(ps::PolScratch, store::FlatEqStore, multiplier::Int)
        ps.stack_depth >= 1 || error("pol stack underflow")
        id = ps.stack[end]
        if id > 0
            _pol_materialize!(ps, store, id)
            idx = _pol_alloc_scratch!(ps)
            ps.stack[end] = Int32(-idx)
        end
        idx = -ps.stack[end]
        scratch = ps.scratch_pool[idx]
        for i in eachindex(scratch[2])
            scratch[2][i] = Int32(Int64(scratch[2][i]) * multiplier)
        end
        ps.scratch_pool[idx] = (scratch[1], scratch[2], scratch[3], scratch[4] * multiplier)
    end

        # Division: ceil divide, mutate top of stack in-place
    function pol_divide!(ps::PolScratch, store::FlatEqStore, divisor::Int)
        ps.stack_depth >= 1 || error("pol stack underflow")
        id = ps.stack[end]
        if id > 0
            _pol_materialize!(ps, store, id)
            idx = _pol_alloc_scratch!(ps)
            ps.stack[end] = Int32(-idx)
        end
        idx = -ps.stack[end]
        scratch = ps.scratch_pool[idx]
        vars, coefs, signs, rhs = scratch
        # Normalize first (should already be normalized, but ceil divide needs it)
        for i in eachindex(coefs)
            coefs[i] = Int32(ceil(coefs[i] / divisor))
        end
        ps.scratch_pool[idx] = (vars, coefs, signs, ceil(Int, rhs / divisor))
    end

        # Saturate: cap coefficients at rhs, mutate top of stack in-place
    function pol_saturate!(ps::PolScratch, store::FlatEqStore)
        ps.stack_depth >= 1 || error("pol stack underflow")
        id = ps.stack[end]
        if id > 0
            _pol_materialize!(ps, store, id)
            idx = _pol_alloc_scratch!(ps)
            ps.stack[end] = Int32(-idx)
        end
        idx = -ps.stack[end]
        scratch = ps.scratch_pool[idx]
        coefs = scratch[2]
        rhs = scratch[4]
        for i in eachindex(coefs)
            coefs[i] > rhs && (coefs[i] = Int32(rhs))
        end
    end

        # Weaken: remove variable, mutate top of stack in-place
    function pol_weaken!(ps::PolScratch, store::FlatEqStore, var::Int)
        ps.stack_depth >= 1 || error("pol stack underflow")
        id = ps.stack[end]
        if id > 0
            _pol_materialize!(ps, store, id)
            idx = _pol_alloc_scratch!(ps)
            ps.stack[end] = Int32(-idx)
        end
        idx = -ps.stack[end]
        scratch = ps.scratch_pool[idx]
        vars, coefs, signs, rhs = scratch
        i = findfirst(==(Int32(var)), vars)
        if i !== nothing
            rhs -= coefs[i]
            deleteat!(vars, i)
            deleteat!(coefs, i)
            deleteat!(signs, i)
            ps.scratch_pool[idx] = (vars, coefs, signs, rhs)
        end
    end

        # Finalize: pop result, remove nulls, optionally saturate, push to store
    function pol_finalize_push!(ps::PolScratch, store::FlatEqStore, saturate_final::Bool)
        ps.stack_depth >= 1 || error("pol stack underflow")
        id = pop!(ps.stack)
        ps.stack_depth -= 1

        v, c, s, rhs, r = _pol_get_arrays(ps, store, id)

        # Pass 1: normalize + remove nulls + write to store
        rhs_adj = zero(Int64)
        for i in r
            c[i] == 0 && continue  # skip null lits
            if c[i] < 0
                push!(store.vars, v[i]); push!(store.coefs, -c[i]); push!(store.signs, !s[i])
                rhs_adj += -c[i]
            else
                push!(store.vars, v[i]); push!(store.coefs, c[i]); push!(store.signs, s[i])
            end
        end
        rhs += rhs_adj

        # Pass 2: saturate if requested
        if saturate_final
            start_idx = length(store.coefs) - count(!=(0), c[k] for k in r) + 1
            for i in start_idx:length(store.coefs)
                store.coefs[i] > rhs && (store.coefs[i] = Int32(rhs))
            end
        end

        push!(store.rhs, Int64(rhs))
        push!(store.row_ptr, length(store.vars) + 1)

        # Reset scratch for next POL
        ps.next_scratch = 1
    end

# ══ End Flat POL Operations ═════════════════════════════════════════════════

        # Flat POL evaluator: zero-copy replacement for solvepol + push_eq_normalized!
        # Pushes result directly to store (no intermediate Eq/Lit allocations)
    function solvepol_flat!(store::FlatEqStore, st, link::Vector{Int}, init::Int,
                            varmap, ctrmap, nbopb)
        ps = get_pol_scratch()
        ps.stack_depth = 0
        empty!(ps.stack)
        ps.next_scratch = 1

        # Parse initial equation ID
        i = st[2]
        id = i[1]==UInt8('@') ? ctrmap[String(view(i,2:length(i)))] : parse_int_bytes(i)
        id < 0 && (id = init + id)

        pol_push_eq!(ps, id)
        push!(link, id)

        weakvar = 0
        lastsaturate = false

        # Process POL expression
        for j in 3:length(st)
            i = st[j]
            tok_eq(i, ";") && continue

            if tok_eq(i, "+")
                pol_add!(ps, store)
                push!(link, -1)
            elseif tok_eq(i, "*")
                multiplier = link[end]
                pol_multiply!(ps, store, multiplier)
                push!(link, -2)
            elseif tok_eq(i, "d")
                divisor = link[end]
                pol_divide!(ps, store, divisor)
                push!(link, -3)
            elseif tok_eq(i, "s")
                if j == length(st)
                    lastsaturate = true  # defer to finalize
                else
                    pol_saturate!(ps, store)
                end
                push!(link, -4)
            elseif tok_eq(i, "w")
                pol_weaken!(ps, store, weakvar)
                push!(link, -5)
            elseif !isdigit(Char(i[1])) && i[1] != UInt8('@') && i[1] != UInt8('-')
                # Literal axiom
                if length(st) > j && tok_eq(st[j+1], "w")
                    weakvar = readvar(i, varmap)
                    push!(link, -100 * weakvar - 99)
                else
                    sign = i[1] != UInt8('~')
                    var = readvar(i, varmap)
                    pol_push_literal!(ps, var, sign)
                    push!(link, -100 * var - 99 - (sign ? 0 : 1))
                end
            elseif !tok_eq(i, "0")
                # Constraint ID
                id = i[1]==UInt8('@') ? ctrmap[String(view(i,2:length(i)))] : parse_int_bytes(i)
                id < 1 && (id = init + id)
                push!(link, id)
                if !tok_in(st[j+1], ["*", "d"])
                    pol_push_eq!(ps, id)
                end
            end
        end

        # Special case: single antecedent = ia
        length(link) == 2 && (link[1] = -3)

        # Finalize and push to store
        pol_finalize_push!(ps, store, lastsaturate)
    end
