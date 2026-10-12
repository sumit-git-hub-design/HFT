# MRMAC 10GE loopback (Versal)

10GE, static, Low Latency, 32-bit non-segmented AXI4-Stream, MRMAC + GT Quad.
Vivado 2025.1.

## Layout
| Path | Content |
|---|---|
| `bd/design_1.tcl` | Exported block design (MRMAC + GT Quad + all IP settings) |
| `rtl/` | HDL (if any) |
| `constraints/` | `.xdc` files |
| `sim/tb_mrmac_loopback.v` | Loopback testbench |
| `scripts/create_project.tcl` | Re-creates the Vivado project |
| `scripts/export_bd.tcl` | Re-exports the block design after changes |

## Re-create and simulate
    vivado -mode batch -source scripts/create_project.tcl
    vivado build/own_mrmac/own_mrmac.xpr
    # Flow Navigator -> Run Simulation -> Run Behavioral Simulation
    # expect "*** TEST PASSED ***"

## After changing the block design / IP settings
In the Vivado Tcl console (project open):

    source scripts/export_bd.tcl

then `git add bd/design_1.tcl && git commit`.

