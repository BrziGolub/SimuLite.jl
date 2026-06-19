module Runner

using ..Types
using ..Diagram

import ..BlocksAPI: evaluate!, commit_state!

export simulate

function simulate(diagram::BlockDiagram; tspan=nothing, dt=nothing)

    tspan = something(tspan, diagram.config.tspan)
    dt    = something(dt,    diagram.config.dt)

    t0, tf = tspan
    t = t0

    order = get_execution_order(diagram)

    t_log = Float64[]
    data  = Dict{String, Vector{Float64}}()

    for b in diagram.blocks
        for (name, _) in b.base.outputs
            data["$(b.name).$name"] = Float64[]
        end
    end

    while t <= tf

        # Evaluate + propagate in topological order.
        # Each block's outputs are forwarded to downstream inputs immediately
        # after it evaluates, so the next sorted block always reads fresh values.
        for b in order
            evaluate!(b, t, dt)
            for c in diagram.connections
                if c.src_block === b
                    c.dst_block.base.inputs[c.dst_port].value =
                        b.base.outputs[c.src_port].value
                end
            end
        end

        # Commit phase
        for b in order
            commit_state!(b)
        end

        # Log time and all block outputs
        push!(t_log, t)
        for b in diagram.blocks
            for (name, port) in b.base.outputs
                push!(data["$(b.name).$name"], port.value)
            end
        end

        t += dt
    end

    return SimResult(t_log, data)
end

end