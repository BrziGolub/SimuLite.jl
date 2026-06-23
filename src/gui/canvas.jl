module Canvas

using GLMakie
using ..Types
import ..BlocksAPI: input_ports, output_ports
import ..Diagram: connect!, add_block!, remove_block!, disconnect!
import ..BlocksSources: ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock
import ..BlocksMath: GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
                    ProductBlock, SaturationBlock, AbsBlock,
                    DerivativeBlock, PIDBlock, LookupTable1DBlock,
                    TransferFnBlock, StateSpaceBlock
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
end

mutable struct ConnVisual
    curve :: Any
    arrow :: Any
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

function _bezier(x0, y0, x1, y1; n=60)
    dx = max(abs(x1 - x0) * 0.45, 0.35)
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
    xs, ys
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

    return BlockVisual(strip, icon, border, divider, sym, label, port_plots, bdr_color)
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
    delete!(ax, bv.strip)
    delete!(ax, bv.icon)
    delete!(ax, bv.border)
    delete!(ax, bv.divider)
    delete!(ax, bv.sym)
    delete!(ax, bv.label)
    for s in bv.ports; delete!(ax, s); end

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

function _open_props_window!(block, block_visuals, prop_screens,
                             ax, diagram, block_centers, block_heights,
                             port_pos, port_type, conn_visuals)
    if haskey(prop_screens, block)
        prev = prop_screens[block]
        try; prev.window_open[] && close(prev); catch _; end
        delete!(prop_screens, block)
    end

    bv  = block_visuals[block]
    fig = Figure(size = (320, 400))
    g   = GridLayout(fig[1, 1])

    # Title bar style header
    Label(g[1, 1:2], "Block Parameters — " * string(nameof(typeof(block)));
        fontsize = 13, halign = :left, font = :bold,
        color = RGBf(0.15, 0.15, 0.15))

    # Thin separator
    Label(g[2, 1:2], ""; fontsize = 2)

    row = Ref(3)

    function add_field!(fname, value, on_commit)
        r = row[]
        Label(g[r, 1], fname * ":"; halign = :right, fontsize = 12)
        tb = Textbox(g[r, 2]; displayed_string = value, tellwidth = false, fontsize = 12)
        on(tb.stored_string) do s
            s === nothing && return
            try; on_commit(s); catch _; end
        end
        row[] += 1
    end

    function add_info!(text)
        Label(g[row[], 1:2], text; fontsize = 11, halign = :left,
              color = RGBf(0.40, 0.40, 0.40))
        row[] += 1
    end

    add_field!("Name", block.name, s -> begin
        block.name = s
        bv.label.text[] = [s]
    end)

    if block isa ConstantBlock
        add_field!("Value", string(block.value),
            s -> block.value = parse(Float64, s))
    elseif block isa StepBlock
        add_field!("Step time", string(block.step_time),
            s -> block.step_time = parse(Float64, s))
        add_field!("Before",    string(block.before),
            s -> block.before    = parse(Float64, s))
        add_field!("After",     string(block.after),
            s -> block.after     = parse(Float64, s))
    elseif block isa SineBlock
        add_field!("Amplitude", string(block.amplitude),
            s -> block.amplitude = parse(Float64, s))
        add_field!("Frequency", string(block.frequency),
            s -> block.frequency = parse(Float64, s))
        add_field!("Phase",     string(block.phase),
            s -> block.phase     = parse(Float64, s))
        add_field!("Offset",    string(block.offset),
            s -> block.offset    = parse(Float64, s))
    elseif block isa RampBlock
        add_field!("Slope",      string(block.slope),
            s -> block.slope      = parse(Float64, s))
        add_field!("Start time", string(block.start_time),
            s -> block.start_time = parse(Float64, s))
        add_field!("Bias",       string(block.bias),
            s -> block.bias       = parse(Float64, s))
    elseif block isa GainBlock
        add_field!("k", string(block.k),
            s -> block.k = parse(Float64, s))
    elseif block isa SumBlock
        add_field!("Signs", block.signs, s -> begin
            all(c -> c == '+' || c == '-', s) || return
            isempty(s) && return
            if length(s) != length(block.signs)
                new_syms = [Symbol("in$i") for i in 1:length(s)]
                _reconfigure_inputs!(ax, block, new_syms, diagram,
                    block_centers, block_heights, port_pos, port_type,
                    conn_visuals, block_visuals)
            end
            block.signs = s
        end)
    elseif block isa IntegratorBlock
        add_field!("x0 (init)", string(block.x0), s -> begin
            v = parse(Float64, s)
            block.x0         = v
            block.state      = v
            block.next_state = v
        end)
    elseif block isa UnitDelayBlock
        add_field!("x0 (init)", string(block.x0), s -> begin
            v = parse(Float64, s)
            block.x0         = v
            block.state      = v
            block.next_state = v
        end)
    elseif block isa SaturationBlock
        add_field!("Lower", string(block.lower),
            s -> block.lower = parse(Float64, s))
        add_field!("Upper", string(block.upper),
            s -> block.upper = parse(Float64, s))
    elseif block isa DerivativeBlock
        add_field!("N (bandwidth)", string(block.N),
            s -> block.N = parse(Float64, s))
    elseif block isa PIDBlock
        add_field!("Kp",      string(block.Kp),
            s -> block.Kp      = parse(Float64, s))
        add_field!("Ki",      string(block.Ki),
            s -> block.Ki      = parse(Float64, s))
        add_field!("Kd",      string(block.Kd),
            s -> block.Kd      = parse(Float64, s))
        add_field!("N",       string(block.N),
            s -> block.N       = parse(Float64, s))
        add_field!("Out min", string(block.out_min),
            s -> block.out_min = parse(Float64, s))
        add_field!("Out max", string(block.out_max),
            s -> block.out_max = parse(Float64, s))
    elseif block isa ScopeBlock
        add_field!("Title", block.title, s -> block.title = s)
        add_field!("Ports (1–3)", string(block.n_ports), s -> begin
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
        add_info!("num: [$(join(block.num, ", "))]")
        add_info!("den: [$(join(block.den, ", "))]")
        add_info!("Order: $(length(block.den) - 1)")
    elseif block isa StateSpaceBlock
        add_info!("Order: $(size(block.A_c, 1)) state(s)")
        add_info!("D = $(block.D_c)")
    end

    # Close button
    screen_ref = Ref{Any}(nothing)
    btn_close = Button(g[row[], 1:2]; label = "Close", tellwidth = false)
    on(btn_close.clicks) do _
        s = screen_ref[]
        s === nothing && return
        try; s.window_open[] && close(s); catch _; end
        delete!(prop_screens, block)
    end

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
    fig = Figure(size = (round(Int, _res[1] * 0.92), round(Int, _res[2] * 0.88)))

    # ── Row 1: single toolbar ────────────────────────────────────────────────
    toolbar = GridLayout(fig[1, 1:2])
    rowsize!(fig.layout, 1, Auto(false))

    # File operations
    btn_new  = Button(toolbar[1, 1]; label = "New")
    btn_save = Button(toolbar[1, 2]; label = "Save")
    btn_load = Button(toolbar[1, 3]; label = "Load")
    filename_ref = Ref{String}("diagram.json")
    tb_filename  = Textbox(toolbar[1, 4];
        displayed_string = "diagram.json", width = 130, fontsize = 11)
    on(tb_filename.stored_string) do s; s === nothing || (filename_ref[] = s); end

    Label(toolbar[1, 5], " │"; tellwidth = false, color = RGBf(0.75, 0.75, 0.75))

    # Run controls
    btn_run  = Button(toolbar[1, 6]; label = "▶  Run",
        buttoncolor = RGBf(0.22, 0.62, 0.32), labelcolor = :white)
    Button(toolbar[1, 7]; label = "■ Stop")   # UI placeholder, no handler
    btn_clear = Button(toolbar[1, 8]; label = "✕  Clear")

    Label(toolbar[1, 9], " │"; tellwidth = false, color = RGBf(0.75, 0.75, 0.75))

    # Simulation time parameters
    Label(toolbar[1, 10], "t₀:"; tellwidth = false, fontsize = 12)
    tb_tstart = Textbox(toolbar[1, 11];
        displayed_string = string(diagram.config.tspan[1]), width = 60)
    Label(toolbar[1, 12], "tstop:"; tellwidth = false, fontsize = 12)
    tb_tend   = Textbox(toolbar[1, 13];
        displayed_string = string(diagram.config.tspan[2]), width = 60)
    Label(toolbar[1, 14], "Δt:"; tellwidth = false, fontsize = 12)
    tb_dt     = Textbox(toolbar[1, 15];
        displayed_string = string(diagram.config.dt), width = 60)

    Label(toolbar[1, 16], ""; tellwidth = true)   # flex spacer

    # ── Row 2: palette | canvas ───────────────────────────────────────────────
    palette_grid = GridLayout(fig[2, 1])

    # Row 1: header
    Label(palette_grid[1, 1:2], "Block Library";
        fontsize = 13, font = :bold, halign = :left,
        color = RGBf(0.15, 0.15, 0.15))

    # Row 2: category dropdown (Menu)
    cat_menu = Menu(palette_grid[2, 1:2];
        options  = ["All", "Sources", "Math", "Sinks"],
        default  = "All",
        tellwidth = true)

    # Row 3: search textbox
    tb_search = Textbox(palette_grid[3, 1:2];
        displayed_string = "", tellwidth = true, fontsize = 11)

    colsize!(palette_grid, 1, Fixed(28))
    colsize!(palette_grid, 2, Auto())

    # Canvas axis (dot-grid background; keeps existing warm-white dot style)
    ax = Axis(fig[2, 2];
        leftspinecolor   = RGBf(0.89, 0.88, 0.85),
        rightspinecolor  = RGBf(0.89, 0.88, 0.85),
        bottomspinecolor = RGBf(0.89, 0.88, 0.85),
        topspinecolor    = RGBf(0.89, 0.88, 0.85),
        spinewidth       = 1,
        backgroundcolor  = RGBf(0.98, 0.98, 0.97))
    hidedecorations!(ax)
    limits!(ax, -2.0, 14.0, -6.0, 6.0)

    let xs = Float64[], ys = Float64[]
        for x in -2.0:0.5:14.0, y in -6.0:0.5:6.0
            push!(xs, x); push!(ys, y)
        end
        scatter!(ax, xs, ys; color = RGBf(0.79, 0.82, 0.87), markersize = 3)
    end

    colsize!(fig.layout, 1, Fixed(236))
    colsize!(fig.layout, 2, Auto())
    rowsize!(fig.layout, 2, Relative(0.88))

    # ── Row 3: status bar ─────────────────────────────────────────────────────
    status = Observable("Build a diagram, then click ▶ Run")
    Label(fig[3, 1:2], status; tellwidth = false, fontsize = 12)
    rowsize!(fig.layout, 3, Auto(false))

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

    # ── Draw existing diagram ─────────────────────────────────────────────────
    for block in diagram.blocks
        block_visuals[block] = _setup_block!(ax, block,
            block_centers, block_strokes, block_heights, port_pos, port_type)
    end
    for conn in diagram.connections
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
    end

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
            block_strokes[selected[]][] = block_visuals[selected[]].border_color
            selected[] = nothing
        end
    end

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
                c = block_centers[selected[]][]
                selected[].position = (Float64(c[1]), Float64(c[2]))
            end
        end
    end

    on(events(ax.scene).keyboardbutton) do ev
        ev.action == Keyboard.press || return
        if ev.key == Keyboard.escape
            wire_active[] ? _cancel_wire!() : _deselect!()
        elseif ev.key == Keyboard.delete && !wire_active[]
            if selected_conn[] !== nothing
                conn = selected_conn[]
                _deselect_conn!()
                cv = conn_visuals[conn]
                delete!(ax, cv.curve)
                delete!(ax, cv.arrow)
                delete!(conn_visuals, conn)
                disconnect!(diagram, conn.src_block, conn.src_port,
                            conn.dst_block, conn.dst_port)
                status[] = "Connection deleted"
            elseif selected[] !== nothing
                block = selected[]
                selected[] = nothing
                _delete_block!(ax, diagram, block,
                    block_centers, block_strokes, block_heights,
                    port_pos, port_type, block_visuals, conn_visuals)
                status[] = "Block deleted"
            end
        end
    end

    # ── Palette: category menu + search ──────────────────────────────────────
    pal_items        = Ref{Vector{Any}}(Any[])
    next_content_row = Ref(4)   # rows 1-3: header / menu / search
    active_cat       = Ref{String}("All")
    search_obs       = Observable("")

    # Palette data: (icon_sym, border_color, label, factory)
    sources_pal = [
        ("1",    _BLUE_BORDER, "Constant",       () -> ConstantBlock(0.0)),
        ("⎍",    _BLUE_BORDER, "Step",           () -> StepBlock()),
        ("∿",    _BLUE_BORDER, "Sine",           () -> SineBlock()),
        ("╱",    _BLUE_BORDER, "Ramp",           () -> RampBlock()),
        ("⏱",    _BLUE_BORDER, "Clock",          () -> ClockBlock()),
    ]
    math_pal = [
        ("▷",    _BLUE_BORDER, "Gain",           () -> GainBlock(1.0)),
        ("Σ",    _BLUE_BORDER, "Sum",             () -> SumBlock("++")),
        ("∫",    _BLUE_BORDER, "Integrator",     () -> IntegratorBlock(0.0)),
        ("z⁻¹",  _BLUE_BORDER, "Unit Delay",     () -> UnitDelayBlock(0.0)),
        ("×",    _BLUE_BORDER, "Product ×2",     () -> ProductBlock([:mul, :mul])),
        ("sat",  _BLUE_BORDER, "Saturation",     () -> SaturationBlock()),
        ("|u|",  _BLUE_BORDER, "Abs",            () -> AbsBlock()),
        ("d/dt", _BLUE_BORDER, "Derivative",     () -> DerivativeBlock()),
        ("PID",  _AMGR_BORDER, "PID",            () -> PIDBlock()),
        ("f(x)", _BLUE_BORDER, "Lookup 1D",      () -> LookupTable1DBlock()),
        ("H(s)", _BLUE_BORDER, "Transfer Fcn",   () -> TransferFnBlock([1.0], [1.0, 1.0])),
        ("SS",   _BLUE_BORDER, "State Space",    () -> StateSpaceBlock([-1.0;;], [1.0], [1.0], 0.0)),
    ]
    sinks_pal = [
        ("∿",    _GRNN_BORDER, "Scope",          () -> ScopeBlock()),
        ("ws",   _GRNN_BORDER, "Workspace",      () -> WorkspaceBlock()),
        ("▪",    _GRNN_BORDER, "Terminator",     () -> TerminatorBlock()),
    ]

    function clear_pal!()
        for item in pal_items[]; delete!(item); end
        pal_items[] = Any[]
        next_content_row[] = 4
        trim!(palette_grid)
    end

    function _pal_block!(sym_text, bdr_color, lbl_text, factory)
        r = next_content_row[]
        next_content_row[] += 1
        chip = Label(palette_grid[r, 1], sym_text;
            fontsize = 11, halign = :center, valign = :center, color = bdr_color)
        btn  = Button(palette_grid[r, 2]; label = lbl_text,
            tellwidth = true, fontsize = 11)
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
            status[] = "Added $(block.name) — drag to position"
        end
        push!(pal_items[], chip)
        push!(pal_items[], btn)
    end

    function _pal_category!(label_text, cat_target)
        r = next_content_row[]
        next_content_row[] += 1
        btn = Button(palette_grid[r, 1:2]; label = label_text,
            tellwidth = true, fontsize = 12)
        on(btn.clicks) do _
            active_cat[] = cat_target
            _build_pal!(cat_target, "")
        end
        push!(pal_items[], btn)
    end

    function _build_pal!(cat_str, search_txt)
        clear_pal!()
        if cat_str == "All" && isempty(search_txt)
            _pal_category!("Sources",  "Sources")
            _pal_category!("Math",     "Math")
            _pal_category!("Sinks",    "Sinks")
            return
        end
        items = if cat_str == "Sources"
            sources_pal
        elseif cat_str == "Math"
            math_pal
        elseif cat_str == "Sinks"
            sinks_pal
        else
            vcat(sources_pal, math_pal, sinks_pal)
        end
        txt = lowercase(search_txt)
        for (sym, clr, lbl, factory) in items
            if isempty(txt) || occursin(txt, lowercase(lbl))
                _pal_block!(sym, clr, lbl, factory)
            end
        end
    end

    # Wire category menu and search to palette rebuild
    on(cat_menu.selection) do cat
        active_cat[] = String(cat)
        _build_pal!(active_cat[], search_obs[])
    end
    on(tb_search.stored_string) do s
        s === nothing && return
        search_obs[] = lowercase(s)
    end
    on(search_obs) do txt
        _build_pal!(active_cat[], txt)
    end
    _build_pal!("All", "")

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

    display(fig)
    return fig
end

end
