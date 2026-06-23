module BlocksAPI

export evaluate!, commit_state!, initialize!, input_ports, output_ports

function evaluate!(block, t, dt)
    error("evaluate! not implemented for $(typeof(block))")
end

function commit_state!(_)
end

function initialize!(_)
end

"""
    input_ports(block) -> Vector{Symbol}

Returns the names of all input ports on a block.
"""
input_ports(block)  = collect(keys(block.base.inputs))

"""
    output_ports(block) -> Vector{Symbol}

Returns the names of all output ports on a block.
"""
output_ports(block) = collect(keys(block.base.outputs))

end
