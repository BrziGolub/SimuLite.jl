module Canvas

using GLMakie
using PrecompileTools
using ..Types
import ..BlocksAPI: input_ports, output_ports
import ..Diagram: connect!, add_block!, remove_block!, disconnect!
import ..BlocksSources: ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock
import ..BlocksMath: GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
                    ProductBlock, SaturationBlock, AbsBlock,
                    DerivativeBlock, PIDBlock, LookupTable1DBlock,
                    TransferFnBlock, StateSpaceBlock, set_tf_coeffs!
import ..BlocksSinks: ScopeBlock, WorkspaceBlock, TerminatorBlock
import ..Runner: simulate
using JSON3

export draw_diagram

const BLOCK_W  = 1.2
const BLOCK_H  = 0.85
const PORT_PX  = 12
const PORT_HIT = 0.18
const STRIP_FRAC = 0.30

const _WIRE_COLOR  = RGBf(0.19, 0.43, 0.69)
const _SEL_COLOR   = RGBf(0.12, 0.56, 1.00)
const _ORA_COLOR   = RGBf(1.00, 0.55, 0.00)

const _BLUE_BORDER = RGBf(0.19, 0.43, 0.69)
const _BLUE_ICON   = RGBf(0.93, 0.96, 1.00)
const _AMGR_BORDER = RGBf(0.75, 0.40, 0.05)
const _AMGR_ICON   = RGBf(0.99, 0.95, 0.88)
const _GRNN_BORDER = RGBf(0.20, 0.60, 0.25)
const _GRNN_ICON   = RGBf(0.92, 0.98, 0.93)

# UI chrome palette (Section 5 wireframe — "GLMakie-realistic editor")
const _WIN_BG     = RGBf(0.914, 0.914, 0.914)   # #e9e9e9 window background
const _TB_BG      = RGBf(0.871, 0.871, 0.871)   # #dedede toolbar / title strips
const _PANEL_BG   = RGBf(0.953, 0.953, 0.953)   # #f3f3f3 palette / dialog body
const _PANEL_BRD  = RGBf(0.706, 0.706, 0.706)   # #b4b4b4 panel borders
const _BTN_BG     = RGBf(0.831, 0.831, 0.831)   # #d4d4d4 button face
const _BTN_BRD    = RGBf(0.620, 0.620, 0.620)   # #9e9e9e button border
const _RUN_GREEN  = RGBf(0.184, 0.620, 0.357)   # #2f9e5b Run button
const _RUN_BRD    = RGBf(0.149, 0.502, 0.286)   # #268049 Run button border
const _MAKIE_BLUE = RGBf(0.000, 0.447, 0.698)   # #0072B2 accent (toggles, chips, Apply)
const _CHIP_BRD   = RGBf(0.769, 0.769, 0.769)   # #c4c4c4 palette chip border
const _INK        = RGBf(0.122, 0.122, 0.122)   # #1f1f1f primary text
const _MUTED      = RGBf(0.267, 0.267, 0.267)   # #444444 secondary text / field labels
const _CANVAS_GRID = RGBf(0.86, 0.86, 0.86)     # neutral grid dots on white canvas
const _PAL_CHIP_W  = 180   # palette chip width: 236 − 2×10 pad − 28 icon col − 8 gap

# Default canvas view extents; the toolbar zoom percentage is relative to this
# x-span (100% = the default view).
const _CANVAS_XLIM = (-2.0, 14.0)
const _CANVAS_YLIM = (-6.0, 6.0)

_block_height(block) =
    max(BLOCK_H, PORT_HIT * 1.4 * (max(length(input_ports(block)),
                                        length(output_ports(block))) + 1))

# ── Internal visual tracking ──────────────────────────────────────────────────

mutable struct BlockVisual
    strip        :: Any
    icon         :: Any
    border       :: Any
    divider      :: Any
    sym          :: Any
    label        :: Any
    ports        :: Vector{Any}
    border_color :: RGBf
    extras       :: Vector{Any}   # block-specific decorations (e.g. Sum sign glyphs)
    input_sides  :: Dict{Symbol, Observable{Symbol}}   # Sum: per-input :left/:bottom
end

mutable struct ConnVisual
    curve :: Any
    arrow :: Any
end

# ── Undo / Redo action types ──────────────────────────────────────────────────

abstract type UndoAction end

struct AddBlockAction <: UndoAction
    block :: AbstractBlock
end

struct DeleteBlockAction <: UndoAction
    block         :: AbstractBlock
    removed_conns :: Vector{Tuple{AbstractBlock, Symbol, AbstractBlock, Symbol}}
end

struct MoveBlockAction <: UndoAction
    block   :: AbstractBlock
    old_pos :: Tuple{Float64, Float64}
    new_pos :: Tuple{Float64, Float64}
end

struct AddConnectionAction <: UndoAction
    src_block :: AbstractBlock
    src_port  :: Symbol
    dst_block :: AbstractBlock
    dst_port  :: Symbol
end

struct DeleteConnectionAction <: UndoAction
    src_block :: AbstractBlock
    src_port  :: Symbol
    dst_block :: AbstractBlock
    dst_port  :: Symbol
end

# ── Block type icons and colors ───────────────────────────────────────────────

function _block_icon(block)
    if     block isa ConstantBlock      return ("1",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa StepBlock          return ("⎍",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa SineBlock          return ("∿",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa RampBlock          return ("╱",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa ClockBlock         return ("⏱",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa GainBlock          return ("▷",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa SumBlock           return ("Σ",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa IntegratorBlock    return ("∫",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa UnitDelayBlock     return ("z⁻¹",  _BLUE_BORDER, _BLUE_ICON)
    elseif block isa ProductBlock       return ("×",    _BLUE_BORDER, _BLUE_ICON)
    elseif block isa SaturationBlock    return ("sat",  _BLUE_BORDER, _BLUE_ICON)
    elseif block isa AbsBlock           return ("|u|",  _BLUE_BORDER, _BLUE_ICON)
    elseif block isa DerivativeBlock    return ("d/dt", _BLUE_BORDER, _BLUE_ICON)
    elseif block isa PIDBlock           return ("PID",  _AMGR_BORDER, _AMGR_ICON)
    elseif block isa LookupTable1DBlock return ("f(x)", _BLUE_BORDER, _BLUE_ICON)
    elseif block isa TransferFnBlock    return ("H(s)", _BLUE_BORDER, _BLUE_ICON)
    elseif block isa StateSpaceBlock    return ("SS",   _BLUE_BORDER, _BLUE_ICON)
    elseif block isa ScopeBlock         return ("∿",    _GRNN_BORDER, _GRNN_ICON)
    elseif block isa WorkspaceBlock     return ("ws",   _GRNN_BORDER, _GRNN_ICON)
    elseif block isa TerminatorBlock    return ("▪",    _GRNN_BORDER, _GRNN_ICON)
    else                                return ("?",    _BLUE_BORDER, _BLUE_ICON)
    end
end

# ── Geometry helpers ──────────────────────────────────────────────────────────

# Densely sample a right-angle polyline through `corners`, so the arrowhead and
# hit-testing (which read the returned point list) keep working unchanged.
function _ortho_pts(corners; step = 0.06)
    xs = Float64[]; ys = Float64[]
    for k in 1:length(corners) - 1
        ax0, ay0 = corners[k]
        bx0, by0 = corners[k + 1]
        m = max(2, ceil(Int, hypot(bx0 - ax0, by0 - ay0) / step))
        for j in 0:m - 1
            t = j / m
            push!(xs, ax0 + t * (bx0 - ax0))
            push!(ys, ay0 + t * (by0 - ay0))
        end
    end
    push!(xs, corners[end][1]); push!(ys, corners[end][2])
    xs, ys
end

# Route a connection from (x0,y0) to (x1,y1). Forward connections get a smooth
# S-curve; feedback connections (destination left of source) get a right-angle
# route through a channel below the blocks, rising vertically into the port.
function _bezier(x0, y0, x1, y1; n=60)
    if x1 >= x0 - 0.1
        dx = max((x1 - x0) * 0.45, 0.35)
        cx0, cy0 = x0 + dx, y0
        cx1, cy1 = x1 - dx, y1
        xs = Vector{Float64}(undef, n)
        ys = Vector{Float64}(undef, n)
        for i in 1:n
            t = (i - 1) / (n - 1)
            s = 1 - t
            xs[i] = s^3*x0 + 3s^2*t*cx0 + 3s*t^2*cx1 + t^3*x1
            ys[i] = s^3*y0 + 3s^2*t*cy0 + 3s*t^2*cy1 + t^3*y1
        end
        return xs, ys
    else
        stub = 0.3
        drop = max((x0 - x1) * 0.12, 0.9)
        ych  = min(y0, y1) - drop
        return _ortho_pts([(x0, y0), (x0 + stub, y0),
                           (x0 + stub, ych), (x1, ych), (x1, y1)])
    end
end

function _arrowhead(src::Point2f, dst::Point2f)
    xs, ys = _bezier(src[1], src[2], dst[1], dst[2])
    n = length(xs)
    ddx, ddy = xs[n] - xs[n-1], ys[n] - ys[n-1]
    len = sqrt(ddx^2 + ddy^2)
    len < 1e-10 && return Point2f[dst, dst, dst]
    ux, uy = ddx / len, ddy / len
    px, py = -uy, ux
    sz = 0.07
    Point2f[
        dst,
        Point2f(dst[1] - sz*ux + (sz/2)*px, dst[2] - sz*uy + (sz/2)*py),
        Point2f(dst[1] - sz*ux - (sz/2)*px, dst[2] - sz*uy - (sz/2)*py),
    ]
end

function _hit_block(center, pos, bh = BLOCK_H)
    abs(pos[1] - center[1]) <= BLOCK_W / 2 &&
    abs(pos[2] - center[2]) <= bh / 2
end

function _hit_port(port_pos, pos)
    for (key, obs) in port_pos
        pp = obs[]
        dx = Float64(pos[1]) - Float64(pp[1])
        dy = Float64(pos[2]) - Float64(pp[2])
        dx^2 + dy^2 < PORT_HIT^2 && return key
    end
    return nothing
end

function _hit_connection(conn, port_pos, pos; tol = 0.12)
    src_obs = port_pos[(conn.src_block, conn.src_port)]
    dst_obs = port_pos[(conn.dst_block, conn.dst_port)]
    p0, p1  = src_obs[], dst_obs[]
    xs, ys  = _bezier(p0[1], p0[2], p1[1], p1[2])
    px, py  = Float64(pos[1]), Float64(pos[2])
    for i in eachindex(xs)
        (xs[i] - px)^2 + (ys[i] - py)^2 < tol^2 && return true
    end
    return false
end

# ── Sum block (circular, Simulink-style) ──────────────────────────────────────

# Angle (rad) of the i-th of ni input ports on the left arc of the circle.
# in1 sits at the top, inN at the bottom; measured about π (the left edge).
function _sum_input_angle(i, ni)
    ni == 1 && return Float64(π)
    fr     = (i - 1) / (ni - 1) - 0.5          # -0.5 (top) … +0.5 (bottom)
    spread = min(1.8, 0.7 * (ni - 1))
    return π + spread * fr
end

# Position of the i-th input port on the circle. A `:left` port sits on the left
# arc; a `:bottom` port (fed by a feedback wire) sits at the bottom of the circle.
function _sum_port_point(c, bh, i, ni, side)
    r = bh / 2
    θ = side === :bottom ? 3π/2 : _sum_input_angle(i, ni)
    Point2f(c[1] + r * cos(θ), c[2] + r * sin(θ))
end
function _sum_glyph_point(c, bh, i, ni, side)
    r = bh / 2
    θ = side === :bottom ? 3π/2 : _sum_input_angle(i, ni)
    Point2f(c[1] + 0.60r * cos(θ), c[2] + 0.60r * sin(θ))
end

# Create the scatter + sign glyph for one Sum input port. The port's `side`
# Observable (:left / :bottom) is flipped by `_refresh_feedback_sides!` so the
# dot, glyph and wire all follow reactively. Returns (scatter, text, side).
function _sum_add_input!(ax, block, p, i, ni, c, bh_obs, bdr, port_pos, port_type)
    side = Observable(:left)
    port_pos[(block, p)]  = @lift _sum_port_point($c, $bh_obs, i, ni, $side)
    port_type[(block, p)] = :input
    scat = scatter!(ax, @lift([$(port_pos[(block, p)])]);
        color = RGBf(0.25, 0.45, 0.75), markersize = PORT_PX)

    glyph = block.signs[i] == '+' ? "+" : "−"
    gpos  = @lift _sum_glyph_point($c, $bh_obs, i, ni, $side)
    txt = text!(ax, @lift([$gpos]); text = [glyph],
        align = (:center, :center), fontsize = 15, color = bdr)
    return scat, txt, side
end

function _setup_sum_visual!(ax, block, c, sc, bh_obs, port_pos, port_type, bdr_color, icon_bg)
    ni = length(block.signs)

    # Filled circle; stroke colour is the selectable Observable `sc`.
    circle_pts = @lift begin
        r = $bh_obs / 2
        [Point2f($c[1] + r * cos(2π * (k - 1) / 48), $c[2] + r * sin(2π * (k - 1) / 48))
         for k in 1:48]
    end
    circle = poly!(ax, circle_pts; color = icon_bg, strokecolor = sc, strokewidth = 2)

    # Input ports on the left arc (in1 top → inN bottom), each with its sign glyph.
    port_plots  = Any[]
    extras      = Any[]
    input_sides = Dict{Symbol, Observable{Symbol}}()
    for i in 1:ni
        p = Symbol("in$i")
        scat, txt, side = _sum_add_input!(ax, block, p, i, ni,
                                           c, bh_obs, bdr_color, port_pos, port_type)
        push!(port_plots, scat)
        push!(extras, txt)
        input_sides[p] = side
    end

    # Output port on the right edge.
    port_pos[(block, :out)]  = @lift Point2f($c[1] + $bh_obs / 2, $c[2])
    port_type[(block, :out)] = :output
    push!(port_plots, scatter!(ax, @lift([$(port_pos[(block, :out)])]);
        color = RGBf(0.82, 0.28, 0.22), markersize = PORT_PX))

    # Name label below the circle.
    name_pos = @lift Point2f($c[1], $c[2] - $bh_obs / 2 - 0.10)
    label = text!(ax, @lift([$name_pos]); text = [block.name],
        align = (:center, :top), fontsize = 10, color = RGBf(0.20, 0.20, 0.20))

    return BlockVisual(nothing, nothing, circle, nothing, nothing,
                       label, port_plots, bdr_color, extras, input_sides)
end

# ── Block and connection draw helpers ─────────────────────────────────────────

function _setup_block!(ax, block, block_centers, block_strokes, block_heights, port_pos, port_type)
    cx, cy = block.position
    bh_obs = Observable(_block_height(block))
    c      = Observable(Point2f(cx, cy))

    sym_text, bdr_color, icon_bg = _block_icon(block)
    sc = Observable{Any}(bdr_color)
    block_centers[block]  = c
    block_strokes[block]  = sc
    block_heights[block]  = bh_obs

    if block isa SumBlock
        return _setup_sum_visual!(ax, block, c, sc, bh_obs, port_pos, port_type,
                                  bdr_color, icon_bg)
    end

    iports = input_ports(block)
    oports = output_ports(block)
    ni, no = length(iports), length(oports)

    for (i, p) in enumerate(iports)
        frac = Float64(i) / (ni + 1) - 0.5
        port_pos[(block, p)]  = @lift Point2f($c[1] - BLOCK_W/2, $c[2] + $bh_obs * frac)
        port_type[(block, p)] = :input
    end
    for (i, p) in enumerate(oports)
        frac = Float64(i) / (no + 1) - 0.5
        port_pos[(block, p)]  = @lift Point2f($c[1] + BLOCK_W/2, $c[2] + $bh_obs * frac)
        port_type[(block, p)] = :output
    end

    strip_pts = @lift Point2f[
        ($c[1] - BLOCK_W/2, $c[2] - $bh_obs/2),
        ($c[1] + BLOCK_W/2, $c[2] - $bh_obs/2),
        ($c[1] + BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
        ($c[1] - BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
    ]
    strip = poly!(ax, strip_pts; color = :white, strokewidth = 0)

    icon_pts = @lift Point2f[
        ($c[1] - BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
        ($c[1] + BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
        ($c[1] + BLOCK_W/2, $c[2] + $bh_obs/2),
        ($c[1] - BLOCK_W/2, $c[2] + $bh_obs/2),
    ]
    icon = poly!(ax, icon_pts; color = icon_bg, strokewidth = 0)

    div_pts = @lift [
        Point2f($c[1] - BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
        Point2f($c[1] + BLOCK_W/2, $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC),
    ]
    divider = lines!(ax, div_pts; color = bdr_color, linewidth = 0.8)

    border_pts = @lift Point2f[
        ($c[1] - BLOCK_W/2, $c[2] - $bh_obs/2),
        ($c[1] + BLOCK_W/2, $c[2] - $bh_obs/2),
        ($c[1] + BLOCK_W/2, $c[2] + $bh_obs/2),
        ($c[1] - BLOCK_W/2, $c[2] + $bh_obs/2),
    ]
    border = poly!(ax, border_pts;
        color = (:white, 0f0), strokecolor = sc, strokewidth = 2)

    icon_center_y = @lift Point2f($c[1],
        $c[2] - $bh_obs/2 + $bh_obs*(STRIP_FRAC + (1f0 - STRIP_FRAC)/2f0))
    sym = text!(ax, @lift([$icon_center_y]);
        text = [sym_text], align = (:center, :center),
        fontsize = 15, color = bdr_color)

    strip_center_y = @lift Point2f($c[1], $c[2] - $bh_obs/2 + $bh_obs*STRIP_FRAC/2f0)
    label = text!(ax, @lift([$strip_center_y]);
        text = [block.name], align = (:center, :center),
        fontsize = 10, color = RGBf(0.20, 0.20, 0.20))

    port_plots = Any[]
    for p in iports
        push!(port_plots,
            scatter!(ax, @lift([$(port_pos[(block, p)])]);
                color = RGBf(0.25, 0.45, 0.75), markersize = PORT_PX))
    end
    for p in oports
        push!(port_plots,
            scatter!(ax, @lift([$(port_pos[(block, p)])]);
                color = RGBf(0.82, 0.28, 0.22), markersize = PORT_PX))
    end

    return BlockVisual(strip, icon, border, divider, sym, label, port_plots, bdr_color,
                       Any[], Dict{Symbol, Observable{Symbol}}())
end

function _add_connection_visual!(ax, conn, port_pos)
    src_obs = port_pos[(conn.src_block, conn.src_port)]
    dst_obs = port_pos[(conn.dst_block, conn.dst_port)]

    curve_pts = @lift begin
        p0, p1 = $src_obs, $dst_obs
        xs, ys = _bezier(p0[1], p0[2], p1[1], p1[2])
        Point2f.(xs, ys)
    end
    curve = lines!(ax, curve_pts; color = _WIRE_COLOR, linewidth = 1.8)

    arrow_pts = @lift _arrowhead($src_obs, $dst_obs)
    arrow = poly!(ax, arrow_pts; color = _WIRE_COLOR)

    return ConnVisual(curve, arrow)
end

function _delete_block!(ax, diagram, block,
                        block_centers, block_strokes, block_heights,
                        port_pos, port_type, block_visuals, conn_visuals)
    affected = filter(c -> c.src_block === block || c.dst_block === block,
                      diagram.connections)
    for conn in affected
        cv = get(conn_visuals, conn, nothing)
        cv === nothing && continue
        delete!(ax, cv.curve)
        delete!(ax, cv.arrow)
        delete!(conn_visuals, conn)
    end

    remove_block!(diagram, block)

    bv = block_visuals[block]
    for pl in (bv.strip, bv.icon, bv.border, bv.divider, bv.sym, bv.label)
        pl === nothing || delete!(ax, pl)
    end
    for s in bv.ports;  delete!(ax, s); end
    for e in bv.extras; delete!(ax, e); end

    for p in vcat(input_ports(block), output_ports(block))
        delete!(port_pos,  (block, p))
        delete!(port_type, (block, p))
    end
    delete!(block_visuals, block)
    delete!(block_centers, block)
    delete!(block_strokes, block)
    delete!(block_heights, block)
end

# ── Port reconfiguration (SumBlock / ScopeBlock) ─────────────────────────────

function _reconfigure_inputs!(ax, block, new_input_syms,
                               diagram, block_centers, block_heights,
                               port_pos, port_type, conn_visuals, block_visuals)
    old_syms     = input_ports(block)
    removed_syms = setdiff(Set(old_syms), Set(new_input_syms))

    # Delete visuals for ALL input-bound connections; re-create surviving ones after.
    affected_conns  = filter(c -> c.dst_block === block, diagram.connections)
    surviving_conns = Connection[]
    for conn in affected_conns
        cv = get(conn_visuals, conn, nothing)
        if cv !== nothing
            delete!(ax, cv.curve)
            delete!(ax, cv.arrow)
            delete!(conn_visuals, conn)
        end
        if conn.dst_port in removed_syms
            disconnect!(diagram, conn.src_block, conn.src_port, block, conn.dst_port)
        else
            push!(surviving_conns, conn)
        end
    end

    # Remove old input scatter plots (stored first in bv.ports).
    bv = block_visuals[block]
    n_old = length(old_syms)
    for i in 1:n_old; delete!(ax, bv.ports[i]); end
    bv.ports = bv.ports[n_old+1:end]   # keep only output plots

    for p in old_syms
        delete!(port_pos,  (block, p))
        delete!(port_type, (block, p))
    end

    # Rebuild block inputs and update reactive height.
    block.base.inputs = Dict(sym => Port(sym, 0.0) for sym in new_input_syms)
    bh_obs = block_heights[block]
    bh_obs[] = _block_height(block)

    # Create new input port observables and scatter plots.
    c  = block_centers[block]
    ni = length(new_input_syms)
    new_plots = Any[]
    for (i, p) in enumerate(new_input_syms)
        frac = Float64(i) / (ni + 1) - 0.5
        port_pos[(block, p)]  = @lift Point2f($c[1] - BLOCK_W/2, $c[2] + $bh_obs * frac)
        port_type[(block, p)] = :input
        push!(new_plots, scatter!(ax, @lift([$(port_pos[(block, p)])]);
            color = RGBf(0.25, 0.45, 0.75), markersize = PORT_PX))
    end
    bv.ports = vcat(new_plots, bv.ports)

    # Recreate connection visuals for surviving connections.
    for conn in surviving_conns
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
    end
end

# Reconfigure a Sum block to a new signs string: rebuilds arc input ports and
# sign glyphs. The circle itself (bv.border) auto-resizes via bh_obs.
function _reconfigure_sum_inputs!(ax, block, new_signs,
                                   diagram, block_centers, block_heights,
                                   port_pos, port_type, conn_visuals, block_visuals)
    old_syms = [Symbol("in$i") for i in 1:length(block.signs)]
    new_syms = [Symbol("in$i") for i in 1:length(new_signs)]
    removed  = setdiff(Set(old_syms), Set(new_syms))

    # Tear down all input-bound connection visuals; drop those on removed ports.
    affected_conns  = filter(c -> c.dst_block === block, diagram.connections)
    surviving_conns = Connection[]
    for conn in affected_conns
        cv = get(conn_visuals, conn, nothing)
        if cv !== nothing
            delete!(ax, cv.curve); delete!(ax, cv.arrow)
            delete!(conn_visuals, conn)
        end
        if conn.dst_port in removed
            disconnect!(diagram, conn.src_block, conn.src_port, block, conn.dst_port)
        else
            push!(surviving_conns, conn)
        end
    end

    # Remove old input scatters (stored first in bv.ports) and old sign glyphs.
    bv    = block_visuals[block]
    n_old = length(old_syms)
    for i in 1:n_old; delete!(ax, bv.ports[i]); end
    bv.ports = bv.ports[n_old+1:end]           # keep the output scatter
    for e in bv.extras; delete!(ax, e); end
    bv.extras = Any[]

    for p in old_syms
        delete!(port_pos,  (block, p))
        delete!(port_type, (block, p))
    end

    # Update model, then resize circle via bh_obs.
    block.signs       = new_signs
    block.base.inputs = Dict(sym => Port(sym, 0.0) for sym in new_syms)
    bh_obs = block_heights[block]
    bh_obs[] = _block_height(block)

    # Rebuild input ports + sign glyphs.
    c  = block_centers[block]
    ni = length(new_syms)
    new_plots, new_extras = Any[], Any[]
    new_sides = Dict{Symbol, Observable{Symbol}}()
    for i in 1:ni
        p = new_syms[i]
        scat, txt, side = _sum_add_input!(ax, block, p, i, ni,
                                           c, bh_obs, bv.border_color, port_pos, port_type)
        push!(new_plots, scat)
        push!(new_extras, txt)
        new_sides[p] = side
    end
    bv.ports       = vcat(new_plots, bv.ports)
    bv.extras      = new_extras
    bv.input_sides = new_sides

    for conn in surviving_conns
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
    end
end

# Re-evaluate which Sum inputs are fed by feedback (backward) wires and move
# those ports to the bottom of the circle; all others sit on the left arc.
# Idempotent — safe to call after any topology or position change.
function _refresh_feedback_sides!(diagram, block_centers, block_visuals)
    for (blk, bv) in block_visuals
        blk isa SumBlock || continue
        for (_, side) in bv.input_sides
            side[] === :left || (side[] = :left)
        end
    end
    for c in diagram.connections
        c.dst_block isa SumBlock || continue
        (haskey(block_centers, c.src_block) && haskey(block_centers, c.dst_block)) || continue
        if block_centers[c.src_block][][1] > block_centers[c.dst_block][][1]   # feedback
            bv = get(block_visuals, c.dst_block, nothing)
            bv === nothing && continue
            side = get(bv.input_sides, c.dst_port, nothing)
            side === nothing && continue
            side[] === :bottom || (side[] = :bottom)
        end
    end
end

# ── Save / Load ───────────────────────────────────────────────────────────────

function save_diagram(diagram::BlockDiagram, path::String)
    blocks_data = map(diagram.blocks) do b
        params = if b isa ConstantBlock
            Dict("value" => b.value)
        elseif b isa StepBlock
            Dict("step_time" => b.step_time, "before" => b.before, "after" => b.after)
        elseif b isa SineBlock
            Dict("amplitude" => b.amplitude, "frequency" => b.frequency,
                 "phase"     => b.phase,     "offset"    => b.offset)
        elseif b isa GainBlock
            Dict("k" => b.k)
        elseif b isa SumBlock
            Dict("signs" => b.signs)
        elseif b isa IntegratorBlock
            Dict("state" => b.state)
        elseif b isa UnitDelayBlock
            Dict("state" => b.state)
        elseif b isa ScopeBlock
            Dict("title" => b.title, "n_ports" => b.n_ports)
        elseif b isa RampBlock
            Dict("slope" => b.slope, "start_time" => b.start_time, "bias" => b.bias)
        elseif b isa ClockBlock
            Dict{String,Any}()
        elseif b isa ProductBlock
            Dict("ops" => [string(op) for op in b.ops])
        elseif b isa SaturationBlock
            Dict("lower" => b.lower, "upper" => b.upper)
        elseif b isa AbsBlock
            Dict{String,Any}()
        elseif b isa DerivativeBlock
            Dict("N" => b.N)
        elseif b isa PIDBlock
            Dict("Kp" => b.Kp, "Ki" => b.Ki, "Kd" => b.Kd, "N" => b.N,
                 "out_min" => b.out_min, "out_max" => b.out_max)
        elseif b isa LookupTable1DBlock
            Dict("bp" => b.bp, "vals" => b.vals)
        elseif b isa TransferFnBlock
            Dict("num" => b.num, "den" => b.den)
        elseif b isa StateSpaceBlock
            Dict("A" => [collect(b.A_c[i, :]) for i in 1:size(b.A_c, 1)],
                 "B" => b.B_c, "C" => b.C_c, "D" => b.D_c)
        elseif b isa WorkspaceBlock
            Dict{String,Any}()
        elseif b isa TerminatorBlock
            Dict{String,Any}()
        else
            Dict{String,Any}()
        end
        Dict("type"     => string(nameof(typeof(b))),
             "name"     => b.name,
             "position" => [b.position[1], b.position[2]],
             "params"   => params)
    end

    conns_data = map(diagram.connections) do c
        Dict("src"      => c.src_block.name,
             "src_port" => string(c.src_port),
             "dst"      => c.dst_block.name,
             "dst_port" => string(c.dst_port))
    end

    data = Dict(
        "config"      => Dict("tspan" => [diagram.config.tspan[1], diagram.config.tspan[2]],
                              "dt"    => diagram.config.dt),
        "blocks"      => blocks_data,
        "connections" => conns_data)

    open(path, "w") do io; JSON3.write(io, data); end
end

function _reconstruct_block(type_name::String, name::String, position, params)
    pf(k, d) = Float64(get(params, k, d))
    ps(k, d) = String(get(params, k, d))

    b = if type_name == "ConstantBlock"
        ConstantBlock(pf(:value, 0.0))
    elseif type_name == "StepBlock"
        StepBlock(; step_time = pf(:step_time, 1.0),
                    before    = pf(:before, 0.0),
                    after     = pf(:after, 1.0))
    elseif type_name == "SineBlock"
        SineBlock(; amplitude = pf(:amplitude, 1.0),
                    frequency = pf(:frequency, 1.0),
                    phase     = pf(:phase, 0.0),
                    offset    = pf(:offset, 0.0))
    elseif type_name == "GainBlock"
        GainBlock(pf(:k, 1.0))
    elseif type_name == "SumBlock"
        SumBlock(ps(:signs, "++"))
    elseif type_name == "IntegratorBlock"
        IntegratorBlock(pf(:state, 0.0))
    elseif type_name == "UnitDelayBlock"
        UnitDelayBlock(pf(:state, 0.0))
    elseif type_name == "ScopeBlock"
        ScopeBlock(; title   = ps(:title, "Scope"),
                     n_ports = Int(get(params, :n_ports, 1)))
    elseif type_name == "RampBlock"
        RampBlock(; slope      = pf(:slope, 1.0),
                    start_time = pf(:start_time, 0.0),
                    bias       = pf(:bias, 0.0))
    elseif type_name == "ClockBlock"
        ClockBlock()
    elseif type_name == "ProductBlock"
        ops_raw = get(params, :ops, ["mul", "mul"])
        ProductBlock([Symbol(s) for s in ops_raw])
    elseif type_name == "SaturationBlock"
        SaturationBlock(; lower = pf(:lower, -1.0), upper = pf(:upper, 1.0))
    elseif type_name == "AbsBlock"
        AbsBlock()
    elseif type_name == "DerivativeBlock"
        DerivativeBlock(; N = pf(:N, 100.0))
    elseif type_name == "PIDBlock"
        PIDBlock(; Kp      = pf(:Kp, 1.0),
                   Ki      = pf(:Ki, 0.1),
                   Kd      = pf(:Kd, 0.0),
                   N       = pf(:N, 100.0),
                   out_min = pf(:out_min, -Inf),
                   out_max = pf(:out_max,  Inf))
    elseif type_name == "LookupTable1DBlock"
        bp   = Float64[Float64(x) for x in get(params, :bp,   [0.0, 1.0])]
        vals = Float64[Float64(x) for x in get(params, :vals, [0.0, 1.0])]
        LookupTable1DBlock(bp, vals)
    elseif type_name == "TransferFnBlock"
        num = Float64[Float64(x) for x in get(params, :num, [1.0])]
        den = Float64[Float64(x) for x in get(params, :den, [1.0, 1.0])]
        TransferFnBlock(num, den)
    elseif type_name == "StateSpaceBlock"
        A_rows = get(params, :A, [[-1.0]])
        n = length(A_rows)
        A_mat = reduce(vcat,
            [reshape(Float64[Float64(x) for x in row], 1, n) for row in A_rows])
        B_vec = Float64[Float64(x) for x in get(params, :B, [1.0])]
        C_vec = Float64[Float64(x) for x in get(params, :C, [1.0])]
        D_val = pf(:D, 0.0)
        StateSpaceBlock(A_mat, B_vec, C_vec, D_val)
    elseif type_name == "WorkspaceBlock"
        WorkspaceBlock()
    elseif type_name == "TerminatorBlock"
        TerminatorBlock()
    else
        error("Unknown block type in file: $type_name")
    end
    b.name     = name
    b.position = (Float64(position[1]), Float64(position[2]))
    return b
end

# ── Scope window ──────────────────────────────────────────────────────────────

function _open_scope_window!(scope_block, result, diagram, scope_screens)
    if haskey(scope_screens, scope_block)
        prev = scope_screens[scope_block]
        try
            prev.window_open[] && close(prev)
        catch _
        end
        delete!(scope_screens, scope_block)
    end

    fig = Figure(size = (720, 460))
    ax  = Axis(fig[1, 1];
        title      = scope_block.title,
        xlabel     = "t (s)",
        ylabel     = "signal",
        titlesize  = 14,
        xlabelsize = 12,
        ylabelsize = 12)

    n_plotted = 0
    colors = [:royalblue, :firebrick, :forestgreen]
    for i in 1:scope_block.n_ports
        port_sym = Symbol("in$i")
        for c in diagram.connections
            if c.dst_block === scope_block && c.dst_port == port_sym
                key = "$(c.src_block.name).$(c.src_port)"
                if haskey(result.data, key)
                    lines!(ax, result.t, result.data[key];
                        label = key, color = colors[mod1(i, 3)], linewidth = 2)
                    n_plotted += 1
                end
                break
            end
        end
    end

    n_plotted == 0 && return
    n_plotted > 1 && axislegend(ax; position = :lt)
    autolimits!(ax)

    screen = GLMakie.Screen(title = "∿ $(scope_block.title) — $(scope_block.name)")
    display(screen, fig)
    scope_screens[scope_block] = screen
end

# ── Properties window ─────────────────────────────────────────────────────────

# "1, 0.8 1" → [1.0, 0.8, 1.0]; empty vector signals a parse failure
function _parse_coeffs(s::AbstractString)
    try
        return parse.(Float64, split(s, r"[,\s]+"; keepempty = false))
    catch
        return Float64[]
    end
end

function _open_props_window!(block, block_visuals, prop_screens,
                             ax, diagram, block_centers, block_heights,
                             port_pos, port_type, conn_visuals)
    if haskey(prop_screens, block)
        prev = prop_screens[block]
        try; prev.window_open[] && close(prev); catch _; end
        delete!(prop_screens, block)
    end

    bv  = block_visuals[block]
    fig = Figure(size = (360, 430), backgroundcolor = _PANEL_BG,
        figure_padding = 0)

    # Title strip (Section 5: 34 px, #dedede, 1 px border)
    Box(fig[1, 1]; color = _TB_BG, strokecolor = _PANEL_BRD, strokewidth = 1)
    Label(fig[1, 1], "Block Parameters — " * block.name;
        fontsize = 13, font = :bold, halign = :left, padding = (12, 0, 0, 0),
        color = _INK, tellwidth = false)
    rowsize!(fig.layout, 1, Fixed(34))
    rowgap!(fig.layout, 0)

    # Field grid: 104 px label column + white textboxes (Section 5)
    g = GridLayout(fig[2, 1]; alignmode = Outside(14), valign = :top,
        tellheight = false)
    colsize!(g, 1, Fixed(104))
    rowgap!(g, 11)

    # Fields commit on Apply (Section 5 Apply/Cancel semantics): each entry
    # reads its textbox's current text and writes it into the block.
    appliers = Function[]
    row = Ref(1)

    function add_field!(fname, value; commit = nothing)
        r = row[]
        row[] += 1
        Label(g[r, 1], fname; halign = :left, fontsize = 12, color = _MUTED,
            tellwidth = true)
        # Explicit width — a Textbox does not stretch to fill its grid cell,
        # long values would otherwise overflow the drawn box.
        tb = Textbox(g[r, 2]; displayed_string = value, tellwidth = false,
            width = 205, fontsize = 12, height = 28, boxcolor = :white,
            bordercolor = _BTN_BRD)
        commit === nothing || push!(appliers, () -> commit(tb.displayed_string[]))
        return tb
    end

    function add_info!(text)
        Label(g[row[], 1:2], text; fontsize = 11, halign = :left,
              color = RGBf(0.40, 0.40, 0.40), tellwidth = false)
        row[] += 1
    end

    add_field!("Name", block.name; commit = s -> begin
        block.name = s
        bv.label.text[] = [s]
    end)

    if block isa ConstantBlock
        add_field!("Value", string(block.value);
            commit = s -> block.value = parse(Float64, s))
    elseif block isa StepBlock
        add_field!("Step time", string(block.step_time);
            commit = s -> block.step_time = parse(Float64, s))
        add_field!("Before",    string(block.before);
            commit = s -> block.before    = parse(Float64, s))
        add_field!("After",     string(block.after);
            commit = s -> block.after     = parse(Float64, s))
    elseif block isa SineBlock
        add_field!("Amplitude", string(block.amplitude);
            commit = s -> block.amplitude = parse(Float64, s))
        add_field!("Frequency", string(block.frequency);
            commit = s -> block.frequency = parse(Float64, s))
        add_field!("Phase",     string(block.phase);
            commit = s -> block.phase     = parse(Float64, s))
        add_field!("Offset",    string(block.offset);
            commit = s -> block.offset    = parse(Float64, s))
    elseif block isa RampBlock
        add_field!("Slope",      string(block.slope);
            commit = s -> block.slope      = parse(Float64, s))
        add_field!("Start time", string(block.start_time);
            commit = s -> block.start_time = parse(Float64, s))
        add_field!("Bias",       string(block.bias);
            commit = s -> block.bias       = parse(Float64, s))
    elseif block isa GainBlock
        add_field!("k", string(block.k);
            commit = s -> block.k = parse(Float64, s))
    elseif block isa SumBlock
        add_field!("Signs (+/−)", block.signs; commit = s -> begin
            (isempty(s) || !all(c -> c == '+' || c == '-', s)) && return
            _reconfigure_sum_inputs!(ax, block, s, diagram,
                block_centers, block_heights, port_pos, port_type,
                conn_visuals, block_visuals)
            _refresh_feedback_sides!(diagram, block_centers, block_visuals)
        end)
    elseif block isa IntegratorBlock
        add_field!("x0 (init)", string(block.x0); commit = s -> begin
            v = parse(Float64, s)
            block.x0         = v
            block.state      = v
            block.next_state = v
        end)
    elseif block isa UnitDelayBlock
        add_field!("x0 (init)", string(block.x0); commit = s -> begin
            v = parse(Float64, s)
            block.x0         = v
            block.state      = v
            block.next_state = v
        end)
    elseif block isa SaturationBlock
        add_field!("Lower", string(block.lower);
            commit = s -> block.lower = parse(Float64, s))
        add_field!("Upper", string(block.upper);
            commit = s -> block.upper = parse(Float64, s))
    elseif block isa DerivativeBlock
        add_field!("N (bandwidth)", string(block.N);
            commit = s -> block.N = parse(Float64, s))
    elseif block isa PIDBlock
        add_field!("Kp",      string(block.Kp);
            commit = s -> block.Kp      = parse(Float64, s))
        add_field!("Ki",      string(block.Ki);
            commit = s -> block.Ki      = parse(Float64, s))
        add_field!("Kd",      string(block.Kd);
            commit = s -> block.Kd      = parse(Float64, s))
        add_field!("N",       string(block.N);
            commit = s -> block.N       = parse(Float64, s))
        add_field!("Out min", string(block.out_min);
            commit = s -> block.out_min = parse(Float64, s))
        add_field!("Out max", string(block.out_max);
            commit = s -> block.out_max = parse(Float64, s))
    elseif block isa ScopeBlock
        add_field!("Title", block.title; commit = s -> block.title = s)
        add_field!("Ports (1–3)", string(block.n_ports); commit = s -> begin
            n = clamp(parse(Int, s), 1, 3)
            if n != block.n_ports
                new_syms = [Symbol("in$i") for i in 1:n]
                _reconfigure_inputs!(ax, block, new_syms, diagram,
                    block_centers, block_heights, port_pos, port_type,
                    conn_visuals, block_visuals)
                block.n_ports = n
            end
        end)
    elseif block isa ProductBlock
        ops_str = join(block.ops, ", ")
        add_info!("Ports: $(length(block.ops))  ops: $ops_str")
    elseif block isa LookupTable1DBlock
        add_info!("$(length(block.bp))-pt table (edit breakpoints in code)")
    elseif block isa TransferFnBlock
        # num and den commit together so a change spanning both fields cannot
        # be rejected half-applied (e.g. raising the order of num and den).
        tb_num = add_field!("Numerator",   join(block.num, ", "))
        tb_den = add_field!("Denominator", join(block.den, ", "))
        add_info!("H(s) = num(s)/den(s), coefficients high → low order")
        push!(appliers, () -> begin
            num = _parse_coeffs(tb_num.displayed_string[])
            den = _parse_coeffs(tb_den.displayed_string[])
            (isempty(num) || isempty(den)) && return
            (num == block.num && den == block.den) && return
            set_tf_coeffs!(block, num, den)
        end)
    elseif block isa StateSpaceBlock
        add_info!("Order: $(size(block.A_c, 1)) state(s)")
        add_info!("D = $(block.D_c)")
    end

    # Apply / Cancel (Section 5): Apply commits every field, then closes.
    screen_ref = Ref{Any}(nothing)
    function _close_win!()
        s = screen_ref[]
        s === nothing && return
        try; s.window_open[] && close(s); catch _; end
        delete!(prop_screens, block)
    end
    btns = GridLayout(g[row[], 1:2]; halign = :right, tellwidth = false)
    colgap!(btns, 8)
    btn_apply  = Button(btns[1, 1]; label = "Apply", height = 30, fontsize = 12,
        buttoncolor = _MAKIE_BLUE, strokecolor = RGBf(0.0, 0.361, 0.565),
        strokewidth = 1, labelcolor = :white)
    btn_cancel = Button(btns[1, 2]; label = "Cancel", height = 30, fontsize = 12,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1,
        labelcolor = _INK)
    on(btn_apply.clicks) do _
        for f in appliers
            try; f(); catch _; end
        end
        _close_win!()
    end
    on(btn_cancel.clicks) do _
        _close_win!()
    end

    # Size the window to its content: title strip + padding + one 39 px slot
    # per grid row (28 px field + 11 px gap), clamped to sane bounds.
    resize!(fig, 360, clamp(96 + 39 * row[], 200, 620))

    screen = GLMakie.Screen(title = "Block Parameters — $(block.name)")
    screen_ref[] = screen
    display(screen, fig)
    prop_screens[block] = screen
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    draw_diagram(diagram) -> Figure

Opens the SimuLite GUI window. Layout (Section 5 wireframe style):
- Top:   single toolbar — New/Save/Load, ▶Run/■Stop/✕Clear, t₀/tstop/Δt
- Left:  block palette — category Menu, search box, icon-chip block list
- Right: block diagram canvas (dot grid)
- Bottom: status bar

Interactions:
- **Palette** — click to add a block at canvas centre
- **Drag** a block to reposition it
- **Output port** (red) → **Input port** (blue) to wire
- **Single-click block** — select (blue border); Delete to remove
- **Double-click block** — open floating Properties window to edit parameters
- **Double-click Scope** — open result plot window (run first); **Ctrl+double-click** to edit Scope properties
- **Escape** — cancel wire / deselect
- **▶ Run** — simulate and show signal plots
- **New / Clear** — remove all blocks and connections
"""
function draw_diagram(diagram::BlockDiagram = BlockDiagram())
    _res = try; GLMakie.primary_resolution(); catch; (1600, 900); end
    fig = Figure(size = (round(Int, _res[1] * 0.92), round(Int, _res[2] * 0.88)),
        backgroundcolor = _WIN_BG, figure_padding = 0)

    # Panel background fills (Section 5 wireframe colors). Created before the
    # widgets that share their grid cells so they render behind them.
    Box(fig[1, 1:2]; color = _TB_BG,    strokecolor = _PANEL_BRD, strokewidth = 1)
    pal_box = Box(fig[2, 1]; color = _PANEL_BG, strokecolor = _PANEL_BRD, strokewidth = 1)
    Box(fig[3, 1:2]; color = _TB_BG,    strokecolor = _PANEL_BRD, strokewidth = 1)

    # ── Row 1: single toolbar (46 px strip, 30 px buttons — Section 5) ───────
    toolbar = GridLayout(fig[1, 1:2]; alignmode = Outside(8))
    rowsize!(fig.layout, 1, Fixed(46))

    # File operations
    btn_new  = Button(toolbar[1, 1]; label = "New", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)
    btn_save = Button(toolbar[1, 2]; label = "Save", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)
    btn_load = Button(toolbar[1, 3]; label = "Load", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)
    filename_ref = Ref{String}("diagram.json")
    tb_filename  = Textbox(toolbar[1, 4];
        displayed_string = "diagram.json", width = 130, height = 28, fontsize = 11,
        boxcolor = :white, bordercolor = _BTN_BRD)
    on(tb_filename.stored_string) do s; s === nothing || (filename_ref[] = s); end

    # Toolbar items must report their width; otherwise their columns share
    # leftover space with the trailing spacer and items spread out.
    Box(toolbar[1, 5]; width = 1, height = 26, color = _PANEL_BRD, strokewidth = 0)

    # Edit history (before Run, per Simulink layout)
    btn_undo = Button(toolbar[1, 6]; label = "↶ Undo", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)
    btn_redo = Button(toolbar[1, 7]; label = "↷ Redo", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)

    Box(toolbar[1, 8]; width = 1, height = 26, color = _PANEL_BRD, strokewidth = 0)

    # Run controls
    btn_run  = Button(toolbar[1, 9]; label = "▶  Run", height = 30,
        buttoncolor = _RUN_GREEN, strokecolor = _RUN_BRD, strokewidth = 1,
        labelcolor = :white)
    Button(toolbar[1, 10]; label = "■ Stop", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1,
        labelcolor = _INK)   # UI placeholder, no handler
    btn_clear = Button(toolbar[1, 11]; label = "✕  Clear", height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)

    Box(toolbar[1, 12]; width = 1, height = 26, color = _PANEL_BRD, strokewidth = 0)

    # Simulation time parameters
    Label(toolbar[1, 13], "t₀:"; tellwidth = true, fontsize = 12, color = _MUTED)
    tb_tstart = Textbox(toolbar[1, 14];
        displayed_string = string(diagram.config.tspan[1]), width = 54, height = 28,
        boxcolor = :white, bordercolor = _BTN_BRD)
    Label(toolbar[1, 15], "tstop:"; tellwidth = true, fontsize = 12, color = _MUTED)
    tb_tend   = Textbox(toolbar[1, 16];
        displayed_string = string(diagram.config.tspan[2]), width = 54, height = 28,
        boxcolor = :white, bordercolor = _BTN_BRD)
    Label(toolbar[1, 17], "Δt:"; tellwidth = true, fontsize = 12, color = _MUTED)
    tb_dt     = Textbox(toolbar[1, 18];
        displayed_string = string(diagram.config.dt), width = 54, height = 28,
        boxcolor = :white, bordercolor = _BTN_BRD)

    # Flexible trailing spacer absorbs all slack → the left groups pack left
    # and the zoom cluster (placed after the spacer) sits at the right edge.
    Label(toolbar[1, 19], ""; tellwidth = false)
    colsize!(toolbar, 19, Auto(false))

    # Zoom cluster: − 100% + (Section 5); handlers attached after the Axis exists
    zoom_pct = Observable("100%")
    btn_zoom_out = Button(toolbar[1, 20]; label = "−", width = 30, height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)
    Label(toolbar[1, 21], zoom_pct; fontsize = 12, color = _MUTED, tellwidth = true)
    btn_zoom_in  = Button(toolbar[1, 22]; label = "+", width = 30, height = 30,
        buttoncolor = _BTN_BG, strokecolor = _BTN_BRD, strokewidth = 1, labelcolor = _INK)

    colgap!(toolbar, 6)

    # ── Row 2: palette | canvas ───────────────────────────────────────────────
    # tellheight = false so the palette never determines the canvas row height;
    # valign = :top packs the content up and leaves slack at the bottom.
    palette_grid = GridLayout(fig[2, 1];
        alignmode = Outside(10), valign = :top, tellheight = false)

    # Row 1: header
    Label(palette_grid[1, 1:2], "Block Library";
        fontsize = 13, font = :bold, halign = :left,
        color = _INK, tellwidth = false)

    # Row 2: category dropdown (Menu)
    cat_menu = Menu(palette_grid[2, 1:2];
        options  = ["All categories", "Sources", "Math", "Sinks"],
        default  = "All categories",
        height = 28, fontsize = 12, tellwidth = true)

    # Row 3: search textbox
    tb_search = Textbox(palette_grid[3, 1:2];
        placeholder = "Search…", tellwidth = true, fontsize = 12,
        height = 28, boxcolor = :white, bordercolor = _BTN_BRD)

    colsize!(palette_grid, 1, Fixed(28))
    colsize!(palette_grid, 2, Auto())
    colgap!(palette_grid, 8)
    rowgap!(palette_grid, 6)

    # Canvas axis (white background + neutral dot grid — Section 5)
    ax = Axis(fig[2, 2];
        leftspinecolor   = RGBf(0.812, 0.812, 0.812),
        rightspinecolor  = RGBf(0.812, 0.812, 0.812),
        bottomspinecolor = RGBf(0.812, 0.812, 0.812),
        topspinecolor    = RGBf(0.812, 0.812, 0.812),
        spinewidth       = 1,
        backgroundcolor  = RGBf(1.0, 1.0, 1.0))
    hidedecorations!(ax)
    limits!(ax, _CANVAS_XLIM..., _CANVAS_YLIM...)

    let xs = Float64[], ys = Float64[]
        for x in _CANVAS_XLIM[1]:0.5:_CANVAS_XLIM[2], y in _CANVAS_YLIM[1]:0.5:_CANVAS_YLIM[2]
            push!(xs, x); push!(ys, y)
        end
        scatter!(ax, xs, ys; color = _CANVAS_GRID, markersize = 3)
    end

    colsize!(fig.layout, 1, Fixed(236))
    colsize!(fig.layout, 2, Auto())
    rowgap!(fig.layout, 0)
    colgap!(fig.layout, 0)

    # ── Row 3: status bar ─────────────────────────────────────────────────────
    status = Observable("Build a diagram, then click ▶ Run")
    Label(fig[3, 1:2], status; tellwidth = false, fontsize = 12,
        halign = :left, padding = (12, 0, 0, 0), color = _MUTED)
    rowsize!(fig.layout, 3, Fixed(28))

    deregister_interaction!(ax, :rectanglezoom)

    # ── State dicts ───────────────────────────────────────────────────────────
    block_centers  = Dict{AbstractBlock, Observable{Point2f}}()
    block_strokes  = Dict{AbstractBlock, Observable{Any}}()
    block_heights  = Dict{AbstractBlock, Observable{Float64}}()
    port_pos       = Dict{Tuple{Any, Symbol}, Observable{Point2f}}()
    port_type      = Dict{Tuple{Any, Symbol}, Symbol}()
    block_visuals  = Dict{AbstractBlock, BlockVisual}()
    conn_visuals   = Dict{Connection,    ConnVisual}()
    scope_screens  = Dict{AbstractBlock, Any}()
    prop_screens   = Dict{AbstractBlock, Any}()
    last_result    = Ref{Union{Nothing, SimResult}}(nothing)
    undo_stack     = UndoAction[]
    redo_stack     = UndoAction[]
    drag_start_pos = Ref{Tuple{Float64, Float64}}((0.0, 0.0))

    # ── Draw existing diagram ─────────────────────────────────────────────────
    for block in diagram.blocks
        block_visuals[block] = _setup_block!(ax, block,
            block_centers, block_strokes, block_heights, port_pos, port_type)
    end
    for conn in diagram.connections
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
    end
    _refresh_feedback_sides!(diagram, block_centers, block_visuals)

    # ── Rubber-band wire ──────────────────────────────────────────────────────
    wire_active = Observable(false)
    rubber_pts  = Observable(Point2f[(0f0, 0f0), (1f0, 0f0)])
    lines!(ax, rubber_pts;
        color = :gray, linewidth = 1.5, linestyle = :dash, visible = wire_active)

    # ── Interaction state ─────────────────────────────────────────────────────
    wire_src      = Ref{Union{Nothing, Tuple{Any, Symbol}}}(nothing)
    selected      = Ref{Union{Nothing, AbstractBlock}}(nothing)
    selected_conn = Ref{Union{Nothing, Connection}}(nothing)
    drag_offset   = Ref((0.0, 0.0))

    function _clear_all!()
        _deselect_conn!()
        selected[] = nothing
        if wire_active[]
            wire_active[] = false
            wire_src[]    = nothing
        end
        for block in copy(diagram.blocks)
            _delete_block!(ax, diagram, block,
                block_centers, block_strokes, block_heights,
                port_pos, port_type, block_visuals, conn_visuals)
        end
        for (_, screen) in scope_screens
            try; screen.window_open[] && close(screen); catch _; end
        end
        empty!(scope_screens)
        for (_, screen) in prop_screens
            try; screen.window_open[] && close(screen); catch _; end
        end
        empty!(prop_screens)
        empty!(undo_stack)
        empty!(redo_stack)
    end

    function _cancel_wire!()
        wire_active[] = false
        wire_src[]    = nothing
        status[] = "Wire cancelled"
    end

    function _deselect_conn!()
        if selected_conn[] !== nothing
            cv = get(conn_visuals, selected_conn[], nothing)
            if cv !== nothing
                cv.curve.color[] = _WIRE_COLOR
                cv.arrow.color[] = _WIRE_COLOR
            end
            selected_conn[] = nothing
        end
    end

    function _deselect!()
        _deselect_conn!()
        if selected[] !== nothing
            # Defensive get: the selected block may already have been removed
            # (e.g. by undo/redo), leaving a stale reference in `selected`.
            bv = get(block_visuals, selected[], nothing)
            st = get(block_strokes, selected[], nothing)
            (bv !== nothing && st !== nothing) && (st[] = bv.border_color)
            selected[] = nothing
        end
    end

    # Clear selection state that points at objects a structural edit (undo/
    # redo) is about to remove — stale refs crash later dict lookups.
    function _drop_stale_selection!(block)
        selected[] === block && (selected[] = nothing)
        sc = selected_conn[]
        if sc !== nothing && (sc.src_block === block || sc.dst_block === block)
            selected_conn[] = nothing
        end
    end

    # ── Undo / Redo ───────────────────────────────────────────────────────────

    function _push_undo!(action::UndoAction)
        push!(undo_stack, action)
        empty!(redo_stack)
    end

    function _find_conn(sb, sp, db, dp)
        for c in diagram.connections
            c.src_block === sb && c.src_port === sp &&
            c.dst_block === db && c.dst_port === dp && return c
        end
        nothing
    end

    function _remove_conn_visual!(sb, sp, db, dp)
        conn = _find_conn(sb, sp, db, dp)
        conn === nothing && return
        selected_conn[] === conn && (selected_conn[] = nothing)
        cv = get(conn_visuals, conn, nothing)
        if cv !== nothing
            delete!(ax, cv.curve); delete!(ax, cv.arrow)
            delete!(conn_visuals, conn)
        end
        disconnect!(diagram, sb, sp, db, dp)
        _refresh_feedback_sides!(diagram, block_centers, block_visuals)
    end

    function _add_conn_visual!(sb, sp, db, dp)
        connect!(diagram, sb, sp, db, dp)
        conn = diagram.connections[end]
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
        _refresh_feedback_sides!(diagram, block_centers, block_visuals)
    end

    function _apply_action!(action::AddBlockAction, forward::Bool)
        if forward
            add_block!(diagram, action.block)
            block_visuals[action.block] = _setup_block!(ax, action.block,
                block_centers, block_strokes, block_heights, port_pos, port_type)
        else
            _drop_stale_selection!(action.block)
            _delete_block!(ax, diagram, action.block,
                block_centers, block_strokes, block_heights,
                port_pos, port_type, block_visuals, conn_visuals)
        end
    end

    function _apply_action!(action::DeleteBlockAction, forward::Bool)
        if forward
            _drop_stale_selection!(action.block)
            _delete_block!(ax, diagram, action.block,
                block_centers, block_strokes, block_heights,
                port_pos, port_type, block_visuals, conn_visuals)
        else
            add_block!(diagram, action.block)
            block_visuals[action.block] = _setup_block!(ax, action.block,
                block_centers, block_strokes, block_heights, port_pos, port_type)
            for (sb, sp, db, dp) in action.removed_conns
                try; _add_conn_visual!(sb, sp, db, dp); catch _; end
            end
        end
    end

    function _apply_action!(action::MoveBlockAction, forward::Bool)
        pos = forward ? action.new_pos : action.old_pos
        action.block.position = pos
        block_centers[action.block][] = Point2f(pos...)
        _refresh_feedback_sides!(diagram, block_centers, block_visuals)
    end

    function _apply_action!(action::AddConnectionAction, forward::Bool)
        if forward
            _add_conn_visual!(action.src_block, action.src_port,
                              action.dst_block, action.dst_port)
        else
            _remove_conn_visual!(action.src_block, action.src_port,
                                 action.dst_block, action.dst_port)
        end
    end

    function _apply_action!(action::DeleteConnectionAction, forward::Bool)
        if forward
            _remove_conn_visual!(action.src_block, action.src_port,
                                 action.dst_block, action.dst_port)
        else
            _add_conn_visual!(action.src_block, action.src_port,
                              action.dst_block, action.dst_port)
        end
    end

    function do_undo!()
        if isempty(undo_stack)
            status[] = "Nothing to undo"
            return
        end
        # A wire in progress may originate from a block the action removes
        wire_active[] && _cancel_wire!()
        action = pop!(undo_stack)
        try
            _apply_action!(action, false)
            push!(redo_stack, action)
            status[] = "Undo"
        catch e
            status[] = "Undo failed: $(sprint(showerror, e))"
        end
    end

    function do_redo!()
        if isempty(redo_stack)
            status[] = "Nothing to redo"
            return
        end
        wire_active[] && _cancel_wire!()
        action = pop!(redo_stack)
        try
            _apply_action!(action, true)
            push!(undo_stack, action)
            status[] = "Redo"
        catch e
            status[] = "Redo failed: $(sprint(showerror, e))"
        end
    end

    on(btn_undo.clicks) do _; do_undo!(); end
    on(btn_redo.clicks) do _; do_redo!(); end

    register_interaction!(ax, :diagram_interaction) do event::MouseEvent, _
        pos = event.data

        if event.type == MouseEventTypes.over
            if wire_active[]
                rubber_pts[] = Point2f[port_pos[wire_src[]][], Point2f(pos)]
            end

        elseif event.type == MouseEventTypes.leftdown
            hit = _hit_port(port_pos, pos)

            if wire_active[]
                if hit !== nothing && port_type[hit] === :input
                    src_block, src_port = wire_src[]
                    dst_block, dst_port = hit
                    try
                        connect!(diagram, src_block, src_port, dst_block, dst_port)
                        conn = diagram.connections[end]
                        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
                        _refresh_feedback_sides!(diagram, block_centers, block_visuals)
                        _push_undo!(AddConnectionAction(src_block, src_port, dst_block, dst_port))
                        status[] = "Connected $(src_block.name):$(src_port) → $(dst_block.name):$(dst_port)"
                    catch e
                        status[] = e isa DiagramError ?
                            sprint(showerror, e) : "Unexpected error — see REPL"
                        e isa DiagramError || rethrow(e)
                    end
                else
                    status[] = "Wire cancelled"
                end
                wire_active[] = false
                wire_src[]    = nothing

            else
                if hit !== nothing && port_type[hit] === :output
                    _deselect!()
                    wire_src[]    = hit
                    wire_active[] = true
                    rubber_pts[]  = Point2f[port_pos[hit][], Point2f(pos)]
                    block, p      = hit
                    status[] = "Wiring from $(block.name):$(p) — click an input port (●)"
                else
                    _deselect!()
                    for block in reverse(diagram.blocks)
                        if _hit_block(block_centers[block][], pos, _block_height(block))
                            selected[]             = block
                            c                      = block_centers[block][]
                            drag_offset[]          = (c[1] - pos[1], c[2] - pos[2])
                            drag_start_pos[]       = block.position
                            block_strokes[block][] = _SEL_COLOR
                            status[] = "$(block.name) selected — double-click to edit, Delete to remove"
                            break
                        end
                    end
                    if selected[] === nothing
                        for (conn, cv) in conn_visuals
                            if _hit_connection(conn, port_pos, pos)
                                selected_conn[]    = conn
                                cv.curve.color[]   = _ORA_COLOR
                                cv.arrow.color[]   = _ORA_COLOR
                                status[] = "Connection selected — press Delete to remove"
                                break
                            end
                        end
                    end
                end
            end

        elseif event.type == MouseEventTypes.leftdoubleclick
            ctrl_held = Keyboard.left_control in events(ax.scene).keyboardstate ||
                        Keyboard.right_control in events(ax.scene).keyboardstate
            for block in reverse(diagram.blocks)
                if _hit_block(block_centers[block][], pos, _block_height(block))
                    if block isa ScopeBlock && !ctrl_held
                        if last_result[] !== nothing
                            _open_scope_window!(block, last_result[], diagram, scope_screens)
                            status[] = "Scope '$(block.title)' opened"
                        else
                            status[] = "Run the simulation first — Ctrl+double-click to edit properties"
                        end
                    else
                        _open_props_window!(block, block_visuals, prop_screens,
                            ax, diagram, block_centers, block_heights,
                            port_pos, port_type, conn_visuals)
                        status[] = "Properties opened for $(block.name)"
                    end
                    break
                end
            end

        elseif event.type == MouseEventTypes.leftdrag
            if selected[] !== nothing
                ox, oy = drag_offset[]
                block_centers[selected[]][] = Point2f(pos[1] + ox, pos[2] + oy)
            end

        elseif event.type == MouseEventTypes.leftup
            if selected[] !== nothing
                c       = block_centers[selected[]][]
                new_pos = (Float64(c[1]), Float64(c[2]))
                old_pos = drag_start_pos[]
                selected[].position = new_pos
                if new_pos != old_pos
                    _push_undo!(MoveBlockAction(selected[], old_pos, new_pos))
                    _refresh_feedback_sides!(diagram, block_centers, block_visuals)
                end
            end
        end
    end

    on(events(ax.scene).keyboardbutton) do ev
        ev.action == Keyboard.press || return
        ctrl  = Keyboard.left_control in events(ax.scene).keyboardstate ||
                Keyboard.right_control in events(ax.scene).keyboardstate
        shift = Keyboard.left_shift in events(ax.scene).keyboardstate ||
                Keyboard.right_shift in events(ax.scene).keyboardstate
        if ev.key == Keyboard.escape
            wire_active[] ? _cancel_wire!() : _deselect!()
        elseif ev.key == Keyboard.z && ctrl
            shift ? do_redo!() : do_undo!()
        elseif ev.key == Keyboard.y && ctrl
            do_redo!()
        elseif ev.key == Keyboard.delete && !wire_active[]
            if selected_conn[] !== nothing
                conn = selected_conn[]
                _deselect_conn!()
                # Defensive get: the connection may already be gone if it was
                # removed behind the selection (e.g. port reconfiguration).
                cv = get(conn_visuals, conn, nothing)
                if cv !== nothing
                    _push_undo!(DeleteConnectionAction(conn.src_block, conn.src_port,
                                                       conn.dst_block, conn.dst_port))
                    delete!(ax, cv.curve)
                    delete!(ax, cv.arrow)
                    delete!(conn_visuals, conn)
                    disconnect!(diagram, conn.src_block, conn.src_port,
                                conn.dst_block, conn.dst_port)
                    _refresh_feedback_sides!(diagram, block_centers, block_visuals)
                    status[] = "Connection deleted"
                end
            elseif selected[] !== nothing
                block = selected[]
                removed = Tuple{AbstractBlock, Symbol, AbstractBlock, Symbol}[
                    (c.src_block, c.src_port, c.dst_block, c.dst_port)
                    for c in filter(c -> c.src_block === block || c.dst_block === block,
                                    diagram.connections)]
                selected[] = nothing
                _delete_block!(ax, diagram, block,
                    block_centers, block_strokes, block_heights,
                    port_pos, port_type, block_visuals, conn_visuals)
                _push_undo!(DeleteBlockAction(block, removed))
                _refresh_feedback_sides!(diagram, block_centers, block_visuals)
                status[] = "Block deleted"
            end
        end
    end

    # ── Palette: collapsible Toggle categories (Section 5 wireframe) ──────────
    pal_items        = Ref{Vector{Any}}(Any[])
    next_content_row = Ref(4)   # rows 1-3: header / menu / search
    active_cat       = Ref{String}("All categories")
    search_obs       = Observable("")
    cat_expanded     = Dict("Sources" => true, "Math" => false, "Sinks" => false)
    pal_scroll       = Ref(0)   # index of the first visible palette entry

    # Palette data: (icon_sym, label, factory) — chips use the uniform
    # Makie-blue accent from the wireframe, independent of block category.
    sources_pal = [
        ("1",    "Constant",       () -> ConstantBlock(0.0)),
        ("⎍",    "Step",           () -> StepBlock()),
        ("∿",    "Sine",           () -> SineBlock()),
        ("╱",    "Ramp",           () -> RampBlock()),
        ("t",    "Clock",          () -> ClockBlock()),
    ]
    math_pal = [
        ("▷",    "Gain",           () -> GainBlock(1.0)),
        ("Σ",    "Sum",            () -> SumBlock("++")),
        ("∫",    "Integrator",     () -> IntegratorBlock(0.0)),
        ("z⁻¹",  "Unit Delay",     () -> UnitDelayBlock(0.0)),
        ("×",    "Product ×2",     () -> ProductBlock([:mul, :mul])),
        ("sat",  "Saturation",     () -> SaturationBlock()),
        ("|u|",  "Abs",            () -> AbsBlock()),
        ("d/dt", "Derivative",     () -> DerivativeBlock()),
        ("PID",  "PID",            () -> PIDBlock()),
        ("f(x)", "Lookup 1D",      () -> LookupTable1DBlock()),
        ("H(s)", "Transfer Fcn",   () -> TransferFnBlock([1.0], [1.0, 1.0])),
        ("SS",   "State Space",    () -> StateSpaceBlock([-1.0;;], [1.0], [1.0], 0.0)),
    ]
    sinks_pal = [
        ("∿",    "Scope",          () -> ScopeBlock()),
        ("ws",   "Workspace",      () -> WorkspaceBlock()),
        ("▪",    "Terminator",     () -> TerminatorBlock()),
    ]
    pal_cats = [("Sources", sources_pal), ("Math", math_pal), ("Sinks", sinks_pal)]

    function clear_pal!()
        for item in pal_items[]; delete!(item); end
        pal_items[] = Any[]
        next_content_row[] = 4
        trim!(palette_grid)
    end

    function _pal_block!(sym_text, lbl_text, factory)
        r = next_content_row[]
        next_content_row[] += 1
        chip_box = Box(palette_grid[r, 1]; width = 24, height = 20,
            color = :white, strokecolor = _MAKIE_BLUE, strokewidth = 1,
            cornerradius = 2)
        chip = Label(palette_grid[r, 1], sym_text;
            fontsize = 10, halign = :center, valign = :center,
            color = _MAKIE_BLUE, tellwidth = false)
        btn  = Button(palette_grid[r, 2]; label = lbl_text, height = 30,
            width = _PAL_CHIP_W, halign = :left, tellwidth = false, fontsize = 12,
            buttoncolor = :white, strokecolor = _CHIP_BRD, strokewidth = 1,
            labelcolor = _INK,
            buttoncolor_hover = RGBf(0.933, 0.957, 0.984))
        on(btn.clicks) do _
            block = factory()
            lim = ax.finallimits[]
            block.position = (Float64(lim.origin[1] + lim.widths[1] / 2),
                              Float64(lim.origin[2] + lim.widths[2] / 2))
            try
                add_block!(diagram, block)
            catch e
                status[] = e isa DiagramError ? sprint(showerror, e) : "Error — see REPL"
                e isa DiagramError || rethrow(e)
                return
            end
            block_visuals[block] = _setup_block!(ax, block,
                block_centers, block_strokes, block_heights, port_pos, port_type)
            _push_undo!(AddBlockAction(block))
            status[] = "Added $(block.name) — drag to position"
        end
        push!(pal_items[], chip_box)
        push!(pal_items[], chip)
        push!(pal_items[], btn)
    end

    # Category header row: "▸/▾ Name" label + expand/collapse Toggle (Section 5)
    function _pal_cat_header!(cat_name)
        r = next_content_row[]
        next_content_row[] += 1
        expanded = cat_expanded[cat_name]
        lbl = Label(palette_grid[r, 1:2], (expanded ? "▾  " : "▸  ") * cat_name;
            fontsize = 12, font = :bold, halign = :left, tellwidth = false,
            color = expanded ? _INK : RGBf(0.33, 0.33, 0.33))
        tg = Toggle(palette_grid[r, 1:2]; active = expanded,
            halign = :right, tellwidth = false, width = 34, height = 18,
            framecolor_active   = _MAKIE_BLUE,
            framecolor_inactive = RGBf(0.737, 0.737, 0.737),
            buttoncolor = :white)
        on(tg.active) do v
            cat_expanded[cat_name] = v
            _build_pal!(active_cat[], search_obs[])
        end
        push!(pal_items[], lbl)
        push!(pal_items[], tg)
    end

    # Flat entry list (category headers + block chips) for the current menu /
    # search state — the scroll window shows a slice of this list.
    function _pal_entries(cat_str, txt)
        entries = Tuple[]
        if !isempty(txt)   # non-empty search: flat filtered list, no headers
            for (_, items) in pal_cats, (sym, lbl, factory) in items
                occursin(txt, lowercase(lbl)) && push!(entries, (:block, sym, lbl, factory))
            end
            return entries
        end
        for (cat_name, items) in pal_cats
            (cat_str == "All categories" || cat_str == cat_name) || continue
            push!(entries, (:header, cat_name))
            cat_expanded[cat_name] || continue
            for (sym, lbl, factory) in items
                push!(entries, (:block, sym, lbl, factory))
            end
        end
        entries
    end

    # How many palette rows fit below header/menu/search at the current panel
    # height: 36 px per slot (30 px chip + gap), ~155 px reserved above/below.
    function _pal_visible_slots()
        bb = pal_box.layoutobservables.computedbbox[]
        max(2, floor(Int, (bb.widths[2] - 155) / 36))
    end

    function _build_pal!(cat_str, search_txt)
        clear_pal!()
        entries = _pal_entries(cat_str, lowercase(search_txt))
        nvis    = _pal_visible_slots()
        pal_scroll[] = clamp(pal_scroll[], 0, max(0, length(entries) - nvis))
        off = pal_scroll[]
        hi  = min(length(entries), off + nvis)
        for e in entries[(off + 1):hi]
            e[1] === :header ? _pal_cat_header!(e[2]) : _pal_block!(e[2], e[3], e[4])
        end
        if length(entries) > nvis   # overflow → scroll hint row
            r = next_content_row[]
            next_content_row[] += 1
            hint = Label(palette_grid[r, 1:2],
                "⇕ scroll — $(off + 1)–$hi of $(length(entries))";
                fontsize = 10, color = RGBf(0.55, 0.55, 0.55),
                halign = :center, tellwidth = false)
            push!(pal_items[], hint)
        end
        # Rows created after a rowgap! call get the default gap again, so the
        # tight chip spacing must be re-applied after every rebuild.
        rowgap!(palette_grid, 6)
    end

    # Wire category menu and search to palette rebuild
    on(cat_menu.selection) do cat
        c = String(cat)
        active_cat[] = c
        c == "All categories" || (cat_expanded[c] = true)
        pal_scroll[] = 0
        _build_pal!(c, search_obs[])
    end
    on(tb_search.stored_string) do s
        s === nothing && return
        search_obs[] = lowercase(s)
    end
    on(search_obs) do txt
        pal_scroll[] = 0
        _build_pal!(active_cat[], txt)
    end
    _build_pal!("All categories", "")

    # Mouse wheel over the palette scrolls the entry window (GLMakie grids
    # have no native scrolling). Consumed so the canvas cannot also zoom.
    on(events(fig).scroll; priority = 100) do (_, dy)
        bb = pal_box.layoutobservables.computedbbox[]
        mp = events(fig).mouseposition[]
        inside = bb.origin[1] <= mp[1] <= bb.origin[1] + bb.widths[1] &&
                 bb.origin[2] <= mp[2] <= bb.origin[2] + bb.widths[2]
        inside || return Consume(false)
        pal_scroll[] = max(0, pal_scroll[] - 2 * round(Int, dy))
        _build_pal!(active_cat[], search_obs[])   # clamps the upper bound
        return Consume(true)
    end

    # Window resize changes how many rows fit — rebuild only when that count
    # actually changes (the bbox observable fires on every layout pass).
    pal_last_slots = Ref(_pal_visible_slots())
    on(pal_box.layoutobservables.computedbbox) do _
        n = _pal_visible_slots()
        n == pal_last_slots[] && return
        pal_last_slots[] = n
        _build_pal!(active_cat[], search_obs[])
    end

    # ── Toolbar: SimConfig textboxes ──────────────────────────────────────────
    on(tb_tstart.stored_string) do s
        s === nothing && return
        try; diagram.config.tspan = (parse(Float64, s), diagram.config.tspan[2]); catch _; end
    end
    on(tb_tend.stored_string) do s
        s === nothing && return
        try; diagram.config.tspan = (diagram.config.tspan[1], parse(Float64, s)); catch _; end
    end
    on(tb_dt.stored_string) do s
        s === nothing && return
        try; diagram.config.dt = parse(Float64, s); catch _; end
    end

    # ── Toolbar: file buttons ─────────────────────────────────────────────────
    on(btn_new.clicks) do _
        _clear_all!()
        status[] = "New diagram — ready"
    end

    on(btn_save.clicks) do _
        path = filename_ref[]
        isempty(path) && (path = "diagram.json")
        try
            save_diagram(diagram, path)
            status[] = "Saved to $path"
        catch e
            status[] = "Save failed: $(sprint(showerror, e))"
        end
    end

    on(btn_load.clicks) do _
        path = filename_ref[]
        isempty(path) && (path = "diagram.json")
        isfile(path) || (status[] = "File not found: $path"; return)
        try
            data = JSON3.read(read(path, String))
            _clear_all!()
            cfg = data["config"]
            diagram.config.tspan = (Float64(cfg["tspan"][1]), Float64(cfg["tspan"][2]))
            diagram.config.dt    = Float64(cfg["dt"])
            name_to_block = Dict{String, AbstractBlock}()
            for b_data in data["blocks"]
                b = _reconstruct_block(String(b_data["type"]),
                                       String(b_data["name"]),
                                       b_data["position"],
                                       b_data["params"])
                add_block!(diagram, b)
                block_visuals[b] = _setup_block!(ax, b,
                    block_centers, block_strokes, block_heights, port_pos, port_type)
                name_to_block[b.name] = b
            end
            for c_data in data["connections"]
                src = name_to_block[String(c_data["src"])]
                dst = name_to_block[String(c_data["dst"])]
                connect!(diagram, src, Symbol(c_data["src_port"]),
                                  dst, Symbol(c_data["dst_port"]))
                conn = diagram.connections[end]
                conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
            end
            _refresh_feedback_sides!(diagram, block_centers, block_visuals)
            status[] = "Loaded $path — $(length(diagram.blocks)) blocks, $(length(diagram.connections)) connections"
        catch e
            status[] = "Load failed: $(sprint(showerror, e))"
            @warn "Load error" exception = (e, catch_backtrace())
        end
    end

    # ── Toolbar: Run / Clear buttons ──────────────────────────────────────────
    on(btn_run.clicks) do _
        try
            result        = simulate(diagram)
            last_result[] = result
            n  = length(result.t)
            ns = count(b -> b isa ScopeBlock, diagram.blocks)
            status[] = ns > 0 ?
                "Run complete — $n steps — double-click a Scope block to view signals" :
                "Run complete — $n steps (add a Scope block to view signals)"
        catch e
            status[] = "Run failed: $(sprint(showerror, e))"
            @warn "Simulation error" exception = (e, catch_backtrace())
        end
    end

    on(btn_clear.clicks) do _
        _clear_all!()
        status[] = "Diagram cleared"
    end

    # ── Toolbar: zoom cluster ─────────────────────────────────────────────────
    function _zoom_canvas!(f)
        lim = ax.finallimits[]
        cx = lim.origin[1] + lim.widths[1] / 2
        cy = lim.origin[2] + lim.widths[2] / 2
        w  = lim.widths[1] * f
        h  = lim.widths[2] * f
        limits!(ax, cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2)
    end
    on(btn_zoom_in.clicks)  do _; _zoom_canvas!(0.8);  end
    on(btn_zoom_out.clicks) do _; _zoom_canvas!(1.25); end
    # finallimits also changes on scroll-wheel zoom and view reset, so the
    # percentage label stays correct for every zoom path.
    on(ax.finallimits) do lim
        pct = round(Int, (_CANVAS_XLIM[2] - _CANVAS_XLIM[1]) / lim.widths[1] * 100)
        zoom_pct[] = "$(pct)%"
    end

    display(fig)
    return fig
end

# ── Precompilation workload ───────────────────────────────────────────────────
# Runs once at `Pkg.precompile()` time, caching method specializations so that
# first-use latency (first block add, first connection, first properties window)
# is eliminated on subsequent sessions.
@compile_workload begin
    # Part 1: simulation engine — pure Julia, always safe
    _d  = BlockDiagram()
    _b1 = ConstantBlock(1.0; name="__pc_src", position=(0.0, 0.0))
    _b2 = GainBlock(2.0;     name="__pc_gain", position=(2.0, 0.0))
    _b3 = ScopeBlock(;        name="__pc_scope", position=(4.0, 0.0))
    add_block!(_d, _b1); add_block!(_d, _b2); add_block!(_d, _b3)
    connect!(_d, _b1, :out, _b2, :in)
    connect!(_d, _b2, :out, _b3, :in1)
    simulate(_d; tspan=(0.0, 0.05), dt=0.05)

    # Part 2: Makie scene-graph method specializations — Figure/Axis/plot! calls
    # are pure Julia (no OpenGL context needed); only display() triggers GPU work.
    _fig = Figure()
    _ax  = Axis(_fig[1, 1])

    _c   = Observable(Point2f(0.0, 0.0))   # block center
    _bh  = Observable(BLOCK_H)             # block height
    _sc  = Observable{Any}(_BLUE_BORDER)   # dynamic strokecolor

    # strip  — poly! with Observable{Vector{Point2f}}, color=:white
    _strip_pts = @lift Point2f[
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] - $(_bh)/2),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] - $(_bh)/2),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
    ]
    poly!(_ax, _strip_pts; color=:white, strokewidth=0)

    # icon   — poly! with RGBf fill color
    _icon_pts = @lift Point2f[
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] + $(_bh)/2),
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] + $(_bh)/2),
    ]
    poly!(_ax, _icon_pts; color=_BLUE_ICON, strokewidth=0)

    # divider — lines!
    _div_pts = @lift [
        Point2f($(_c)[1] - BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
        Point2f($(_c)[1] + BLOCK_W/2, $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC),
    ]
    lines!(_ax, _div_pts; color=_BLUE_BORDER, linewidth=0.8)

    # border — poly! with strokecolor=Observable{Any}
    _border_pts = @lift Point2f[
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] - $(_bh)/2),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] - $(_bh)/2),
        ($(_c)[1] + BLOCK_W/2, $(_c)[2] + $(_bh)/2),
        ($(_c)[1] - BLOCK_W/2, $(_c)[2] + $(_bh)/2),
    ]
    poly!(_ax, _border_pts; color=(:white, 0f0), strokecolor=_sc, strokewidth=2)

    # icon symbol — text! with Observable{Vector{Point2f}}
    _icy = @lift Point2f($(_c)[1], $(_c)[2] - $(_bh)/2 + $(_bh)*(STRIP_FRAC + (1f0-STRIP_FRAC)/2f0))
    text!(_ax, @lift([$(_icy)]); text=["Σ"], align=(:center,:center),
          fontsize=15, color=_BLUE_BORDER)

    # block name label — text! (different fontsize/color combo)
    _lbl = @lift Point2f($(_c)[1], $(_c)[2] - $(_bh)/2 + $(_bh)*STRIP_FRAC/2f0)
    text!(_ax, @lift([$(_lbl)]); text=["block"], align=(:center,:center),
          fontsize=10, color=RGBf(0.20, 0.20, 0.20))

    # input port — scatter! with Observable{Vector{Point2f}}
    _ip = @lift Point2f($(_c)[1] - BLOCK_W/2, $(_c)[2])
    scatter!(_ax, @lift([$(_ip)]); color=RGBf(0.25, 0.45, 0.75), markersize=PORT_PX)

    # output port — scatter! (different color)
    _op = @lift Point2f($(_c)[1] + BLOCK_W/2, $(_c)[2])
    scatter!(_ax, @lift([$(_op)]); color=RGBf(0.82, 0.28, 0.22), markersize=PORT_PX)

    # connection curve — lines! with bezier-computed Observable{Vector{Point2f}}
    _psrc = Observable(Point2f(0.0, 0.0))
    _pdst = Observable(Point2f(2.0, 0.0))
    _curv = @lift begin
        p0, p1 = $(_psrc), $(_pdst)
        xs, ys = _bezier(p0[1], p0[2], p1[1], p1[2])
        Point2f.(xs, ys)
    end
    lines!(_ax, _curv; color=_WIRE_COLOR, linewidth=1.8)

    # arrowhead — poly! with Observable{Vector{Point2f}}
    _arrw = @lift _arrowhead($(_psrc), $(_pdst))
    poly!(_ax, _arrw; color=_WIRE_COLOR)
end

end
