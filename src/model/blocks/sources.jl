module BlocksSources

using ..Types
using ..BlocksCommon

import ..BlocksAPI: evaluate!, initialize!

export ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock

# ------------------------------------------

mutable struct ConstantBlock <: AbstractBlock
    base::BlockBase
    value::Float64
    name::String
    position::Tuple{Float64, Float64}
end

function ConstantBlock(value::Float64; name="const_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase(Symbol[], [:out])
    ConstantBlock(base, value, name, position)
end

function evaluate!(b::ConstantBlock, _t, _dt)
    b.base.outputs[:out].value = b.value
end

initialize!(::ConstantBlock) = nothing

# ------------------------------------------

mutable struct StepBlock <: AbstractBlock
    base::BlockBase
    step_time::Float64
    before::Float64
    after::Float64
    name::String
    position::Tuple{Float64, Float64}
end

"""
    StepBlock(; step_time, before, after, name, position)

Outputs `before` for t < step_time, then `after` for t >= step_time.
"""
function StepBlock(; step_time=1.0, before=0.0, after=1.0,
                     name="step_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase(Symbol[], [:out])
    StepBlock(base, step_time, before, after, name, position)
end

function evaluate!(b::StepBlock, t, _dt)
    b.base.outputs[:out].value = t >= b.step_time ? b.after : b.before
end

initialize!(::StepBlock) = nothing

# ------------------------------------------

mutable struct SineBlock <: AbstractBlock
    base      :: BlockBase
    amplitude :: Float64
    frequency :: Float64
    phase     :: Float64
    offset    :: Float64
    name      :: String
    position  :: Tuple{Float64, Float64}
end

"""
    SineBlock(; amplitude, frequency, phase, offset, name, position)

Outputs `amplitude * sin(2π * frequency * t + phase) + offset`.
"""
function SineBlock(; amplitude=1.0, frequency=1.0, phase=0.0, offset=0.0,
                     name="sine_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase(Symbol[], [:out])
    SineBlock(base, amplitude, frequency, phase, offset, name, position)
end

function evaluate!(b::SineBlock, t, _dt)
    b.base.outputs[:out].value =
        b.amplitude * sin(2π * b.frequency * t + b.phase) + b.offset
end

initialize!(::SineBlock) = nothing

# ------------------------------------------

mutable struct RampBlock <: AbstractBlock
    base       :: BlockBase
    slope      :: Float64
    start_time :: Float64
    bias       :: Float64
    name       :: String
    position   :: Tuple{Float64, Float64}
end

function RampBlock(; slope=1.0, start_time=0.0, bias=0.0,
                     name="ramp_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase(Symbol[], [:out])
    RampBlock(base, slope, start_time, bias, name, position)
end

function evaluate!(b::RampBlock, t, _dt)
    b.base.outputs[:out].value =
        b.bias + (t >= b.start_time ? b.slope * (t - b.start_time) : 0.0)
end

initialize!(::RampBlock) = nothing

# ------------------------------------------

mutable struct ClockBlock <: AbstractBlock
    base     :: BlockBase
    name     :: String
    position :: Tuple{Float64, Float64}
end

function ClockBlock(; name="clock_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase(Symbol[], [:out])
    ClockBlock(base, name, position)
end

function evaluate!(b::ClockBlock, t, _dt)
    b.base.outputs[:out].value = t
end

initialize!(::ClockBlock) = nothing

end
