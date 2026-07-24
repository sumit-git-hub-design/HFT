# AVED V80 Setup, Licensing, and Design Exploration — A Practical Log

> Environment: Vivado 2025.1 (win64), AMD Alveo V80 (Versal), Windows 10/11 64-bit
> Repo used: [Xilinx/AVED](https://github.com/Xilinx/AVED)

This document walks through the real issues encountered while bringing up the
AVED (Alveo Versal Example Design) project from a fresh `git clone`, resolving
the SMBus IP licensing chain, and understanding where custom application logic
("glue") is meant to attach in the AVED architecture — contrasted with the
Cisco FDK-style `user_application` wrapper some readers may be used to.

---

## 1. The initial build error

Running the design creation script out of the box produced:

```
ERROR: [BD::TCL 103-2012] The following IPs are not found in the IP Catalog:
  xilinx.com:ip:smbus:*
Resolution: Please add the repository containing the IP(s) to the project.
WARNING: [BD::TCL 103-2023] Will not continue with creation of design due to the error(s) above.
invalid command name "create_root_design"
```

**Root cause:** The `smbus_v1_1` IP is *not* bundled in the AVED git repo. It's
gated behind a separate AMD licensing/NDA process due to third-party licensing
terms on the SMBus IP core.

### Fix — high level steps

1. Register on AMD's licensing portal ("the lounge") and accept the NDA for
   the AVED SMBus IP.
2. Download `smbus_v1_1-20240328.zip` (v1.1, compatible with Vivado 2025.1).
3. Extract it into the repo at:
   ```
   hw\amd_v80_gen5x8_24.1\src\iprepo\smbus_v1_1
   ```
   so it sits alongside the other pre-supplied IP folders (`cmd_queue_v2_0`,
   `hw_discovery_v1_0`, `shell_utils_uuid_rom_v2_0`, etc.).
4. Generate a **license** for the IP at `xilinx.com/getlicense` (registration
   ≠ license — both steps are required). This requires:
   - An **Alveo V80 Accelerator Card Early Access** entitlement (appears
     automatically once the lounge NDA is accepted).
   - A **Host ID** to node-lock the license to your machine (see below).
5. Install the resulting `.lic` file via Vivado's `Manage Xilinx Licenses`
   tool → **Load License** → **Copy License…** → select the `.lic` file.
6. Re-run `create_design.tcl`. The SMBus IP now resolves from the IP catalog.

### Finding your Host ID on Windows

```
ipconfig /all
```

Look for **Physical Address** under your *active* adapter (the one currently
carrying an IP address — Wi-Fi or Ethernet). Use that MAC address
(e.g. `64BC588D5F6D`, no dashes) as the Host ID when generating the license.
Prefer a wired/Ethernet adapter if your setup is a stable lab machine, since
Wi-Fi hardware may change more often and would invalidate a node-locked
license.

### Note on license terminology

- **"Full"** vs **"Evaluation"** describes license *completeness*
  (permanent + full functionality vs a time-limited trial).
- **"No Charge"** vs a priced tier describes license *cost*.

Both the SMBus IP license and the "Vivado Alveo Edition" seat obtained through
this flow are free — the different wording just reflects two different axes
of the license record, not that one costs money and the other doesn't.

---

## 2. Understanding `create_design.tcl` vs `build_design.tcl`

| Script | Role |
|---|---|
| `create_design.tcl` | Builds the **project + Block Design (BD)**: instantiates IP (CIPS, Base Logic, Clocks & Resets, SMBus, GCQ, Hardware Discovery, UUID ROM), wires them together. Output: a complete `.bd`. This is where the `create_root_design` procedure lives — and where the SMBus error above originates. |
| `build_design.tcl` | Takes the finished BD and runs **synthesis + implementation**, producing the **XSA** (hardware handoff for firmware) and ultimately the bitstream/PDI. |

Analogy: `create_design.tcl` is the architect's blueprint; `build_design.tcl`
is the actual construction. If you need to attach custom RTL, you edit
`create_design.tcl` (or the `create_bd_design.tcl` it calls) — not
`build_design.tcl`.

---

## 3. What's actually inside the generated design (verified from netlist)

After a successful build, the generated `top.v` / `top_wrapper.v` netlist
shows the **real** top-level hierarchy is only:

```
top
 ├── axi_noc_cips        (NoC configuration / CIPS-side AXI routing)
 ├── axi_noc_mc_ddr4_0    (DDR4 channel 0 memory controller via NoC)
 ├── axi_noc_mc_ddr4_1    (DDR4 channel 1 memory controller via NoC)
 ├── base_logic           (see breakdown below)
 ├── cips                 (Control, Interfaces, and Processing System)
 └── clock_reset          (clocking + reset generation)
```

And inside `base_logic`:

```
base_logic
 ├── axi_smbus_rpu   — SMBus IP instance, connects RPU to the SMBus (card mgmt)
 ├── gcq_m2r         — Generic Command Queue (the host↔RPU "mailbox")
 ├── hw_discovery    — Populates PCIe extended capabilities / UUID metadata
 ├── pcie_slr0_mgmt_sc — AXI crossbar routing PCIe-side masters
 ├── rpu_sc          — AXI crossbar routing RPU-side masters
 └── uuid_rom        — Stores a per-build design UUID
```

**Important finding:** there is **no `xbtest` placeholder IP and no
"User Application" hierarchy block** in this generated design. Some AI
assistants and older AVED docs (referring to the `exdes_1` / 2023.1-era
release) describe an `xbtest` demonstration application that acts as a
replaceable placeholder — that is a *separate, optional example design*, not
part of the default `create_design.tcl` flow used to generate this project
(24.1/25.1-era AVED). Similarly, "OpenNIC" is a distinct AMD repo/project, not
a component of AVED itself. Treat any guidance describing `xbtest` as a ready
replaceable slot with caution unless you've explicitly built that variant.

---

## 4. Where the "exchange" data flows (Host ↔ Card)

Per AVED's *Host to Card Communication* documentation, and confirmed in the
netlist:

```
Host (PCIe) → PCIe BAR (PF0 memory aperture)
            → gcq_m2r (mailbox: submission + completion circular buffers)
            → RPU firmware (AMC) polls / is interrupted, processes command
            → result pushed back on the completion queue
```

- `gcq_m2r` is strictly a **control-plane** mailbox (small messages, AXI-Lite
  style) — not a bulk data-streaming path.
- For your own **user-space data**, AVED explicitly leaves this open-ended:
  extend the design with an additional PCIe Physical Function, an extra GCQ
  mailbox instance for the user app, or use **Versal's PCIe Slave Bridge** /
  the CPM DMA engine (exposed on PF1) for direct host-memory access.

---

## 5. MRMAC / networking

The base AVED design (as generated here) is **PCIe-only** — there is no
MRMAC (Multi-Rate MAC, Versal's hardened Ethernet block) instantiated, and no
active QSFP/GT logic. If your application needs Ethernet/QSFP connectivity,
you must add and wire the MRMAC hard IP and enable the relevant GT
transceivers yourself; they are not present in the default build.

---

## 6. Where to attach custom logic ("glue"), and how this differs from Cisco's FDK

Cisco's FDK model provides:
- A pre-built `user_application` top-level wrapper.
- Ready-made streaming ports: `rx_net`/`tx_net` (network) and
  `rx_host`/`tx_host` (host DMA) — plug custom logic straight in.

AVED does **not** provide an equivalent ready-made streaming abstraction. It
is a lower-level reference design exposing raw building blocks (NoC, CPM
PCIe, DMA engines) rather than a pre-wired data-plane. Concretely, to attach
custom logic:

1. **Package your RTL as a Vivado IP** (`Tools → Create and Package New IP`),
   exposing:
   - An AXI4-Lite slave (control/register access)
   - An AXI4 master (for NoC / HBM / DDR access), if needed
   - An AXI-Stream interface, if you need high-throughput data
2. **Add the IP into the Block Design** (`create_bd_design.tcl` / `top.bd`).
3. **Connect it in two places:**
   - To `axi_noc_cips` (or the DDR/HBM NoC entry points) for memory access.
   - To `pcie_slr0_mgmt_sc` (add a new master port, e.g. `M04_AXI`) for
     host-side control, the same way `gcq_m2r` and `hw_discovery` are already
     wired in.
4. **For bulk host↔card data throughput** (equivalent to Cisco's
   `rx_host`/`tx_host`), don't reuse `gcq_m2r` — instead expose and wire the
   CPM's **QDMA** AXI-Stream interface (already present inside the `cips`
   block in the netlist) to your custom logic.
5. **For network-bound applications** (equivalent to Cisco's
   `rx_net`/`tx_net`), you'll need to instantiate MRMAC and enable the GT/QSFP
   transceivers yourself, since none of this exists in the base design.

---

## Summary Checklist

- [ ] SMBus IP downloaded, extracted to `iprepo/smbus_v1_1`, and licensed
- [ ] License loaded via Vivado License Manager
- [ ] `create_design.tcl` runs clean (BD builds without IP-catalog errors)
- [ ] `build_design.tcl` run for synthesis/implementation → XSA generated
- [ ] Verified actual generated hierarchy (no `xbtest`/User App present)
- [ ] Custom IP packaged and added to `top.bd`
- [ ] Control path wired via `pcie_slr0_mgmt_sc` (new AXI-Lite master port)
- [ ] Memory path wired via `axi_noc_cips` / DDR-HBM NoC entry points
- [ ] (If needed) QDMA AXI-Stream exposed for host bulk data
- [ ] (If needed) MRMAC + QSFP GTs instantiated for networking
