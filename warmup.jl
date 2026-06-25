# warmup.jl — PackageCompiler precompile execution file
#
# This script is run once during sysimage creation to trace every method that
# SimuLite uses at runtime. Anything compiled here is frozen into the sysimage
# so the user never pays JIT cost for it again.
#
# Run via build_sysimage.jl, not directly.

using SimuLite
import GLMakie

# ── 1. Simulation engine ──────────────────────────────────────────────────────
# Cover many block types, connect them, and run the fixed-step runner.

d = BlockDiagram()
d.config = SimConfig((0.0, 2.0), 0.01)

src   = ConstantBlock(1.0;       name="src",   position=( 0.0,  3.0))
step  = StepBlock(;              name="step",  position=( 0.0,  1.5))
sine  = SineBlock(;              name="sine",  position=( 0.0,  0.0))
ramp  = RampBlock(;              name="ramp",  position=( 0.0, -1.5))
clk   = ClockBlock(;             name="clk",   position=( 0.0, -3.0))
gain  = GainBlock(2.0;           name="gain",  position=( 3.0,  3.0))
integ = IntegratorBlock(0.0;     name="integ", position=( 3.0,  1.5))
delay = UnitDelayBlock(0.0;      name="delay", position=( 3.0,  0.0))
sat   = SaturationBlock(;        name="sat",   position=( 3.0, -1.5))
abss  = AbsBlock(;               name="abs",   position=( 3.0, -3.0))
sumblk = SumBlock("+-";          name="sum",   position=( 6.0,  2.0))
pid   = PIDBlock(;               name="pid",   position=( 6.0,  0.0))
deriv = DerivativeBlock(;        name="deriv", position=( 6.0, -2.0))
scope = ScopeBlock(; n_ports=2,  name="scope", position=( 9.0,  1.0))
ws    = WorkspaceBlock(;         name="ws",    position=( 9.0, -1.0))
term  = TerminatorBlock(;        name="term",  position=( 9.0, -3.0))

for b in [src, step, sine, ramp, clk,
          gain, integ, delay, sat, abss,
          sumblk, pid, deriv,
          scope, ws, term]
    add_block!(d, b)
end

connect!(d, src,   :out,  gain,   :in)
connect!(d, step,  :out,  integ,  :in)
connect!(d, sine,  :out,  delay,  :in)
connect!(d, ramp,  :out,  sat,    :in)
connect!(d, clk,   :out,  abss,   :in)
connect!(d, gain,  :out,  sumblk, :in1)
connect!(d, integ, :out,  sumblk, :in2)
connect!(d, sumblk,:out,  pid,    :in)
connect!(d, delay, :out,  deriv,  :in)
connect!(d, pid,   :out,  scope,  :in1)
connect!(d, sat,   :out,  scope,  :in2)
connect!(d, abss,  :out,  ws,     :in)
connect!(d, deriv, :out,  term,   :in)

simulate(d)

# ── 2. GUI warm-up ────────────────────────────────────────────────────────────
# Open draw_diagram with the pre-populated diagram and a hidden GLMakie screen.
# This triggers _setup_block! for every block type and _add_connection_visual!
# for every connection, compiling all Makie scene-graph and OpenGL paths.

try
    fig = draw_diagram(d)
    GLMakie.closeall()
catch e
    @warn "GUI warmup failed (sysimage will still benefit non-GUI paths): $e"
end
