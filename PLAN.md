# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-26 — session 7)

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
| `SumBlock` | math | `SumBlock("+-")` | Configurable signs per input port |
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
- No algebraic loop solving — pure direct-feedthrough cycles (e.g. Gain→Sum→Gain) throw `AlgebraicLoopError`; feedback loops containing a memory block work correctly
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
    compiler.jl             — ODE compiler via ModelingToolkit
    runner.jl               — fixed-step simulation loop
  gui/
    canvas.jl               — full GUI: canvas, palette (Menu+search),
                              floating properties/scope windows,
                              single-row toolbar (New/Save/Load,
                              Run/Clear, t₀/tstop/Δt),
                              save/load (draw_diagram)
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
- **Reactive block height** — `_block_height(block)` is wrapped in `Observable{Float64}` per block (`block_heights` dict); all geometry and port-position `@lift`s reference `$bh_obs` so the block resizes live when port count changes.
- **Single palette entry + reconfigurable ports** — `SumBlock` and `ScopeBlock` have one palette button each (default `"++"` / 1 port). Double-clicking their Properties window reconfigures port count on the fly: `_reconfigure_inputs!` tears down old port Observables/scatter plots and connection visuals for removed ports, rebuilds `block.base.inputs`, updates `bh_obs`, and recreates surviving connection visuals against the new port Observables. `ScopeBlock` properties are accessed via **Ctrl+double-click** (plain double-click opens the scope result window).
- **Block Library group-first navigation** — default ("All") view shows three category buttons (Sources / Math / Sinks); clicking one drills into that category. Category dropdown and search still work normally for direct access.
- **Blue wires** — connections drawn in `_WIRE_COLOR = RGBf(0.19, 0.43, 0.69)` (linewidth 1.8); turn orange `_ORA_COLOR` on selection, restored on deselect.
- **Backward bezier routing** — `_bezier` detects feedback wires (`x1 < x0 - 0.1`) and routes them as a downward arc (`drop = max(spread × 0.4, 1.2)`) that clears the block layout, instead of cutting through blocks. Forward wires use the original S-curve.
- **Dot grid canvas** — 825 scatter dots at 0.5-unit spacing on warm-white background `RGBf(0.98, 0.98, 0.97)`; dots zoom with the canvas naturally.
- **Single-row toolbar** (Section 5 wireframe style) — `New | Save | Load [filename]` for file ops, `▶ Run | ■ Stop | ✕ Clear` for simulation, `t₀ [txt] tstop [txt] Δt [txt]` for timing. No separate menubar strip. File tab removed from palette.
- **Block Library panel** (2-column layout, 236px total — Section 5 wireframe):
  - Row 1: "Block Library" bold header (span 1:2)
  - Row 2: `Menu` dropdown (All / Sources / Math / Sinks, span 1:2)
  - Row 3: search `Textbox` (span 1:2)
  - Rows 4+: icon chip (col 1, 28px) + name button (col 2)
  - `next_content_row` Ref (starts at 4, reset on `clear_pal!`) tracks next row
  - `on(cat_menu.selection)` + `on(search_obs)` → `_build_pal!(cat, txt)` filters and rebuilds from combined 4-tuple `(sym, color, label, factory)` lists
- **Dynamic block height** — `_block_height(block)` scales height as `max(BLOCK_H, PORT_HIT × 1.4 × (n_ports + 1))` so port hit-circles never overlap on multi-port blocks (e.g. Scope ×3).
- **Floating properties windows** — double-clicking any non-Scope block opens a dedicated `GLMakie.Screen` (320×400 px) with editable fields and a **Close** button; title: `"Block Parameters — [name]"`; tracked per-block in `prop_screens` dict; replaced on re-open. `_clear_all!` closes all prop windows.
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
| Zoom / pan canvas | Scroll to zoom; double-click empty area to reset view |
| Save diagram | Toolbar: type filename in textbox (press Enter) → click Save |
| Load diagram | Toolbar: type filename → click Load (clears canvas first) |
| New diagram | Toolbar: click New (clears canvas) |

---

## Known bugs / open issues

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

3. **Lazy-load `ModelingToolkit` and `DifferentialEquations`** *(medium impact, medium effort)*
   - These packages add ~10–20 s to `using SimuLite` alone.
   - Move `compiler.jl` (the MTK ODE path) behind a Julia 1.9+ package extension (`ext/SimuLiteCompilerExt.jl`), loaded only when the user does `using ModelingToolkit`.
   - `simulate_ode` can remain in the public API but throw a helpful error if the extension is not loaded.
   - Result: normal GUI startup drops by ~10–20 s; only users who call `simulate_ode` pay that cost.

#### Category B — Runtime hot-path inefficiencies (affects simulation speed on larger diagrams)

4. **Pre-build adjacency list in `runner.jl`** *(medium impact, low effort)*
   - The inner loop `for c in diagram.connections` runs once per block per timestep — O(n_blocks × n_connections) per step.
   - Fix: before the time loop, build `adj = Dict{AbstractBlock, Vector{Connection}}()` keyed by source block. Inner loop becomes `for c in get(adj, b, [])`.
   - Makes the hot path O(n_connections) per step instead of O(n_blocks × n_connections).

5. **Reduce `_bezier` allocations during drag** *(low impact, low effort)*
   - `_bezier` allocates two `Vector{Float64}(undef, 60)` every frame for every visible connection when any block is dragged.
   - Fix: reduce the curve resolution from `n=60` to `n=30` (visually indistinguishable at these scales), and/or pre-allocate shared buffers using a module-level `const _BEZ_XS = Vector{Float64}(undef, 30)`.
   - Alternatively: skip redrawing connections that are off-screen.

6. **`_zoh_discretize` caching** *(low impact in practice)*
   - Already partially addressed via `dt_cached` fields on `TransferFnBlock`/`StateSpaceBlock`.
   - Confirm the `dt_cached == dt` guard prevents re-discretization on every `evaluate!` call.

### Polish items (if time allows before thesis demo)
- ~~Block type label displayed inside the rectangle~~ — **done** (icon zone with type symbol)
- ~~Per-type block colors~~ — **done** (blue/amber/green by category; PID gets amber accent)
- Confirm palette squashing bug is resolved (see Known bugs above)
- Right-click context menu to delete block or wire
- Port name labels on hover
- Snap-to-grid for block positioning
- Undo/redo stack
- Rename validation (reject empty names, reject duplicate names before committing)

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
- Editable num/den and A/B/C/D matrices in the Properties window for the new blocks
