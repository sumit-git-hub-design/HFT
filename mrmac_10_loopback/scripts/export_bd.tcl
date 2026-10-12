# ---------------------------------------------------------------------------
# export_bd.tcl
# Run INSIDE your open Vivado project (Tcl console) whenever the block design
# (MRMAC + GT Quad) changes:
#
#     source <repo>/scripts/export_bd.tcl
#
# It writes bd/design_1.tcl, a text file that recreates the whole block design
# including the MRMAC and GT Quad IP settings. Commit that file.
# ---------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set bd_name    design_1

open_bd_design [get_files ${bd_name}.bd]
write_bd_tcl -force [file join $repo_dir bd ${bd_name}.tcl]
puts "Exported block design to [file join $repo_dir bd ${bd_name}.tcl]"
