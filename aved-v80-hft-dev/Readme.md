AVED V80 HFT Dev

Development notes, licensing walkthrough, and custom-logic integration guide for building HFT (High-Frequency Trading) applications on the AMD Alveo V80 card using AMD's AVED (Alveo Versal Example Design) reference project.

Environment
 
 -> Vivado 2025.1 (win64)
 
 -> AMD Alveo V80 (Versal HBM)
 
 -> Windows 10/11 64-bit

Contents

-> docs/01-setup-and-licensing.md — End-to-end walkthrough: fixing the xilinx.com:ip:smbus IP-catalog error, the AMD lounge/NDA + licensing flow, create_design.tcl vs build_design.tcl, the verified real design hierarchy (no xbtest/User Application block in this AVED build), the host↔card data path via GCQ, and where to attach custom RTL for control/memory/streaming.
Status


Work in progress — this repo tracks an ongoing HFT-on-V80 development effort. Expect frequent restructuring as the custom logic (src/) and build scripts (scripts/) are added.


License


Add your chosen license here (e.g. MIT, Apache-2.0) — note that AMD's SMBus IP itself remains under AMD's own licensing terms and should not be committed to this repo; only reference how to obtain it (see docs).
