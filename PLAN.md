# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-07-15 — session 11)

### Simulation engine — COMPLETE
- Fixed-step discrete runner (`simulate`) — feed-forward chains, integrators, unit delays, feedback loops
- ODE compiler path via ModelingToolkit (`simulate_ode`) — symbolic ODE system, adaptive solver
- Three-phase block lifecycle: `initialize!` (reset state) → `evaluate!` (output current state) → `commit_state!` (advance state)
- `simulate` calls `initialize!` on every block before the loop; pass `continue_sim=true` to skip and carry over final states from the previous run
- Topological sort (Kahn's algorithm) with feedback loop support — memory blocks (Integrator, UnitDelay, TF/SS with D=0) act as cycle-breakers; pure algebraic loops throw `AlgebraicLoopError`
- `simulate` returns `SimResult(t, data)` — time vector + named signal vectors

### Model layer — COMPLETE
- `BlockDiagram` with `SimConfig` (tspan, dt) and `Vector{Connection}`
- `add_block!` validates unique names → throws `DuplicateNameError`
- `connect!` validates port existence and no double-driven inputs → throws `PortNotFoundError`, `PortAlreadyConnectedError`
- `disconnect!` and `remove_block!` (removes block + all its connections)
- `input_ports(block)` / `output_ports(block)` — stable GUI API for port introspection
- All blocks have `name::String` and `position::Tuple{Float64,Float64}`

### Blocks available — 20 total
| Block | Module | Constructor | Notes |
|---|---|---|---|
| `ConstantBlock` | sources | `ConstantBlock(value)` | Scalar constant output |
| `StepBlock` | sources | `StepBlock(; step_time, before, after)` | Step at configurable time |
| `SineBlock` | sources | `SineBlock(; amplitude, frequency, phase, offset)` | Sinusoidal output |
| `RampBlock` | sources | `RampBlock(; slope, start_time, bias)` | Linear ramp starting at `start_time` |
| `ClockBlock` | sources | `ClockBlock()` | Outputs simulation time `t` |
| `GainBlock` | math | `GainBlock(k)` | Scalar multiply |
| `SumBlock` | math | `SumBlock("+-")` | Configurable signs per input; rendered as a circle with per-port `+`/`−` glyphs (GUI) |
| `IntegratorBlock` | math | `IntegratorBlock(x0)` | Forward Euler, feeds MTK ODE compiler |
| `UnitDelayBlock` | math | `UnitDelayBlock(x0)` | Discrete z⁻¹ |
| `ProductBlock` | math | `ProductBlock(ops)` | `ops` is `Vector{Symbol}` of `:mul`/`:div` per port |
| `SaturationBlock` | math | `SaturationBlock(; lower, upper)` | `clamp(u, lower, upper)` |
| `AbsBlock` | math | `AbsBlock()` | `y = abs(u)` |
| `DerivativeBlock` | math | `DerivativeBlock(; N)` | Filtered derivative `H(s)=Ns/(s+N)`, 1 state var |
| `PIDBlock` | math | `PIDBlock(; Kp, Ki, Kd, N, out_min, out_max)` | 2 state vars (xi, fd); output clamped |
| `LookupTable1DBlock` | math | `LookupTable1DBlock(bp, vals)` | Linear interp, clamp extrapolation |
| `TransferFnBlock` | math | `TransferFnBlock(num, den)` | Continuous TF via ControlSystems.jl → ZOH-discretized; n state vars |
| `StateSpaceBlock` | math | `StateSpaceBlock(A, B, C, D)` | Continuous SS model → ZOH-discretized; n state vars |
| `ScopeBlock` | sinks | `ScopeBlock(; title, n_ports)` | Opens dedicated plot window on double-click; 1–3 ports |
| `WorkspaceBlock` | sinks | `WorkspaceBlock()` | Pass-through tap; logged as `name.out` in `SimResult.data` |
| `TerminatorBlock` | sinks | `TerminatorBlock()` | No-op sink — caps unused output ports |

### Known limitations (deferred)
- No algebraic loop solving — pure direct-feedthrough cycles (e.g. Gain→Sum→Gain, or PID fed straight back into a Sum with no plant) throw `AlgebraicLoopError`; feedback loops containing a memory block (Integrator, Unit Delay, strictly proper TF/SS, I-only PID) work correctly. The error message lists the cycle's block names and suggests inserting a memory block (session 10).
- All signals are scalar `Float64` only
- No subsystems / hierarchical diagrams

---

## File map
```
src/
  SimuLite.jl               — top-level module and exports
  model/
    types.jl                — Port, AbstractBlock, Connection,
                              SimConfig, BlockDiagram, SimResult,
                              DiagramError subtypes (incl. AlgebraicLoopError)
    diagram.jl              — add_block!, connect!, disconnect!,
                              remove_block!, get_execution_order
                              (cycle-aware Kahn's with memory-block breaking)
    blocks/
      api.jl                — evaluate!, commit_state!, initialize!,
                              input_ports, output_ports,
                              has_direct_feedthrough
      common.jl             — BlockBase, _next_id() counter
      sources.jl            — ConstantBlock, StepBlock, SineBlock,
                              RampBlock, ClockBlock
      math.jl               — GainBlock, SumBlock, IntegratorBlock,
                              UnitDelayBlock, ProductBlock,
                              SaturationBlock, AbsBlock,
                              DerivativeBlock, PIDBlock,
                              LookupTable1DBlock,
                              TransferFnBlock, StateSpaceBlock
      sinks.jl              — ScopeBlock, WorkspaceBlock, TerminatorBlock
  sim/
    compiler.jl             — stubs for the ODE compiler
                              (real impl in ext/SimuLiteCompilerExt.jl)
    runner.jl               — fixed-step simulation loop
  gui/
    canvas.jl               — full GUI: canvas, palette (Menu+search),
                              floating properties/scope windows,
                              single-row toolbar (New/Save/Load,
                              Run/Clear, t₀/tstop/Δt),
                              save/load (draw_diagram)
ext/
  SimuLiteCompilerExt.jl    — ODE compiler via ModelingToolkit
                              (package extension; loads with
                              `using ModelingToolkit, DifferentialEquations`)
test/
  runtests.jl               — (planned) main test entry point
```

---

## Key design decisions (permanent)
- **Three-phase block lifecycle** — `initialize!` resets state to initial conditions; `evaluate!` outputs current state; `commit_state!` advances state. Matches Simulink's Initialize/Output/Update method split. All 20 blocks have explicit `initialize!` methods; stateless blocks return `nothing`. `IntegratorBlock` and `UnitDelayBlock` store their original `x0` field so `initialize!` resets to the user-specified IC, not zero. `TransferFnBlock`/`StateSpaceBlock` also reset `dt_cached = -1` to force ZOH re-discretization. `simulate(; continue_sim=true)` skips initialization to resume from the previous run's final state.
- **Topological sort at simulation start** — blocks always evaluated upstream-first.
- **`name::String` on all blocks** — used as `SimResult.data` key prefix and MTK symbolic variable name.
- **`SumBlock` takes a signs string** — `"+-"` enables subtraction for feedback error signals.
- **Two simulation backends** — runner (fixed-step, fast, used by GUI); compiler (MTK ODE, accurate, available as advanced mode).
- **Custom exception hierarchy** — `DiagramError` subtypes so the GUI can catch specific errors and show user-friendly messages.
- **Observable-based GUI** — block centers, port positions, and connection curves are all `@lift`-derived Observables; dragging a block updates everything reactively without explicit redraws.
- **Icon-card block visual style** (wireframe Style C) — each block is split into two zones: top ~70% is a tinted icon zone with the type symbol (`⎍`, `Σ`, `PID`, `∿`, …), bottom 30% is a white name strip. Three category border colors: blue (`_BLUE_BORDER`) for Sources + most Math, amber (`_AMGR_BORDER`) for PID, green (`_GRNN_BORDER`) for Sinks. Selection uses bright dodgerblue `_SEL_COLOR`; deselect restores the block's natural `border_color` stored in `BlockVisual`.
- **Circular Sum block** (Simulink-style, exception to the icon-card style) — `SumBlock` renders as a filled circle (radius follows the reactive block height) instead of the two-zone card. Input ports are indexed explicitly `in1…inN` **top-to-bottom** (not via `Dict`-key order, which is unspecified), each with its `+`/`−` sign glyph painted just inside the circle next to the port, so the sign-to-port mapping is unambiguous. The output port is on the right edge, the name label sits below the circle. `_setup_sum_visual!` builds it; `_reconfigure_sum_inputs!` rebuilds arc ports + glyphs when the signs string changes (circle auto-resizes via `bh_obs`). `BlockVisual` gained `extras` (sign glyph plots) and `input_sides` (per-input side Observables); `_delete_block!` tolerates `nothing` visual slots.
- **Reactive block height** — `_block_height(block)` is wrapped in `Observable{Float64}` per block (`block_heights` dict); all geometry and port-position `@lift`s reference `$bh_obs` so the block resizes live when port count changes.
- **Single palette entry + reconfigurable ports** — `SumBlock` and `ScopeBlock` have one palette button each (default `"++"` / 1 port). Double-clicking their Properties window reconfigures port count on the fly: `_reconfigure_inputs!` tears down old port Observables/scatter plots and connection visuals for removed ports, rebuilds `block.base.inputs`, updates `bh_obs`, and recreates surviving connection visuals against the new port Observables. `ScopeBlock` properties are accessed via **Ctrl+double-click** (plain double-click opens the scope result window).
- **Block Library with Toggle-collapsible categories** (Section 5 wireframe, implemented from `design/Block Diagram Editor Wireframes.html`) — each category (Sources / Math / Sinks) is a header row `▸/▾ Name` + a Makie `Toggle` (blue `_MAKIE_BLUE` = #0072B2 when expanded); expanded categories list blocks as 30 px white chips (`Box` icon square + full-width `Button`, width `_PAL_CHIP_W`). Default: Sources expanded. The category `Menu` ("All categories" / specific) filters which sections appear (specific selection auto-expands); a non-empty search shows a flat filtered chip list. `rowgap!(palette_grid, 6)` must be re-applied at the end of every `_build_pal!` — rows created after a `rowgap!` call get the default gap again. Palette data is 3-tuples `(sym, label, factory)`; chips use the uniform blue accent, independent of block category. Collapsing a category deletes its Toggle from inside the Toggle's own `active` listener — verified safe.
- **Blue wires** — connections drawn in `_WIRE_COLOR = RGBf(0.19, 0.43, 0.69)` (linewidth 1.8); turn orange `_ORA_COLOR` on selection, restored on deselect.
- **Orthogonal feedback routing + bottom-entry Sum ports** — `_bezier` detects feedback wires (`x1 < x0 - 0.1`) and routes them as a **right-angle (Manhattan) path** through a channel below the blocks that rises vertically into the destination port (`_ortho_pts` densely samples the polyline so `_arrowhead`/`_hit_connection` keep working). Forward wires keep the S-curve. For **Sum blocks**, each input port carries a reactive `:left`/`:bottom` side (`BlockVisual.input_sides`); `_refresh_feedback_sides!` re-evaluates all Sum inputs after any topology/position change and moves feedback-fed ports (dot + sign glyph) to the bottom of the circle so the wire enters from below. Feedback is detected geometrically (source block centre right of destination centre); ports relocate on connect / disconnect / drag-release / load / signs-reconfigure / undo-redo / initial draw. Single-driven inputs make the "which port is feedback" mapping unambiguous.
- **Dot grid canvas** — 825 scatter dots at 0.5-unit spacing; Section 5 colors: white background `#ffffff`, neutral gray dots `_CANVAS_GRID`, `#cfcfcf` spines; dots zoom with the canvas naturally.
- **Sketch-5 UI chrome colors** (constants in `canvas.jl`) — window `_WIN_BG` #e9e9e9, toolbar/status/title strips `_TB_BG` #dedede, palette/dialog body `_PANEL_BG` #f3f3f3, 1 px `_PANEL_BRD` #b4b4b4 borders (drawn as `Box` fills created *before* the widgets sharing their grid cells), buttons `_BTN_BG` #d4d4d4 with `_BTN_BRD` #9e9e9e stroke, Run `_RUN_GREEN` #2f9e5b, accent `_MAKIE_BLUE` #0072B2. Figure uses `figure_padding = 0` and zero row/col gaps so panels are flush; rows: toolbar `Fixed(46)`, canvas `Auto` (all leftover), status `Fixed(28)`.
- **Single-row toolbar** (Section 5 wireframe style) — `New | Save | Load [filename]` for file ops, `↶ Undo | ↷ Redo` for edit history, `▶ Run | ■ Stop | ✕ Clear` for simulation, `t₀ [txt] tstop [txt] Δt [txt]` for timing, groups split by thin `│` separators. Undo/Redo sit **before** Run (Simulink order) and mirror the Ctrl+Z / Ctrl+Y shortcuts. All items are **left-aligned** via a flexible trailing spacer column (`colsize!(toolbar, N, Auto(false))`) that absorbs slack, with `colgap!(toolbar, 6)` tightening inter-item spacing. A **zoom cluster `− 100% +`** sits after the spacer (right edge, Section 5): buttons scale `ax.finallimits` by 0.8 / 1.25 around the view centre; the percentage label derives from `on(ax.finallimits)` relative to `_CANVAS_XLIM` span, so it stays correct for button zoom, scroll-wheel zoom, and view reset alike. Toolbar fixed content needs ≈1120 px window width. Buttons are 30 px tall, textboxes 28 px, separators are 1×26 px `Box`es (Section 5 sizes; toolbar strip `Fixed(46)` with `alignmode = Outside(8)`). **Constraint:** every other toolbar item — including the `t₀:`/`tstop:`/`Δt:` labels — must report its width (`tellwidth = true` / an explicit `width`); a non-reporting item makes its column undetermined, and undetermined Auto columns split the leftover width equally with the spacer, spreading items across the full toolbar (bug found+fixed session 9). No separate menubar strip. File tab removed from palette.
- **Block Library panel** (2-column layout, 236px total — Section 5 wireframe):
  - Row 1: "Block Library" bold header (span 1:2)
  - Row 2: `Menu` dropdown (All categories / Sources / Math / Sinks, span 1:2, 28 px)
  - Row 3: search `Textbox` (span 1:2, 28 px, `placeholder = "Search…"`)
  - Rows 4+: category header rows (label + Toggle, span 1:2) and block chip rows: icon `Box`+`Label` (col 1, 28px) + white name `Button` (col 2, `_PAL_CHIP_W` wide)
  - `next_content_row` Ref (starts at 4, reset on `clear_pal!`) tracks next row
  - `on(cat_menu.selection)` + `on(search_obs)` + `on(toggle.active)` → `_build_pal!(cat, txt)` filters and rebuilds from 3-tuple `(sym, label, factory)` lists
  - Grid-cell gotcha: Makie `Button`/`Textbox` do **not** stretch to fill their grid cell — give them explicit `width`, or labels ragged / text overflows the drawn box
  - **Virtual scrolling** (GLMakie grids have no native scroll container): `_pal_entries` builds the flat header+chip list, `_pal_visible_slots()` computes how many 36 px slots fit in the palette `Box` bbox (~155 px reserved), `_build_pal!` renders the `pal_scroll` slice plus a `⇕ scroll — a–b of N` hint row on overflow. Mouse wheel over the palette bbox (checked against `events(fig).mouseposition`, listener at `priority = 100`, returns `Consume(true)`) moves the offset 2 rows/tick; menu/search changes reset it; a `computedbbox` listener rebuilds when the fitting slot count changes on window resize
- **Dynamic block height** — `_block_height(block)` scales height as `max(BLOCK_H, PORT_HIT × 1.4 × (n_ports + 1))` so port hit-circles never overlap on multi-port blocks (e.g. Scope ×3).
- **Floating properties windows** (Section 5 "Parameter editor" styling) — double-clicking any non-Scope block opens a dedicated `GLMakie.Screen` (360 px wide, height sized to content via `resize!`); 34 px `#dedede` title strip "Block Parameters — [name]", field rows = 104 px label column + white 28 px `Textbox`es (explicit `width = 205`), and **Apply** (blue, commits every field then closes) / **Cancel** (closes without committing) buttons bottom-right. Fields no longer commit on Enter — commit closures are collected in an `appliers` list run by Apply. `TransferFnBlock` gets editable **Numerator/Denominator** coefficient fields (comma/space-separated, high→low order, parsed by `_parse_coeffs`, committed atomically via `set_tf_coeffs!` in `math.jl` which rebuilds the SS realization, resizes state, and invalidates the ZOH cache). Tracked per-block in `prop_screens` dict; replaced on re-open. `_clear_all!` closes all prop windows.
- **Scope windows** — `ScopeBlock` opens a dedicated `GLMakie.Screen` window on double-click; tracked per-block in `scope_screens` dict; old window always replaced on re-run. Title: `"∿ [title] — [name]"`; axis uses `xlabel = "t (s)"`, coloured lines per port.
- **JSON save/load** — `save_diagram`/`_reconstruct_block` live at module level in `canvas.jl`; the file format stores block type name, constructor params, name, position, and connections by block-name references.
- **`draw_diagram` default argument** — `draw_diagram(diagram::BlockDiagram = BlockDiagram())` so both `draw_diagram()` (empty canvas) and `draw_diagram(d)` (pre-populated) work with a single method.

---

## GUI — COMPLETE (Phases 1–11)

### What `draw_diagram()` gives you
Opening the GUI shows a 3-row window sized to 92 × 88% of the primary monitor:

| Area | Location | Purpose |
|---|---|---|
| Toolbar | row 1 (single row) | New/Save/Load + filename, ▶Run/■Stop/✕Clear, t₀/tstop/Δt fields |
| Block Library | row 2, left (236px) | Header + Menu dropdown + search box; blocks as icon chip + name |
| Canvas | row 2, right (Auto) | Dot-grid warm-white background; blocks as icon cards; blue wires |
| Status bar | row 3 (auto height) | Current action / error messages |
| Properties windows | separate OS windows | "Block Parameters — [name]" title; editable fields + Close button |
| Scope windows | separate OS windows | "∿ [title] — [name]" title; coloured lines; opened on double-click after run |

### Interactions implemented
| Action | How |
|---|---|
| Add block | Click Sources / Math / Sinks in palette → click block button → placed at canvas centre |
| Move block | Drag with left mouse; bezier wires follow live |
| Select block | Left click → blue border |
| Edit params | Double-click block → floating Properties window opens; **Ctrl+double-click** for ScopeBlock |
| Rename block | Edit "Name" field in Properties window → canvas label updates live |
| Draw connection | Click output port (red) → click input port (blue) |
| Delete connection | Click wire → highlights orange → press Delete |
| Cancel wire | Escape |
| Delete block | Select → Delete key; removes block + all its connections |
| Run simulation | Click ▶ Run; last result stored, status bar prompts scope double-click |
| View scope signals | Double-click a ScopeBlock → dedicated plot window opens (no duplicates) |
| Change tspan/dt | Edit toolbar textboxes before running |
| Clear diagram | Click Clear button; closes all scope + properties windows |
| Zoom / pan canvas | Scroll to zoom (or toolbar − / + buttons; % label tracks); double-click empty area to reset view |
| Scroll block library | Mouse wheel over the palette when it overflows (⇕ hint row shows the window) |
| Save diagram | Toolbar: type filename in textbox (press Enter) → click Save |
| Load diagram | Toolbar: type filename → click Load (clears canvas first) |
| New diagram | Toolbar: click New (clears canvas) |

---

## Known bugs / open issues

### Save/load restores blocks with wrong parameters — **OPEN**
`save_diagram` serializes block constructor params and `_reconstruct_block` rebuilds blocks from JSON. However, certain blocks (confirmed: `IntegratorBlock`) are reconstructed with wrong parameter values — e.g. `x0` is not preserved correctly. This means loading a saved diagram and running it may produce different results than before saving.
- Root cause: likely `_reconstruct_block` in `canvas.jl` either reads the wrong JSON field name or maps params to the constructor in the wrong order for some block types.
- Fix needed: audit every block's `params` dict in `save_diagram` and the corresponding `_reconstruct_block` branch; add a round-trip test (`test_io.jl`) that verifies each block type restores with identical field values.
- **While in there:** change the default save location so `.json` diagram files land in a dedicated folder (e.g. `diagrams/`) instead of the repo root, and add that folder to `.gitignore` (the stray root-level `diagram.json` currently shows up as untracked in git).
- Affects: thesis demo if the user saves and reloads a diagram with non-default ICs.

### Dot grid only covers the default view — **OPEN**
- Symptom: zooming out (or panning far) reveals bare canvas — the dots exist only over the initially visible surface.
- Root cause: the grid is a single static `scatter!` built once over `_CANVAS_XLIM × _CANVAS_YLIM` at 0.5 spacing (`draw_diagram`, ~line 1147); nothing regenerates it when the view changes.
- Fix directions (pick one):
  1. **Reactive grid (preferred)** — derive the dot positions from `ax.finallimits` via `@lift`: snap the visible range to the 0.5-unit lattice and emit only the dots inside the current view (plus a margin). Constant dot count regardless of zoom; grid appears infinite. Optionally scale spacing up (0.5 → 1.0 → 2.0) when zoomed far out so the dot count stays bounded.
  2. Cheap stopgap — statically generate dots over, say, 5× the default extents. Still finite, wastes vertices.

### Camera resets to default view when adding a block — **OPEN**
- Symptom: after panning / wheel-zooming the canvas, clicking a palette button to add a block snaps the camera back to the starting position and zoom.
- Root cause: **not** the placement logic — the palette handler already places new blocks at the current view centre (`ax.finallimits` centre, ~line 1612; user idea 2 is already implemented). The snap comes from Makie: every `plot!` into an Axis triggers `reset_limits!`, which re-applies `ax.limits` — and those are pinned to the default view by the initial `limits!(ax, _CANVAS_XLIM..., _CANVAS_YLIM...)`. Wheel-zoom/pan only change `targetlimits`, so the first plot added afterwards (block visuals, wires, Sum reconfigure...) discards them. (The toolbar − / + buttons call `limits!`, which *does* update `ax.limits` — adds after button-zoom don't snap; only after wheel-zoom/pan.)
- Fix directions:
  1. **Keep `ax.limits` in sync (preferred, smallest)** — `on(ax.finallimits) do lim; ax.limits[] = (…lim…); end` (guarded against feedback loops), or save `ax.finallimits[]` before creating visuals and `limits!`-restore it right after, in the handful of places that add plots at runtime.
  2. Drag-to-add from the palette (user idea 1) — nice UX but doesn't fix the underlying reset, which also fires when drawing a *connection* after wheel-zoom; do it as an extra, not the fix.

### AlgebraicLoopError on PID feedback loop — **INVESTIGATED, NOT A BUG (session 10, 2026-07-08)**
- Report: building a feedback loop with a PID block raised `AlgebraicLoopError`.
- Diagnosis: **correct engine behavior** when the loop contains no memory block. A PID with a P or D term has true direct feedthrough (`u = Kp·e + Ki·xi + Kd·N·(e − fd)` needs the current input `e`), so `Sum → PID → Sum` (or via only Gain/Sum-type blocks) is a genuine algebraic loop — same situation Simulink reports. Closed loops through a memory element work and are regression-tested: PID + strictly proper TF plant ✓, PID + Integrator plant ✓.
- Improvements made anyway:
  1. `has_direct_feedthrough(::PIDBlock)` refined to `!(iszero(Kp) && iszero(Kd))` — an I-only PID outputs `Ki·xi` (state only) and now legally breaks cycles like an Integrator (`math.jl`).
  2. `AlgebraicLoopError` now names the blocks in the cycle (acyclic fringe trimmed from the stalled set in `get_execution_order`) and tells the user to insert a memory block: `"algebraic loop through: PID, Sum — … Insert a memory block (Integrator, Unit Delay, or a strictly proper Transfer Fn)"` (`diagram.jl`). The GUI status bar shows this text via the existing "Run failed:" path.
- True algebraic-loop *solving* (iterative solver) remains in the post-thesis backlog.

### KeyError on click after undo/redo — **FIXED (session 10, 2026-07-08)**
- Symptom: `KeyError: key ConstantBlock(...) not found` in `_deselect!` when clicking the canvas after a mix of undo/redo edits.
- Root cause: undo/redo block-removal paths (`_apply_action!` for `AddBlockAction` backward / `DeleteBlockAction` forward) removed the block's `BlockVisual` but left `selected[]` / `selected_conn[]` pointing at it; the next `_deselect!` indexed `block_visuals[stale]`.
- Fixes (`canvas.jl`): `_drop_stale_selection!(block)` called in both block-removal undo/redo paths; `_remove_conn_visual!` clears a matching `selected_conn[]`; `_deselect!` and the Delete-key connection branch use defensive `get` lookups; undo/redo cancel an in-progress wire (its source port may be removed by the action). Regression-tested by firing the real button `clicks` observables through add/undo/redo/change/redo sequences.

### Stale port values between simulation runs — **FIXED (session 8)**
- Symptom: setting t₀ = 0.0 caused growing oscillations ("sky rocket numbers") on repeated runs; t₀ = 0.1 worked correctly.
- Root cause: non-stateful blocks (`SumBlock`, `GainBlock`, …) never had their output ports reset between runs. On re-run the propagation pass distributed stale end-of-previous-run values into cycle-breaker block inputs (e.g. `Int1` reads `Sum2.out` before `Sum2` evaluates). Stateful block `initialize!` methods also did not reset `b.base.outputs[:out].value`.
- Fix applied (`runner.jl`, `math.jl`):
  1. `runner.jl`: zero ALL output ports before `initialize!` so non-stateful blocks start clean.
  2. `runner.jl`: propagation pass after `initialize!` distributes initial values to downstream inputs.
  3. `math.jl`: `initialize!` for all 6 stateful blocks now explicitly sets `b.base.outputs[:out].value` (= `x0` for Integrator/UnitDelay, 0.0 for others).

### Palette widget squashing *(superseded)*
The old multi-entry palette (18+ rows always visible) has been replaced with group-first navigation — the default view shows only 3 category buttons, so squashing of a long list is no longer a concern.

---

## Remaining work

### Performance — **PRIORITY**

There are two distinct categories of slowness, with different root causes and fixes.

#### Category A — JIT compilation latency (first-interaction stalls)
**Symptom:** adding the first block, drawing the first connection, and opening the first properties/scope window each take several seconds, then become instant afterward.
**Root cause:** Julia compiles specialized native code the first time any generic function is called with a new argument-type combination. `poly!`, `lines!`, `scatter!`, `text!`, `Observable`, `@lift`, and the GLMakie event loop are all compiled on first use — thousands of methods in total.

**Fixes (ordered by impact / effort):**

1. ~~**`PrecompileTools.jl` workload**~~ — **DONE** (session 6)
   - `PrecompileTools` added as a direct dependency; `@compile_workload` block added at the end of `canvas.jl`.
   - Covers: full `simulate` run + all `poly!`/`lines!`/`scatter!`/`text!` patterns from `_setup_block!` and `_add_connection_visual!` with the exact Observable types they use.
   - Note: alone this was insufficient — GLMakie rendering paths (OpenGL) require a real Screen, so first-interaction stalls persisted until item 2 was also done.

2. ~~**`PackageCompiler` sysimage**~~ — **DONE** (session 6)
   - `warmup.jl` exercises 16 block types + `simulate` + `draw_diagram(d)` with a real GLMakie window (visible, closed immediately with `closeall()`).
   - `build_sysimage.jl` builds `simulite.dll` (~1.8 GB) via `PackageCompiler.create_sysimage`; took ~36 min on the dev machine.
   - `run_simulite.bat` launches with `julia --sysimage simulite.dll --project=. -e "using SimuLite; draw_diagram()"`.
   - `simulite.dll` and `simulite.so` added to `.gitignore`.
   - **Result: confirmed faster** — window open, first block, first connection, first properties window all noticeably improved.
   - Rebuild needed after: Julia version upgrade, `Pkg.update()`, or any change to SimuLite source.

3. ~~**Lazy-load `ModelingToolkit` and `DifferentialEquations`**~~ — **DONE** (session 11)
   - MTK + DiffEq moved from `[deps]` to `[weakdeps]` with an `[extensions]` entry; compiler code moved verbatim to `ext/SimuLiteCompilerExt.jl`.
   - `src/sim/compiler.jl` now holds varargs stubs for `simulate_ode`/`compile_ode` that throw a helpful "run `using ModelingToolkit, DifferentialEquations`" error; the extension's `::BlockDiagram` methods override them once both weakdeps are loaded.
   - `[compat] julia` bumped `"1"` → `"1.9"` (extensions require 1.9+).
   - Dependency closure shrank 517 → 443 packages; `using SimuLite` no longer loads MTK/DiffEq (~10 s total load on dev machine, without sysimage).
   - **Dev-workflow note:** weakdeps can't be `using`-loaded from a script whose active project is SimuLite itself — to call `simulate_ode`, work in an environment that has SimuLite (dev'd) plus ModelingToolkit + DifferentialEquations installed as regular packages.
   - Sysimage rebuild recommended (old `simulite.dll` still has MTK baked in; rebuild will be smaller/faster).

#### Category B — Runtime hot-path inefficiencies (affects simulation speed on larger diagrams)

4. ~~**Pre-build adjacency list in `runner.jl`**~~ — **DONE** (session 11)
   - `adj = IdDict{AbstractBlock, Vector{Connection}}()` built once before the time loop (IdDict matches the old `===` identity test); inner loop is `for c in get(adj, b, _NO_CONNS)` with a shared empty-vector constant so misses never allocate.
   - Hot path is now O(n_connections) per step; verified bit-identical `SimResult` on a feedback-loop diagram before/after.

5. ~~**Reduce `_bezier` allocations during drag**~~ — **DONE** (session 11; re-merged with session 10's orthogonal feedback routing)
   - Forward-curve resolution halved `n=60` → `n=30` (visually indistinguishable; `_hit_connection` tol 0.12 still well above sample spacing). Feedback wires use session 10's `_ortho_pts` right-angle routing, unchanged.
   - Forward control-point math extracted into `_bezier_ctrl` (forward-only helper); `_arrowhead` no longer samples a full curve just to use its last 2 points — forward wires get the analytic tangent (cubic bezier tangent at t=1 is along P3 − C1), feedback wires always end with a vertical rise into the port so the arrow direction is a constant (0, 1). Eliminates one `_bezier` call per connection per drag frame.
   - **Shared module-level buffers were rejected**: Makie retains the exact vectors passed through Observables into `lines!`, so a shared buffer would alias across every connection (all wires would render the last-computed curve).

6. ~~**`_zoh_discretize` caching**~~ — **DONE / confirmed** (session 11, no code change)
   - `evaluate!` for `TransferFnBlock`/`StateSpaceBlock` guards with `!(b.dt_cached ≈ dt)` — ZOH re-discretization runs only when `dt` changes, not per step; `initialize!` resets `dt_cached = -1.0` to force one recompute per run.

### Polish items (if time allows before thesis demo)
- ~~Block type label displayed inside the rectangle~~ — **done** (icon zone with type symbol)
- ~~Per-type block colors~~ — **done** (blue/amber/green by category; PID gets amber accent)
- Confirm palette squashing bug is resolved (see Known bugs above)
- Right-click context menu to delete block or wire
- Port name labels on hover
- Snap-to-grid for block positioning
- ~~Undo/redo stack~~ — **done** (Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y; covers add/delete/move block, add/delete connection)
- Rename validation (reject empty names, reject duplicate names before committing)
- **Dedicated `diagrams/` folder for saved diagrams** — Save/Load in the toolbar should read/write JSON files inside a `diagrams/` subfolder of the repo (create it on first save if missing) instead of dumping them next to the source. Add `diagrams/` to `.gitignore` so saved user diagrams never pollute the repo (the stray `diagram.json` currently sitting untracked in the root is the motivating example — delete or move it when this lands).

### GUI dependency decision (permanent)
The GUI stays on **GLMakie only** — no Gtk.jl or Cairo.jl.
GLMakie covers all needed features (canvas, events, zoom/pan, plots, text input).
The only trade-off is no native OS file dialog; the filename-in-textbox approach is adequate for thesis.

---

## Testing infrastructure *(required for Julia General Registry)*

Julia's General Registry requires a package to have a passing `test/runtests.jl` and proper `[compat]` bounds. Planned test structure:

```
test/
  runtests.jl          — @testset "SimuLite" includes all sub-suites
  test_types.jl        — Port, Connection, SimConfig, BlockDiagram,
                         SimResult, DiagramError subtypes
  test_diagram.jl      — add_block!, connect!, disconnect!,
                         remove_block!, get_execution_order,
                         error path coverage (DuplicateNameError,
                         PortNotFoundError, PortAlreadyConnectedError)
  test_blocks.jl       — constructors and field defaults for all 18 blocks,
                         evaluate! / commit_state! round-trips,
                         input_ports / output_ports counts
  test_runner.jl       — simulate() on: constant feed-forward,
                         gain chain, step response, integrator (ramp),
                         unit delay (one-step shift), PID step response
  test_compiler.jl     — simulate_ode() on integrator block (ramp),
                         compare result with runner to within tolerance
  test_io.jl           — save_diagram / load round-trip:
                         same block count, params, and connections
                         after save → new diagram → load
```

### Additional registry checklist
- `[compat]` entries for all direct deps (GLMakie, JSON3, DifferentialEquations, ModelingToolkit) — **DONE**
- Public API docstrings on `draw_diagram`, `simulate`, `simulate_ode`, all block constructors, `add_block!`, `connect!`, `disconnect!`, `remove_block!`
- Semantic versioning: bumped to `0.2.0` — **DONE**
- `LICENSE` file (MIT recommended for Julia ecosystem packages) — **DONE**
- `README.md` — DONE (install instructions, usage examples, full block catalog)

---

## Post-thesis backlog
- Algebraic loop resolution (iterative solver for pure direct-feedthrough cycles — feedback loops with memory blocks already work)
- Signal vectors / matrices (non-scalar ports)
- Subsystems (hierarchical diagrams with In/Out port blocks)
- Expose `simulate_ode` in GUI as "continuous solver" toggle
- Variable / mixed sample times (continuous + discrete in same diagram)
- Code generation (export diagram as standalone Julia ODE script)
- MIMO support for `TransferFnBlock` / `StateSpaceBlock` (currently SISO only)
- ~~Editable num/den in the Properties window~~ — **done** (session 9, `set_tf_coeffs!` + Apply/Cancel window); A/B/C/D matrix editing for `StateSpaceBlock` still open
