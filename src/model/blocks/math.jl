module BlocksMath

using ..Types
using ..BlocksCommon
import ControlSystems
using LinearAlgebra

import ..BlocksAPI: evaluate!, commit_state!

export GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
       ProductBlock, SaturationBlock, AbsBlock,
       DerivativeBlock, PIDBlock, LookupTable1DBlock,
       TransferFnBlock, StateSpaceBlock

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

# ------------------------------------------

mutable struct ProductBlock <: AbstractBlock
    base :: BlockBase
    ops  :: Vector{Symbol}   # :mul or :div per input port
    name :: String
    position :: Tuple{Float64, Float64}
end

function ProductBlock(ops::Vector{Symbol}=[:mul, :mul];
                      name="prod_$(_next_id())", position=(0.0, 0.0))
    inputs = [Symbol("in$i") for i in 1:length(ops)]
    base   = BlockBase(inputs, [:out])
    ProductBlock(base, ops, name, position)
end

function evaluate!(b::ProductBlock, _t, _dt)
    result = 1.0
    for (i, op) in enumerate(b.ops)
        v = b.base.inputs[Symbol("in$i")].value
        result = op == :div ? result / v : result * v
    end
    b.base.outputs[:out].value = result
end

# ------------------------------------------

mutable struct SaturationBlock <: AbstractBlock
    base  :: BlockBase
    lower :: Float64
    upper :: Float64
    name  :: String
    position :: Tuple{Float64, Float64}
end

function SaturationBlock(; lower=-1.0, upper=1.0,
                           name="sat_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    SaturationBlock(base, lower, upper, name, position)
end

function evaluate!(b::SaturationBlock, _t, _dt)
    b.base.outputs[:out].value = clamp(b.base.inputs[:in].value, b.lower, b.upper)
end

# ------------------------------------------

mutable struct AbsBlock <: AbstractBlock
    base     :: BlockBase
    name     :: String
    position :: Tuple{Float64, Float64}
end

function AbsBlock(; name="abs_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    AbsBlock(base, name, position)
end

function evaluate!(b::AbsBlock, _t, _dt)
    b.base.outputs[:out].value = abs(b.base.inputs[:in].value)
end

# ------------------------------------------

mutable struct DerivativeBlock <: AbstractBlock
    base       :: BlockBase
    N          :: Float64   # filter bandwidth: H(s) = Ns/(s+N)
    state      :: Float64   # filter state fd
    next_state :: Float64
    name       :: String
    position   :: Tuple{Float64, Float64}
end

function DerivativeBlock(; N=100.0, name="deriv_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    DerivativeBlock(base, N, 0.0, 0.0, name, position)
end

function evaluate!(b::DerivativeBlock, _t, dt)
    u = b.base.inputs[:in].value
    b.base.outputs[:out].value = b.N * (u - b.state)
    b.next_state = b.state + b.N * (u - b.state) * dt
end

function commit_state!(b::DerivativeBlock)
    b.state = b.next_state
end

# ------------------------------------------

mutable struct PIDBlock <: AbstractBlock
    base    :: BlockBase
    Kp      :: Float64
    Ki      :: Float64
    Kd      :: Float64
    N       :: Float64   # derivative filter coefficient
    out_min :: Float64
    out_max :: Float64
    xi      :: Float64   # integrator state
    fd      :: Float64   # derivative filter state
    xi_next :: Float64
    fd_next :: Float64
    name    :: String
    position :: Tuple{Float64, Float64}
end

function PIDBlock(; Kp=1.0, Ki=0.1, Kd=0.0, N=100.0,
                   out_min=-Inf, out_max=Inf,
                   name="pid_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    PIDBlock(base, Kp, Ki, Kd, N, out_min, out_max,
             0.0, 0.0, 0.0, 0.0, name, position)
end

function evaluate!(b::PIDBlock, _t, dt)
    e  = b.base.inputs[:in].value
    p  = b.Kp * e
    i  = b.Ki * b.xi
    d  = b.Kd * b.N * (e - b.fd)
    b.base.outputs[:out].value = clamp(p + i + d, b.out_min, b.out_max)
    b.xi_next = b.xi + e * dt
    b.fd_next = b.fd + b.N * (e - b.fd) * dt
end

function commit_state!(b::PIDBlock)
    b.xi = b.xi_next
    b.fd = b.fd_next
end

# ------------------------------------------

mutable struct LookupTable1DBlock <: AbstractBlock
    base     :: BlockBase
    bp       :: Vector{Float64}   # breakpoints (must be sorted ascending)
    vals     :: Vector{Float64}   # corresponding output values
    name     :: String
    position :: Tuple{Float64, Float64}
end

function LookupTable1DBlock(bp::Vector{Float64}=[0.0, 1.0],
                             vals::Vector{Float64}=[0.0, 1.0];
                             name="lut_$(_next_id())", position=(0.0, 0.0))
    length(bp) == length(vals) || error("LookupTable1DBlock: bp and vals must be the same length")
    base = BlockBase([:in], [:out])
    LookupTable1DBlock(base, bp, vals, name, position)
end

function evaluate!(b::LookupTable1DBlock, _t, _dt)
    x  = b.base.inputs[:in].value
    bp = b.bp; v = b.vals
    y  = if x <= bp[1]
        v[1]
    elseif x >= bp[end]
        v[end]
    else
        i = searchsortedfirst(bp, x)
        t = (x - bp[i-1]) / (bp[i] - bp[i-1])
        v[i-1] + t * (v[i] - v[i-1])
    end
    b.base.outputs[:out].value = y
end

# ------------------------------------------
# ZOH discretization helper (Van Loan augmented-matrix method)
# Computes Φ = expm(A·dt) and Γ = ∫₀ᵈᵗ expm(A·s)·B ds
# by forming the (n+1)×(n+1) augmented matrix [A B; 0 0]·dt.
# ------------------------------------------
function _zoh_discretize(A::Matrix{Float64}, B::Vector{Float64}, dt::Float64)
    n = size(A, 1)
    M = zeros(n + 1, n + 1)
    M[1:n, 1:n] = A
    M[1:n, n+1] = B
    eM = exp(M * dt)
    eM[1:n, 1:n], eM[1:n, n+1]
end

# ------------------------------------------
# TransferFnBlock
# Continuous-time SISO transfer function H(s) = num(s)/den(s).
# Coefficients are highest-power-first (ControlSystems.jl convention).
# Uses ControlSystems.jl for minimal-realization TF→SS conversion,
# then ZOH-discretizes lazily on the first evaluate! call.
# ------------------------------------------

mutable struct TransferFnBlock <: AbstractBlock
    base      :: BlockBase
    num       :: Vector{Float64}
    den       :: Vector{Float64}
    A_c       :: Matrix{Float64}
    B_c       :: Vector{Float64}
    C_c       :: Vector{Float64}
    D_c       :: Float64
    x         :: Vector{Float64}
    x_next    :: Vector{Float64}
    Φ         :: Matrix{Float64}
    Γ         :: Vector{Float64}
    dt_cached :: Float64
    name      :: String
    position  :: Tuple{Float64, Float64}
end

function TransferFnBlock(num::Vector{Float64}, den::Vector{Float64};
                          name = "tf_$(_next_id())", position = (0.0, 0.0))
    sys_ss = ControlSystems.ss(ControlSystems.tf(num, den))
    A_c = Float64.(sys_ss.A)
    B_c = Float64.(vec(sys_ss.B))
    C_c = Float64.(vec(sys_ss.C))
    D_c = Float64(sys_ss.D[1, 1])
    n   = size(A_c, 1)
    base = BlockBase([:in], [:out])
    TransferFnBlock(base, num, den, A_c, B_c, C_c, D_c,
                    zeros(n), zeros(n), zeros(n, n), zeros(n), -1.0,
                    name, position)
end

function evaluate!(b::TransferFnBlock, _t, dt)
    if !(b.dt_cached ≈ dt)
        b.Φ, b.Γ = _zoh_discretize(b.A_c, b.B_c, dt)
        b.dt_cached = dt
    end
    u = b.base.inputs[:in].value
    b.base.outputs[:out].value = dot(b.C_c, b.x) + b.D_c * u
    b.x_next = b.Φ * b.x + b.Γ * u
end

function commit_state!(b::TransferFnBlock)
    b.x .= b.x_next
end

# ------------------------------------------
# StateSpaceBlock
# Continuous-time SISO state-space: ẋ = A·x + B·u, y = C·x + D·u.
# ZOH-discretized lazily on first evaluate! call.
# ------------------------------------------

mutable struct StateSpaceBlock <: AbstractBlock
    base      :: BlockBase
    A_c       :: Matrix{Float64}
    B_c       :: Vector{Float64}
    C_c       :: Vector{Float64}
    D_c       :: Float64
    x         :: Vector{Float64}
    x_next    :: Vector{Float64}
    Φ         :: Matrix{Float64}
    Γ         :: Vector{Float64}
    dt_cached :: Float64
    name      :: String
    position  :: Tuple{Float64, Float64}
end

function StateSpaceBlock(A::Matrix{Float64},
                          B::Union{Matrix{Float64}, Vector{Float64}},
                          C::Union{Matrix{Float64}, Vector{Float64}},
                          D::Float64 = 0.0;
                          name = "ss_$(_next_id())", position = (0.0, 0.0))
    n   = size(A, 1)
    b_v = ndims(B) == 2 ? Float64.(vec(B)) : Float64.(B)
    c_v = ndims(C) == 2 ? Float64.(vec(C)) : Float64.(C)
    base = BlockBase([:in], [:out])
    StateSpaceBlock(base, A, b_v, c_v, D,
                    zeros(n), zeros(n), zeros(n, n), zeros(n), -1.0,
                    name, position)
end

function evaluate!(b::StateSpaceBlock, _t, dt)
    if !(b.dt_cached ≈ dt)
        b.Φ, b.Γ = _zoh_discretize(b.A_c, b.B_c, dt)
        b.dt_cached = dt
    end
    u = b.base.inputs[:in].value
    b.base.outputs[:out].value = dot(b.C_c, b.x) + b.D_c * u
    b.x_next = b.Φ * b.x + b.Γ * u
end

function commit_state!(b::StateSpaceBlock)
    b.x .= b.x_next
end

end
