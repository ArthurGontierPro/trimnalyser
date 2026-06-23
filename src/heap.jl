struct MinHeap
    data::Vector{Int}
end
MinHeap() = MinHeap(Int[])

struct MaxHeap
    data::Vector{Int}
end
MaxHeap() = MaxHeap(Int[])

Base.isempty(h::Union{MinHeap,MaxHeap}) = isempty(h.data)
Base.length(h::Union{MinHeap,MaxHeap})  = length(h.data)
Base.empty!(h::Union{MinHeap,MaxHeap})  = (empty!(h.data); h)
Base.sizehint!(h::Union{MinHeap,MaxHeap}, n::Integer) = (sizehint!(h.data, n); h)

function Base.push!(h::MinHeap, v::Int)
    d = h.data
    push!(d, v)
    _percolate_up_min!(d, length(d), v)
end

function Base.pop!(h::MinHeap)
    d = h.data
    x = @inbounds d[1]
    y = pop!(d)
    isempty(d) || @inbounds _percolate_down_min!(d, 1, y, length(d))
    x
end

function Base.push!(h::MaxHeap, v::Int)
    d = h.data
    push!(d, v)
    _percolate_up_max!(d, length(d), v)
end

function Base.pop!(h::MaxHeap)
    d = h.data
    x = @inbounds d[1]
    y = pop!(d)
    isempty(d) || @inbounds _percolate_down_max!(d, 1, y, length(d))
    x
end

@inline function _percolate_up_min!(d, i, x)
    @inbounds while (j = i >> 1) >= 1
        x < d[j] || break
        d[i] = d[j]
        i = j
    end
    @inbounds d[i] = x
end

@inline function _percolate_down_min!(d, i, x, n)
    @inbounds while (l = i << 1) <= n
        r = l + 1
        j = r > n || d[l] < d[r] ? l : r
        d[j] < x || break
        d[i] = d[j]
        i = j
    end
    @inbounds d[i] = x
end

@inline function _percolate_up_max!(d, i, x)
    @inbounds while (j = i >> 1) >= 1
        x > d[j] || break
        d[i] = d[j]
        i = j
    end
    @inbounds d[i] = x
end

@inline function _percolate_down_max!(d, i, x, n)
    @inbounds while (l = i << 1) <= n
        r = l + 1
        j = r > n || d[l] > d[r] ? l : r
        d[j] > x || break
        d[i] = d[j]
        i = j
    end
    @inbounds d[i] = x
end
