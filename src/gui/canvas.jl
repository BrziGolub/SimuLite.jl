module Canvas

using GLMakie
using ..Types
import ..BlocksAPI: input_ports, output_ports
import ..Diagram: connect!, add_block!, remove_block!, disconnect!
import ..BlocksSources: ConstantBlock, StepBlock, SineBlock
import ..BlocksMath: GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock
import ..Runner: simulate
using JSON3

export draw_diagram

const BLOCK_W  = 1.2
const BLOCK_H  = 0.7
const PORT_PX  = 12
const PORT_HIT = 0.18

# ── Internal visual tracking ──────────────────────────────────────────────────

mutable struct BlockVisual
    rect  :: Any
    label :: Any
    ports :: Vector{Any}
end

mutable struct ConnVisual
    curve :: Any
    arrow :: Any
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

function _hit_block(center, pos)
    abs(pos[1] - center[1]) <= BLOCK_W / 2 &&
    abs(pos[2] - center[2]) <= BLOCK_H / 2
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

function _setup_block!(ax, block, block_centers, block_strokes, port_pos, port_type)
    cx, cy = block.position
    c  = Observable(Point2f(cx, cy))
    sc = Observable{Symbol}(:black)
    block_centers[block] = c
    block_strokes[block] = sc

    iports = input_ports(block)
    oports = output_ports(block)
    ni, no = length(iports), length(oports)

    for (i, p) in enumerate(iports)
        frac = Float64(i) / (ni + 1) - 0.5
        port_pos[(block, p)]  = @lift Point2f($c[1] - BLOCK_W/2, $c[2] + BLOCK_H * frac)
        port_type[(block, p)] = :input
    end
    for (i, p) in enumerate(oports)
        frac = Float64(i) / (no + 1) - 0.5
        port_pos[(block, p)]  = @lift Point2f($c[1] + BLOCK_W/2, $c[2] + BLOCK_H * frac)
        port_type[(block, p)] = :output
    end

    rect_pts = @lift Point2f[
        ($c[1] - BLOCK_W/2, $c[2] - BLOCK_H/2),
        ($c[1] + BLOCK_W/2, $c[2] - BLOCK_H/2),
        ($c[1] + BLOCK_W/2, $c[2] + BLOCK_H/2),
        ($c[1] - BLOCK_W/2, $c[2] + BLOCK_H/2),
    ]
    rect  = poly!(ax, rect_pts;
        color = RGBf(0.93, 0.96, 1.0), strokecolor = sc, strokewidth = 2)
    label = text!(ax, @lift([$c]);
        text = [block.name], align = (:center, :center), fontsize = 13)

    port_plots = Any[]
    for p in iports
        push!(port_plots,
            scatter!(ax, @lift([$(port_pos[(block, p)])]);
                color = :steelblue, markersize = PORT_PX))
    end
    for p in oports
        push!(port_plots,
            scatter!(ax, @lift([$(port_pos[(block, p)])]);
                color = :tomato, markersize = PORT_PX))
    end

    return BlockVisual(rect, label, port_plots)
end

function _add_connection_visual!(ax, conn, port_pos)
    src_obs = port_pos[(conn.src_block, conn.src_port)]
    dst_obs = port_pos[(conn.dst_block, conn.dst_port)]

    curve_pts = @lift begin
        p0, p1 = $src_obs, $dst_obs
        xs, ys = _bezier(p0[1], p0[2], p1[1], p1[2])
        Point2f.(xs, ys)
    end
    curve = lines!(ax, curve_pts; color = :black, linewidth = 1.5)

    arrow_pts = @lift _arrowhead($src_obs, $dst_obs)
    arrow = poly!(ax, arrow_pts; color = :black)

    return ConnVisual(curve, arrow)
end

function _delete_block!(ax, diagram, block,
                        block_centers, block_strokes, port_pos, port_type,
                        block_visuals, conn_visuals)
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
    delete!(ax, bv.rect)
    delete!(ax, bv.label)
    for s in bv.ports; delete!(ax, s); end

    for p in vcat(input_ports(block), output_ports(block))
        delete!(port_pos,  (block, p))
        delete!(port_type, (block, p))
    end
    delete!(block_visuals, block)
    delete!(block_centers, block)
    delete!(block_strokes, block)
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
    else
        error("Unknown block type in file: $type_name")
    end
    b.name     = name
    b.position = (Float64(position[1]), Float64(position[2]))
    return b
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    draw_diagram(diagram) -> Figure

Opens the SimuLite GUI window. Layout:
- Left:   block diagram canvas
- Middle: block palette
- Right:  properties panel (updates when a block is selected)
- Bottom: simulation toolbar + results plots

Interactions:
- **Palette** — click to add a block at canvas center
- **Drag** a block to reposition it
- **Output port** (red) → **Input port** (blue) to wire
- **Select block** → edit parameters in Properties panel (Enter to apply)
- **Escape** — cancel wire / deselect
- **Delete** — remove selected block and its connections
- **▶ Run** — simulate and show signal plots
- **Clear** — remove all blocks and connections
"""
function draw_diagram(diagram::BlockDiagram)
    _res = try; GLMakie.primary_resolution(); catch; (1600, 900); end
    fig = Figure(size = (round(Int, _res[1] * 0.92), round(Int, _res[2] * 0.88)))

    # ── Row 1: canvas | palette | properties ─────────────────────────────────
    ax = Axis(fig[1, 1];
        leftspinecolor   = RGBf(0.30, 0.50, 0.78),
        rightspinecolor  = RGBf(0.30, 0.50, 0.78),
        bottomspinecolor = RGBf(0.30, 0.50, 0.78),
        topspinecolor    = RGBf(0.30, 0.50, 0.78),
        spinewidth       = 2,
        backgroundcolor  = RGBf(0.97, 0.98, 1.00))
    hidedecorations!(ax)
    limits!(ax, -2.0, 14.0, -6.0, 6.0)

    palette_grid   = GridLayout(fig[1, 2])
    btn_tab_blocks = Button(palette_grid[1, 1]; label = "Blocks", tellwidth = true)
    btn_tab_file   = Button(palette_grid[2, 1]; label = "File",   tellwidth = true)

    props_grid = GridLayout(fig[1, 3])
    Label(props_grid[1, 1:2], "Properties"; fontsize = 13, halign = :center)

    colsize!(fig.layout, 1, Auto())      # canvas: fills space left by sidebars
    colsize!(fig.layout, 2, Fixed(140))  # palette
    colsize!(fig.layout, 3, Fixed(200))  # properties

    rowsize!(fig.layout, 1, Relative(0.60))  # canvas: 60% of window height

    # ── Row 2: simulation toolbar (full width) ────────────────────────────────
    toolbar = GridLayout(fig[2, 1:3])
    rowsize!(fig.layout, 2, Auto(false))

    btn_run = Button(toolbar[1, 1]; label = "▶  Run")
    Label(toolbar[1, 2], "  t:";  tellwidth = false)
    tb_tstart = Textbox(toolbar[1, 3];
        displayed_string = string(diagram.config.tspan[1]), width = 60)
    Label(toolbar[1, 4], "→";  tellwidth = false)
    tb_tend   = Textbox(toolbar[1, 5];
        displayed_string = string(diagram.config.tspan[2]), width = 60)
    Label(toolbar[1, 6], "  dt:"; tellwidth = false)
    tb_dt     = Textbox(toolbar[1, 7];
        displayed_string = string(diagram.config.dt), width = 60)
    btn_clear = Button(toolbar[1, 8]; label = "Clear")

    # ── Row 3: results axis (full width) ─────────────────────────────────────
    results_ax = Axis(fig[3, 1:3],
        title  = "Results",
        xlabel = "t",
        ylabel = "signal")
    rowsize!(fig.layout, 3, Relative(0.28))  # results: 28% of window height

    # ── Row 4: status bar ─────────────────────────────────────────────────────
    status = Observable("Build a diagram, then click ▶ Run")
    Label(fig[4, 1:3], status; tellwidth = false, fontsize = 12)
    rowsize!(fig.layout, 4, Auto(false))

    deregister_interaction!(ax, :rectanglezoom)

    # ── State dicts ───────────────────────────────────────────────────────────
    block_centers  = Dict{AbstractBlock, Observable{Point2f}}()
    block_strokes  = Dict{AbstractBlock, Observable{Symbol}}()
    port_pos       = Dict{Tuple{Any, Symbol}, Observable{Point2f}}()
    port_type      = Dict{Tuple{Any, Symbol}, Symbol}()
    block_visuals  = Dict{AbstractBlock, BlockVisual}()
    conn_visuals   = Dict{Connection,    ConnVisual}()
    results_legend = Ref{Any}(nothing)

    # ── Draw existing diagram ─────────────────────────────────────────────────
    for block in diagram.blocks
        block_visuals[block] = _setup_block!(ax, block,
            block_centers, block_strokes, port_pos, port_type)
    end
    for conn in diagram.connections
        conn_visuals[conn] = _add_connection_visual!(ax, conn, port_pos)
    end

    # ── Rubber-band wire ──────────────────────────────────────────────────────
    wire_active = Observable(false)
    rubber_pts  = Observable(Point2f[(0f0, 0f0), (1f0, 0f0)])
    lines!(ax, rubber_pts;
        color = :gray, linewidth = 1.5, linestyle = :dash, visible = wire_active)

    # ── Properties panel ──────────────────────────────────────────────────────
    prop_items = Ref{Vector{Any}}(Any[])

    function clear_props!()
        for item in prop_items[]
            delete!(item)
        end
        prop_items[] = Any[]
    end

    function show_props!(block)
        clear_props!()
        bv = block_visuals[block]
        row = Ref(2)

        function add_field!(fname::String, value::String, on_commit)
            r = row[]
            push!(prop_items[],
                Label(props_grid[r, 1], fname * ":";
                    halign = :right, fontsize = 12))
            tb = Textbox(props_grid[r, 2];
                displayed_string = value,
                tellwidth        = false,
                fontsize         = 12)
            push!(prop_items[], tb)
            on(tb.stored_string) do s
                s === nothing && return
                try
                    on_commit(s)
                catch _
                end
            end
            row[] += 1
        end

        add_field!("Name", block.name, s -> begin
            block.name = s
            bv.label.text[] = [s]
        end)

        if block isa ConstantBlock
            add_field!("Value", string(block.value),
                s -> block.value = parse(Float64, s))
        elseif block isa GainBlock
            add_field!("k", string(block.k),
                s -> block.k = parse(Float64, s))
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
        elseif block isa IntegratorBlock
            add_field!("Init state", string(block.state), s -> begin
                v = parse(Float64, s)
                block.state      = v
                block.next_state = v
            end)
        elseif block isa UnitDelayBlock
            add_field!("Init state", string(block.state), s -> begin
                v = parse(Float64, s)
                block.state      = v
                block.next_state = v
            end)
        elseif block isa SumBlock
            add_field!("Signs", block.signs, s -> block.signs = s)
        end
    end

    # ── Interaction state ─────────────────────────────────────────────────────
    wire_src      = Ref{Union{Nothing, Tuple{Any, Symbol}}}(nothing)
    selected      = Ref{Union{Nothing, AbstractBlock}}(nothing)
    selected_conn = Ref{Union{Nothing, Connection}}(nothing)
    drag_offset   = Ref((0.0, 0.0))

    function _clear_all!()
        _deselect_conn!()
        if selected[] !== nothing
            selected[] = nothing
            clear_props!()
        end
        if wire_active[]
            wire_active[] = false
            wire_src[]    = nothing
        end
        for block in copy(diagram.blocks)
            _delete_block!(ax, diagram, block,
                block_centers, block_strokes, port_pos, port_type,
                block_visuals, conn_visuals)
        end
        empty!(results_ax)
        if results_legend[] !== nothing
            delete!(results_legend[])
            results_legend[] = nothing
        end
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
                cv.curve.color[] = :black
                cv.arrow.color[] = :black
            end
            selected_conn[] = nothing
        end
    end

    function _deselect!()
        _deselect_conn!()
        if selected[] !== nothing
            block_strokes[selected[]][] = :black
            selected[] = nothing
            clear_props!()
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
                        if _hit_block(block_centers[block][], pos)
                            selected[]             = block
                            c                      = block_centers[block][]
                            drag_offset[]          = (c[1] - pos[1], c[2] - pos[2])
                            block_strokes[block][] = :dodgerblue
                            show_props!(block)
                            status[] = "$(block.name) selected — edit properties on the right, Delete to remove"
                            break
                        end
                    end
                    if selected[] === nothing
                        for (conn, cv) in conn_visuals
                            if _hit_connection(conn, port_pos, pos)
                                selected_conn[]    = conn
                                cv.curve.color[]   = :orange
                                cv.arrow.color[]   = :orange
                                status[] = "Connection selected — press Delete to remove"
                                break
                            end
                        end
                    end
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
                clear_props!()
                _delete_block!(ax, diagram, block,
                    block_centers, block_strokes, port_pos, port_type,
                    block_visuals, conn_visuals)
                status[] = "Block deleted"
            end
        end
    end

    # ── Palette: tabbed content ───────────────────────────────────────────────
    pal_items    = Ref{Vector{Any}}(Any[])
    filename_ref = Ref{String}("diagram.json")

    function clear_pal!()
        for item in pal_items[]; delete!(item); end
        pal_items[] = Any[]
    end

    sources_pal = [
        ("Constant",  () -> ConstantBlock(0.0)),
        ("Step",      () -> StepBlock()),
        ("Sine",      () -> SineBlock()),
    ]
    math_pal = [
        ("Gain",        () -> GainBlock(1.0)),
        ("Sum  ++",     () -> SumBlock("++")),
        ("Sum  +-",     () -> SumBlock("+-")),
        ("Integrator",  () -> IntegratorBlock(0.0)),
        ("Unit Delay",  () -> UnitDelayBlock(0.0)),
    ]

    function show_blocks_tab!()
        clear_pal!()
        btn_tab_blocks.buttoncolor[] = RGBf(0.30, 0.50, 0.78)
        btn_tab_file.buttoncolor[]   = RGBf(0.85, 0.85, 0.85)
        row = Ref(3)

        function pal_cat!(text)
            lbl = Label(palette_grid[row[], 1], text;
                fontsize = 11, halign = :center, color = :gray50)
            push!(pal_items[], lbl)
            row[] += 1
        end

        function pal_block!(lbl_text, factory)
            btn = Button(palette_grid[row[], 1]; label = lbl_text, tellwidth = true)
            on(btn.clicks) do _
                block = factory()
                r = ax.finallimits[]
                block.position = (Float64(r.origin[1] + r.widths[1] / 2),
                                  Float64(r.origin[2] + r.widths[2] / 2))
                try
                    add_block!(diagram, block)
                catch e
                    status[] = e isa DiagramError ? sprint(showerror, e) : "Error — see REPL"
                    e isa DiagramError || rethrow(e)
                    return
                end
                block_visuals[block] = _setup_block!(ax, block,
                    block_centers, block_strokes, port_pos, port_type)
                status[] = "Added $(block.name) — drag to position"
            end
            push!(pal_items[], btn)
            row[] += 1
        end

        pal_cat!("─ Sources ─")
        for (lbl, factory) in sources_pal; pal_block!(lbl, factory); end
        pal_cat!("─ Math ─")
        for (lbl, factory) in math_pal;    pal_block!(lbl, factory); end
    end

    function show_file_tab!()
        clear_pal!()
        btn_tab_blocks.buttoncolor[] = RGBf(0.85, 0.85, 0.85)
        btn_tab_file.buttoncolor[]   = RGBf(0.30, 0.50, 0.78)
        row = Ref(3)

        function fadd!(w); push!(pal_items[], w); row[] += 1; w; end

        fadd!(Label(palette_grid[row[], 1], "Filename:";
            fontsize = 11, halign = :left))
        tb = fadd!(Textbox(palette_grid[row[], 1];
            displayed_string = filename_ref[], tellwidth = true, fontsize = 11))
        on(tb.stored_string) do s; s === nothing || (filename_ref[] = s); end

        btn_save = fadd!(Button(palette_grid[row[], 1]; label = "Save", tellwidth = true))
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

        btn_load = fadd!(Button(palette_grid[row[], 1]; label = "Load", tellwidth = true))
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
                        block_centers, block_strokes, port_pos, port_type)
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
                status[] = "Loaded from $path — $(length(diagram.blocks)) blocks, $(length(diagram.connections)) connections"
            catch e
                status[] = "Load failed: $(sprint(showerror, e))"
                @warn "Load error" exception = (e, catch_backtrace())
            end
        end
    end

    on(btn_tab_blocks.clicks) do _; show_blocks_tab!(); end
    on(btn_tab_file.clicks)   do _; show_file_tab!();   end
    show_blocks_tab!()

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

    # ── Toolbar: Run button ───────────────────────────────────────────────────
    on(btn_run.clicks) do _
        try
            result = simulate(diagram)
            empty!(results_ax)
            if results_legend[] !== nothing
                delete!(results_legend[])
                results_legend[] = nothing
            end
            for (sig_name, vals) in sort(collect(result.data))
                lines!(results_ax, result.t, vals; label = sig_name)
            end
            if !isempty(result.data)
                results_legend[] = axislegend(results_ax; position = :lt)
            end
            autolimits!(results_ax)
            n = length(result.t)
            status[] = "Run complete — $(n) steps, $(length(result.data)) signals plotted"
        catch e
            status[] = "Run failed: $(sprint(showerror, e))"
            @warn "Simulation error" exception = (e, catch_backtrace())
        end
    end

    # ── Toolbar: Clear button ─────────────────────────────────────────────────
    on(btn_clear.clicks) do _
        _clear_all!()
        status[] = "Diagram cleared"
    end

    display(fig)
    return fig
end

end
