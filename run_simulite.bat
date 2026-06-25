@echo off
julia --sysimage "%~dp0simulite.dll" --project="%~dp0" -e "using SimuLite; draw_diagram()"
