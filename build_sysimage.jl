# build_sysimage.jl — builds a Julia sysimage for SimuLite
#
# Run once on the target machine (takes ~20–40 minutes):
#
#   julia --startup-file=no build_sysimage.jl
#
# Then launch the app with the generated sysimage:
#
#   julia --sysimage simulite.dll -e "using SimuLite; draw_diagram()"
# or just double-click run_simulite.bat
#
# The sysimage is machine-specific. Rebuild after any package updates.

using PackageCompiler

@info "Building SimuLite sysimage — this takes 20–40 minutes, please wait..."

t0 = time()

create_sysimage(
    ["SimuLite"],
    sysimage_path     = joinpath(@__DIR__, "simulite.dll"),
    precompile_execution_file = joinpath(@__DIR__, "warmup.jl"),
    project           = @__DIR__,
)

elapsed = round(time() - t0; digits=1)
@info "Done! Sysimage written to simulite.dll in $(elapsed)s."
@info "Launch with: julia --sysimage simulite.dll -e \"using SimuLite; draw_diagram()\""
@info "Or just run: run_simulite.bat"
