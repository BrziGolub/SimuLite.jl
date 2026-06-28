module Diagram

using ..Types
using ..BlocksAPI

export add_block!, connect!, disconnect!, remove_block!, get_execution_order

function add_block!(diagram::BlockDiagram, block::AbstractBlock)
    if any(b.name == block.name for b in diagram.blocks)
        throw(DuplicateNameError(block.name))
    end
    push!(diagram.blocks, block)
    return block
end

function connect!(diagram::BlockDiagram, src, src_port::Symbol, dst, dst_port::Symbol)
    haskey(src.base.outputs, src_port) ||
        throw(PortNotFoundError(src.name, src_port, :output))
    haskey(dst.base.inputs, dst_port) ||
        throw(PortNotFoundError(dst.name, dst_port, :input))
    any(c.dst_block === dst && c.dst_port == dst_port for c in diagram.connections) &&
        throw(PortAlreadyConnectedError(dst.name, dst_port))
    push!(diagram.connections, Connection(src, src_port, dst, dst_port))
end

function disconnect!(diagram::BlockDiagram, src, src_port::Symbol, dst, dst_port::Symbol)
    filter!(diagram.connections) do c
        !(c.src_block === src && c.src_port == src_port &&
          c.dst_block === dst && c.dst_port == dst_port)
    end
end

function remove_block!(diagram::BlockDiagram, block::AbstractBlock)
    filter!(b -> b !== block, diagram.blocks)
    filter!(diagram.connections) do c
        c.src_block !== block && c.dst_block !== block
    end
end

# -----------------------------
# Topological sort (Kahn) with feedback loop support
# -----------------------------
function get_execution_order(diagram::BlockDiagram)
    blocks = diagram.blocks
    indegree = Dict(b => 0 for b in blocks)

    for c in diagram.connections
        indegree[c.dst_block] += 1
    end

    queue    = AbstractBlock[b for b in blocks if indegree[b] == 0]
    order    = AbstractBlock[]
    in_order = Set{AbstractBlock}()

    while length(order) < length(blocks)
        if isempty(queue)
            # Kahn's stalled — a cycle exists.
            # Find a memory block (no direct feedthrough) to act as cycle-breaker.
            remaining = [b for b in blocks if b ∉ in_order]
            idx = findfirst(b -> !has_direct_feedthrough(b), remaining)
            if idx === nothing
                throw(AlgebraicLoopError(
                    "cycle contains only direct-feedthrough blocks — cannot resolve automatically"))
            end
            push!(queue, remaining[idx])
        end

        b = popfirst!(queue)
        b ∈ in_order && continue
        push!(order, b)
        push!(in_order, b)

        for c in diagram.connections
            if c.src_block === b
                indegree[c.dst_block] -= 1
                if indegree[c.dst_block] == 0 && c.dst_block ∉ in_order
                    push!(queue, c.dst_block)
                end
            end
        end
    end

    return order
end

end