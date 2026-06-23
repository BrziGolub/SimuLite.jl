module BlocksSinks

using ..Types
using ..BlocksCommon

import ..BlocksAPI: evaluate!, initialize!

export ScopeBlock, WorkspaceBlock, TerminatorBlock

mutable struct ScopeBlock <: AbstractBlock
    base     :: BlockBase
    title    :: String
    n_ports  :: Int
    name     :: String
    position :: Tuple{Float64, Float64}
end

"""
    ScopeBlock(; title, n_ports, name, position)

Sink block that opens a separate plot window after simulation.
Each connected input port is plotted as a separate signal line.
"""
function ScopeBlock(; title="Scope", n_ports=1,
                     name="scope_$(_next_id())", position=(0.0, 0.0))
    inputs = [Symbol("in$i") for i in 1:n_ports]
    base   = BlockBase(inputs, Symbol[])
    ScopeBlock(base, title, n_ports, name, position)
end

evaluate!(::ScopeBlock, ::Any, ::Any) = nothing  # data read from SimResult via upstream connections
initialize!(::ScopeBlock) = nothing

# ------------------------------------------

mutable struct WorkspaceBlock <: AbstractBlock
    base     :: BlockBase
    name     :: String
    position :: Tuple{Float64, Float64}
end

"""
    WorkspaceBlock(; name, position)

Pass-through sink. Copies its input to its output so the runner logs the
signal under `name.out` in `SimResult.data`. The block name acts as the
variable name in the workspace.
"""
function WorkspaceBlock(; name="ws_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], [:out])
    WorkspaceBlock(base, name, position)
end

function evaluate!(b::WorkspaceBlock, _t, _dt)
    b.base.outputs[:out].value = b.base.inputs[:in].value
end

initialize!(::WorkspaceBlock) = nothing

# ------------------------------------------

mutable struct TerminatorBlock <: AbstractBlock
    base     :: BlockBase
    name     :: String
    position :: Tuple{Float64, Float64}
end

"""
    TerminatorBlock(; name, position)

Sink with one input and no outputs. Use it to cleanly cap an unconnected
output port without the diagram raising a missing-connection warning.
"""
function TerminatorBlock(; name="term_$(_next_id())", position=(0.0, 0.0))
    base = BlockBase([:in], Symbol[])
    TerminatorBlock(base, name, position)
end

evaluate!(::TerminatorBlock, ::Any, ::Any) = nothing
initialize!(::TerminatorBlock) = nothing

end
