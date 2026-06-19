module BlocksCommon

using ..Types

export BlockBase, _next_id

const _block_id = Ref(0)
_next_id() = (_block_id[] += 1)

mutable struct BlockBase
    inputs::Dict{Symbol, Port}
    outputs::Dict{Symbol, Port}
end

function BlockBase(input_names::Vector{Symbol}, output_names::Vector{Symbol})
    inputs  = Dict{Symbol, Port}()
    outputs = Dict{Symbol, Port}()

    for name in input_names
        inputs[name] = Port(name, 0.0)
    end

    for name in output_names
        outputs[name] = Port(name, 0.0)
    end

    return BlockBase(inputs, outputs)
end

end
