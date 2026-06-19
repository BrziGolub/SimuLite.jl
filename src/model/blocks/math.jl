module BlocksMath

using ..Types
using ..BlocksCommon

import ..BlocksAPI: evaluate!, commit_state!

export GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock

# ------------------------------------------

mutable struct GainBlock <: AbstractBlock
    base::BlockBase
    k::Float64
    name::String
    position::Tuple{Float64, Float64}
end

function GainBlock(k; name="gain_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    GainBlock(base, k, name, position)
end

function evaluate!(b::GainBlock, _t, _dt)
    b.base.outputs[:out].value = b.k * b.base.inputs[:in].value
end

# ------------------------------------------

mutable struct SumBlock <: AbstractBlock
    base::BlockBase
    signs::String
    name::String
    position::Tuple{Float64, Float64}
end

"""
    SumBlock(signs; name, position)

Signs is a string of '+' and '-' characters, one per input port.
E.g. SumBlock("+-") subtracts in2 from in1.
"""
function SumBlock(signs::String; name="sum_$(_next_id())", position=(0.0, 0.0))
    inputs = [Symbol("in$i") for i in 1:length(signs)]
    base   = BlockBase(inputs, [:out])
    SumBlock(base, signs, name, position)
end

function evaluate!(b::SumBlock, _t, _dt)
    result = 0.0
    for (i, sign_char) in enumerate(b.signs)
        port    = b.base.inputs[Symbol("in$i")]
        result += (sign_char == '+' ? 1.0 : -1.0) * port.value
    end
    b.base.outputs[:out].value = result
end

# ------------------------------------------

mutable struct IntegratorBlock <: AbstractBlock
    base::BlockBase
    state::Float64
    next_state::Float64
    name::String
    position::Tuple{Float64, Float64}
end

function IntegratorBlock(x0=0.0; name="int_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    IntegratorBlock(base, x0, x0, name, position)
end

function evaluate!(b::IntegratorBlock, _t, dt)
    u = b.base.inputs[:in].value
    b.base.outputs[:out].value = b.state
    b.next_state = b.state + u * dt
end

function commit_state!(b::IntegratorBlock)
    b.state = b.next_state
end

# ------------------------------------------

mutable struct UnitDelayBlock <: AbstractBlock
    base::BlockBase
    state::Float64
    next_state::Float64
    name::String
    position::Tuple{Float64, Float64}
end

function UnitDelayBlock(x0=0.0; name="delay_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    UnitDelayBlock(base, x0, x0, name, position)
end

function evaluate!(b::UnitDelayBlock, _t, _dt)
    b.base.outputs[:out].value = b.state
    b.next_state = b.base.inputs[:in].value
end

function commit_state!(b::UnitDelayBlock)
    b.state = b.next_state
end

end
