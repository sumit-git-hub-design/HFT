# Integrating Custom Logic ("Glue") into the AVED V80 Design

> Companion to [`01-setup-and-licensing.md`](01-setup-and-licensing.md).
> Covers: how to attach custom application RTL into the AVED block design,
> and a working demo module exposing all three interface types needed.

---

## 1. Decide which interfaces you actually need

Before packaging anything, identify what your logic must talk to:

| Need | Interface type |
|---|---|
| Host reads/writes control & status registers | AXI4-Lite **slave** |
| Access to HBM / DDR memory | AXI4 **master** |
| High-throughput bulk data to/from the host | AXI4-**Stream** |

Most non-trivial applications (including HFT-style pipelines) end up needing
all three: control registers to arm/configure the logic, memory for
buffering/lookup tables, and a stream path for the actual data feed.

---

## 2. Package your RTL as a Vivado IP

1. Write your module exposing standard AXI-named ports (`s_axi_*` for
   slaves, `m_axi_*` for masters — see the demo module below for the exact
   port naming Vivado's interface auto-inference expects).
2. In Vivado: `Tools → Create and Package New IP → Package a specified
   directory`.
3. In the IP Packager, go to **Ports and Interfaces** and let Vivado
   auto-infer the AXI4-Lite / AXI4 / AXI4-Stream interfaces from your port
   names.
4. Set a VLNV, e.g. `mycompany.com:hft:custom_glue_logic:1.0`.
5. **Package IP** → **Review and Package**.
6. Point your project at the IP repo:
   ```tcl
   set_property ip_repo_paths {./my_ip_repo} [current_project]
   update_ip_catalog
   ```

---

## 3. Instantiate it in the block design

Edit `create_bd_design.tcl` (the script that builds `top.bd`) and add, after
the existing blocks (`base_logic`, `cips`, etc.) are created:

```tcl
set custom_glue [ create_bd_cell -type ip \
    -vlnv mycompany.com:hft:custom_glue_logic:1.0 custom_glue ]
```

---

## 4. Wire the control path (Host → your IP)

The AVED PCIe management crossbar (`base_logic/pcie_slr0_mgmt_sc`) already
routes master ports `M00`–`M03` to `hw_discovery`, `uuid_rom`, `gcq_m2r`, and
`clock_reset`. Add a new master port (`M04`) for your IP:

```tcl
set_property CONFIG.NUM_MI {5} [get_bd_cells base_logic/pcie_slr0_mgmt_sc]

connect_bd_intf_net [get_bd_intf_pins base_logic/pcie_slr0_mgmt_sc/M04_AXI] \
                     [get_bd_intf_pins custom_glue/s_axi_ctrl]

assign_bd_address [get_bd_addr_segs {custom_glue/s_axi_ctrl/reg0}]
```

Verify/adjust the address map afterwards in Vivado's **Address Editor**
(`Window → Address Editor`).

---

## 5. Wire the memory path (your IP → HBM/DDR)

Add a NoC slave port on the existing DDR4 controller connection
(`axi_noc_mc_ddr4_0`, or the HBM NMU if targeting HBM instead) and connect
your IP's AXI4 master:

```tcl
set_property CONFIG.NUM_SI {N+1} [get_bd_cells axi_noc_mc_ddr4_0]

connect_bd_intf_net [get_bd_intf_pins custom_glue/m_axi_mem] \
                     [get_bd_intf_pins axi_noc_mc_ddr4_0/S0X_AXI]
```

(`N+1` / `S0X` — replace with the actual next available index; check the NoC
block in the GUI for current port names before writing this in Tcl.)

Connect clock/reset from the existing PL domain:

```tcl
connect_bd_net [get_bd_pins cips/pl0_ref_clk] [get_bd_pins custom_glue/aclk]
connect_bd_net [get_bd_pins clock_reset/resetn_pl_periph] \
               [get_bd_pins custom_glue/aresetn]
```

---

## 6. Wire the bulk streaming path (host ↔ your IP, high throughput)

`gcq_m2r` is control-plane only (small messages) — **not** suitable for bulk
data. For real throughput, expose the CIPS QDMA AXI-Stream interface (present
inside `cips`, currently tied off / unused in the base design) and connect it
to your IP's stream ports:

```tcl
connect_bd_intf_net [get_bd_intf_pins cips/dma1_st_h2c] \
                     [get_bd_intf_pins custom_glue/s_axis_data]
connect_bd_intf_net [get_bd_intf_pins custom_glue/m_axis_data] \
                     [get_bd_intf_pins cips/dma1_st_c2h]
```

Exact QDMA port names depend on the CIPS IP configuration — confirm them in
the CIPS customization GUI (DMA tab) before wiring, since these are tied to
`1'b0` / unused by default in the generated design.

---

## 7. Validate, rebuild, and re-generate

```tcl
validate_bd_design
save_bd_design
generate_target all [get_files top.bd]
```

Then re-run `create_design.tcl` followed by `build_design.tcl`
(synthesis + implementation → XSA / bitstream).

---

## 8. Update firmware / host driver

The new control register space (Step 4) needs to be reflected on the
software side — update the AMC firmware (`fw/AMC`) and/or the host driver so
they know how to read/write the new address range.

---

## 9. Reference demo module

[`src/hft_custom_glue_logic.v`](../src/hft_custom_glue_logic.v) is a working
skeleton implementing all three interfaces described above:

- **AXI4-Lite slave** (`s_axi_ctrl_*`) — a 7-register control/status bank
  (`CTRL`, `STATUS`, `MEM_ADDR_LO/HI`, `MEM_WDATA`, `MEM_RDATA`,
  `PKT_COUNT`).
- **AXI4 master** (`m_axi_mem_*`) — a minimal single-beat (burst-of-1)
  read/write state machine triggered by the `CTRL` register. Intended as a
  correctness-first skeleton; extend to bursts for real throughput.
- **AXI4-Stream** (`s_axis_data_*` / `m_axis_data_*`) — currently a
  combinational pass-through that increments `PKT_COUNT` on every completed
  packet (`tlast`). **This is where real packet-processing / HFT logic
  should be inserted**, replacing the pass-through assignment.

### Register map

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | `CTRL` | RW | bit0 = start mem write, bit1 = start mem read (self-clearing) |
| `0x04` | `STATUS` | RO | bit0 = busy, bit1 = done |
| `0x08` | `MEM_ADDR_LO` | RW | target address [31:0] |
| `0x0C` | `MEM_ADDR_HI` | RW | target address [63:32] |
| `0x10` | `MEM_WDATA` | RW | data to write |
| `0x14` | `MEM_RDATA` | RO | last data read |
| `0x18` | `PKT_COUNT` | RO | AXI-Stream packets passed through |

### Next steps for this module

- [ ] Replace the AXI4-Stream pass-through with real processing logic
- [ ] Extend the AXI4 master FSM from single-beat to burst transfers
- [ ] Package as a Vivado IP (`Tools → Create and Package New IP`)
- [ ] Wire into `top.bd` per Steps 3–6 above
- [ ] Write a simulation testbench before synthesizing on hardware
