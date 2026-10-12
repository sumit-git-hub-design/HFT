# ---------------------------------------------------------------------------
# create_project.tcl
# Re-creates the Vivado project from the files in this repo.
#
#   vivado -mode batch -source scripts/create_project.tcl
#   (or, in the Vivado Tcl console:  source scripts/create_project.tcl)
#
# TEMPLATE: not run inside Vivado by the author of this file. Fill in the
# values marked <<< EDIT >>> and test once on a clean checkout.
# Tested-with Vivado version: 2025.1 (taken from the generated wrapper header)
# ---------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]

set proj_name  own_mrmac
set proj_dir   [file join $repo_dir build $proj_name]
set bd_name    design_1
set top_tb     tb_mrmac_loopback

# <<< EDIT >>> exact part from your project: Tcl console -> get_property PART [current_project]
set part       "xcvc1902-vsva2197-2MP-e-S"
# <<< EDIT >>> only if you used a board in the project, uncomment and fill
# set board_part "<BOARD_PART>"

create_project -force $proj_name $proj_dir -part $part
# if {[info exists board_part]} { set_property board_part $board_part [current_project] }

# ---- RTL ----
set rtl_files [concat [glob -nocomplain [file join $repo_dir rtl *.v]] \
                      [glob -nocomplain [file join $repo_dir rtl *.sv]]]
if {[llength $rtl_files] > 0} { add_files -norecurse $rtl_files }

# ---- Constraints (GT refclk / MRMAC site / pin LOCs) ----
set xdc_files [glob -nocomplain [file join $repo_dir constraints *.xdc]]
if {[llength $xdc_files] > 0} { add_files -fileset constrs_1 -norecurse $xdc_files }

# ---- Block design (MRMAC + GT Quad), rebuilt from the exported Tcl ----
source [file join $repo_dir bd ${bd_name}.tcl]

# ---- Wrapper ----
set wrapper [make_wrapper -files [get_files ${bd_name}.bd] -top]
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [get_filesets sources_1]

# ---- Generate IP / BD output products (needed for simulation) ----
generate_target all [get_files ${bd_name}.bd]

# ---- Simulation ----
add_files -fileset sim_1 -norecurse [file join $repo_dir sim ${top_tb}.v]
set_property top $top_tb [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Project created in $proj_dir"
