module BlocksSinks

using ..Types
using ..BlocksCommon

import ..BlocksAPI: evaluate!

export ScopeBlock

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

end
