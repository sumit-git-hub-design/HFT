// =============================================================================
// Module      : hft_custom_glue_logic
// Description : Demo "glue logic" wrapper exposing the three interfaces
//               needed to integrate custom application logic into the AVED
//               (Alveo Versal Example Design) block design:
//
//                 1) AXI4-Lite SLAVE  (s_axi_ctrl)  - host control/status regs
//                 2) AXI4      MASTER (m_axi_mem)   - HBM/DDR memory access
//                 3) AXI4-Stream       (s_axis_data / m_axis_data) - bulk
//                                                     host<->card streaming
//                                                     (e.g. via QDMA H2C/C2H)
//
// Status      : Functional skeleton / reference. The AXI4 master here does
//               single-beat (burst-of-1) transactions only, and the stream
//               path is a pass-through with a packet counter. Replace the
//               marked sections with real HFT processing logic.
//
// Register Map (AXI4-Lite, byte addressed, 32-bit registers)
//   0x00  CTRL        [0] mem_wr_start  [1] mem_rd_start   (self-clearing)
//   0x04  STATUS      [0] mem_busy      [1] mem_done       (RO)
//   0x08  MEM_ADDR_LO  target address bits [31:0]
//   0x0C  MEM_ADDR_HI  target address bits [63:32]
//   0x10  MEM_WDATA    data to write (low 32 bits of the write beat)
//   0x14  MEM_RDATA    data last read (low 32 bits of the read beat) (RO)
//   0x18  PKT_COUNT    AXI-Stream packets passed through so far (RO)
// =============================================================================

`timescale 1ns / 1ps

module hft_custom_glue_logic #(
    parameter C_S_AXI_ADDR_WIDTH = 12,
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_M_AXI_ADDR_WIDTH = 64,
    parameter C_M_AXI_DATA_WIDTH = 512,
    parameter C_AXIS_DATA_WIDTH  = 512
)(
    input  wire                              aclk,
    input  wire                              aresetn,

    // -------------------------------------------------------------------
    // AXI4-Lite SLAVE : control / status register access from the host
    // Connect to: base_logic/pcie_slr0_mgmt_sc (new master port, e.g. M04)
    // -------------------------------------------------------------------
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_ctrl_awaddr,
    input  wire                              s_axi_ctrl_awvalid,
    output reg                               s_axi_ctrl_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_ctrl_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_ctrl_wstrb,
    input  wire                              s_axi_ctrl_wvalid,
    output reg                               s_axi_ctrl_wready,
    output reg  [1:0]                        s_axi_ctrl_bresp,
    output reg                               s_axi_ctrl_bvalid,
    input  wire                              s_axi_ctrl_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_ctrl_araddr,
    input  wire                              s_axi_ctrl_arvalid,
    output reg                               s_axi_ctrl_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_ctrl_rdata,
    output reg  [1:0]                        s_axi_ctrl_rresp,
    output reg                               s_axi_ctrl_rvalid,
    input  wire                              s_axi_ctrl_rready,

    // -------------------------------------------------------------------
    // AXI4 MASTER : HBM / DDR memory access
    // Connect to: axi_noc_cips / axi_noc_mc_ddr4_0 (new NoC slave port)
    // -------------------------------------------------------------------
    output reg  [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_mem_awaddr,
    output reg  [7:0]                        m_axi_mem_awlen,
    output reg  [2:0]                        m_axi_mem_awsize,
    output reg  [1:0]                        m_axi_mem_awburst,
    output reg                               m_axi_mem_awvalid,
    input  wire                              m_axi_mem_awready,
    output reg  [C_M_AXI_DATA_WIDTH-1:0]     m_axi_mem_wdata,
    output reg  [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_mem_wstrb,
    output reg                               m_axi_mem_wlast,
    output reg                               m_axi_mem_wvalid,
    input  wire                              m_axi_mem_wready,
    input  wire [1:0]                        m_axi_mem_bresp,
    input  wire                              m_axi_mem_bvalid,
    output reg                               m_axi_mem_bready,
    output reg  [C_M_AXI_ADDR_WIDTH-1:0]     m_axi_mem_araddr,
    output reg  [7:0]                        m_axi_mem_arlen,
    output reg  [2:0]                        m_axi_mem_arsize,
    output reg  [1:0]                        m_axi_mem_arburst,
    output reg                               m_axi_mem_arvalid,
    input  wire                              m_axi_mem_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]     m_axi_mem_rdata,
    input  wire [1:0]                        m_axi_mem_rresp,
    input  wire                              m_axi_mem_rlast,
    input  wire                              m_axi_mem_rvalid,
    output reg                               m_axi_mem_rready,

    // -------------------------------------------------------------------
    // AXI4-Stream SLAVE : bulk data arriving from the host (H2C / RX)
    // Connect to: cips QDMA H2C stream (dma1_st_h2c or equivalent)
    // -------------------------------------------------------------------
    input  wire [C_AXIS_DATA_WIDTH-1:0]      s_axis_data_tdata,
    input  wire [(C_AXIS_DATA_WIDTH/8)-1:0]  s_axis_data_tkeep,
    input  wire                              s_axis_data_tlast,
    input  wire                              s_axis_data_tvalid,
    output reg                               s_axis_data_tready,

    // -------------------------------------------------------------------
    // AXI4-Stream MASTER : bulk data going to the host (C2H / TX)
    // Connect to: cips QDMA C2H stream (dma1_st_c2h or equivalent)
    // -------------------------------------------------------------------
    output reg  [C_AXIS_DATA_WIDTH-1:0]      m_axis_data_tdata,
    output reg  [(C_AXIS_DATA_WIDTH/8)-1:0]  m_axis_data_tkeep,
    output reg                               m_axis_data_tlast,
    output reg                               m_axis_data_tvalid,
    input  wire                              m_axis_data_tready
);

    // =========================================================================
    // 1. AXI4-LITE SLAVE — CONTROL / STATUS REGISTERS
    // =========================================================================
    localparam ADDR_CTRL      = 12'h000;
    localparam ADDR_STATUS    = 12'h004;
    localparam ADDR_MEM_ADDR_LO = 12'h008;
    localparam ADDR_MEM_ADDR_HI = 12'h00C;
    localparam ADDR_MEM_WDATA = 12'h010;
    localparam ADDR_MEM_RDATA = 12'h014;
    localparam ADDR_PKT_COUNT = 12'h018;

    reg [31:0] reg_ctrl;
    reg [31:0] reg_status;
    reg [31:0] reg_mem_addr_lo;
    reg [31:0] reg_mem_addr_hi;
    reg [31:0] reg_mem_wdata;
    reg [31:0] reg_mem_rdata;
    reg [31:0] reg_pkt_count;

    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr_latched;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr_latched;

    wire mem_wr_start_pulse;
    wire mem_rd_start_pulse;
    reg  mem_wr_start_q, mem_rd_start_q;

    // ---- Write channel FSM ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_ctrl_awready <= 1'b0;
            s_axi_ctrl_wready  <= 1'b0;
            s_axi_ctrl_bvalid  <= 1'b0;
            s_axi_ctrl_bresp   <= 2'b00;
            reg_ctrl           <= 32'h0;
            reg_mem_addr_lo    <= 32'h0;
            reg_mem_addr_hi    <= 32'h0;
            reg_mem_wdata      <= 32'h0;
        end else begin
            // CTRL is self-clearing: the start bits pulse for one cycle only
            reg_ctrl[0] <= 1'b0;
            reg_ctrl[1] <= 1'b0;

            if (!s_axi_ctrl_awready && s_axi_ctrl_awvalid && s_axi_ctrl_wvalid) begin
                s_axi_ctrl_awready <= 1'b1;
                s_axi_ctrl_wready  <= 1'b1;
                axi_awaddr_latched <= s_axi_ctrl_awaddr;
            end else begin
                s_axi_ctrl_awready <= 1'b0;
                s_axi_ctrl_wready  <= 1'b0;
            end

            if (s_axi_ctrl_awready && s_axi_ctrl_wready) begin
                case (axi_awaddr_latched)
                    ADDR_CTRL:        reg_ctrl        <= s_axi_ctrl_wdata;
                    ADDR_MEM_ADDR_LO: reg_mem_addr_lo  <= s_axi_ctrl_wdata;
                    ADDR_MEM_ADDR_HI: reg_mem_addr_hi  <= s_axi_ctrl_wdata;
                    ADDR_MEM_WDATA:   reg_mem_wdata     <= s_axi_ctrl_wdata;
                    default: ;
                endcase
                s_axi_ctrl_bvalid <= 1'b1;
                s_axi_ctrl_bresp  <= 2'b00; // OKAY
            end else if (s_axi_ctrl_bvalid && s_axi_ctrl_bready) begin
                s_axi_ctrl_bvalid <= 1'b0;
            end
        end
    end

    // ---- Read channel FSM ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_ctrl_arready <= 1'b0;
            s_axi_ctrl_rvalid  <= 1'b0;
            s_axi_ctrl_rresp   <= 2'b00;
            s_axi_ctrl_rdata   <= 32'h0;
        end else begin
            if (!s_axi_ctrl_arready && s_axi_ctrl_arvalid) begin
                s_axi_ctrl_arready <= 1'b1;
                axi_araddr_latched <= s_axi_ctrl_araddr;
            end else begin
                s_axi_ctrl_arready <= 1'b0;
            end

            if (s_axi_ctrl_arready && s_axi_ctrl_arvalid && !s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rvalid <= 1'b1;
                s_axi_ctrl_rresp  <= 2'b00; // OKAY
                case (axi_araddr_latched)
                    ADDR_CTRL:        s_axi_ctrl_rdata <= reg_ctrl;
                    ADDR_STATUS:      s_axi_ctrl_rdata <= reg_status;
                    ADDR_MEM_ADDR_LO: s_axi_ctrl_rdata <= reg_mem_addr_lo;
                    ADDR_MEM_ADDR_HI: s_axi_ctrl_rdata <= reg_mem_addr_hi;
                    ADDR_MEM_WDATA:   s_axi_ctrl_rdata <= reg_mem_wdata;
                    ADDR_MEM_RDATA:   s_axi_ctrl_rdata <= reg_mem_rdata;
                    ADDR_PKT_COUNT:   s_axi_ctrl_rdata <= reg_pkt_count;
                    default:          s_axi_ctrl_rdata <= 32'hDEAD_BEEF;
                endcase
            end else if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
                s_axi_ctrl_rvalid <= 1'b0;
            end
        end
    end

    assign mem_wr_start_pulse = reg_ctrl[0];
    assign mem_rd_start_pulse = reg_ctrl[1];

    // =========================================================================
    // 2. AXI4 MASTER — SINGLE-BEAT HBM/DDR ACCESS (demo only)
    //    Triggered by CTRL[0]=write, CTRL[1]=read. Extend to bursts for
    //    real throughput; this is intentionally minimal to show the
    //    handshake shape.
    // =========================================================================
    localparam MEM_IDLE      = 3'd0,
               MEM_WR_ADDR   = 3'd1,
               MEM_WR_DATA   = 3'd2,
               MEM_WR_RESP   = 3'd3,
               MEM_RD_ADDR   = 3'd4,
               MEM_RD_DATA   = 3'd5,
               MEM_DONE      = 3'd6;

    reg [2:0] mem_state;
    wire [C_M_AXI_ADDR_WIDTH-1:0] mem_target_addr = {reg_mem_addr_hi, reg_mem_addr_lo};

    always @(posedge aclk) begin
        if (!aresetn) begin
            mem_state          <= MEM_IDLE;
            m_axi_mem_awvalid  <= 1'b0;
            m_axi_mem_wvalid   <= 1'b0;
            m_axi_mem_wlast    <= 1'b0;
            m_axi_mem_bready   <= 1'b0;
            m_axi_mem_arvalid  <= 1'b0;
            m_axi_mem_rready   <= 1'b0;
            reg_status         <= 32'h0;
            reg_mem_rdata      <= 32'h0;
            m_axi_mem_awsize   <= 3'b110; // 64 bytes (512-bit bus)
            m_axi_mem_awburst  <= 2'b01;  // INCR
            m_axi_mem_awlen    <= 8'h00;  // single beat
            m_axi_mem_arsize   <= 3'b110;
            m_axi_mem_arburst  <= 2'b01;
            m_axi_mem_arlen    <= 8'h00;
            m_axi_mem_wstrb    <= {(C_M_AXI_DATA_WIDTH/8){1'b1}};
        end else begin
            case (mem_state)
                MEM_IDLE: begin
                    reg_status[1] <= 1'b0; // clear "done" once acknowledged
                    if (mem_wr_start_pulse) begin
                        m_axi_mem_awaddr  <= mem_target_addr;
                        m_axi_mem_awvalid <= 1'b1;
                        reg_status[0]     <= 1'b1; // busy
                        mem_state         <= MEM_WR_ADDR;
                    end else if (mem_rd_start_pulse) begin
                        m_axi_mem_araddr  <= mem_target_addr;
                        m_axi_mem_arvalid <= 1'b1;
                        reg_status[0]     <= 1'b1; // busy
                        mem_state         <= MEM_RD_ADDR;
                    end
                end

                // ---- Write path ----
                MEM_WR_ADDR: begin
                    if (m_axi_mem_awready) begin
                        m_axi_mem_awvalid <= 1'b0;
                        m_axi_mem_wdata   <= {{(C_M_AXI_DATA_WIDTH-32){1'b0}}, reg_mem_wdata};
                        m_axi_mem_wvalid  <= 1'b1;
                        m_axi_mem_wlast   <= 1'b1;
                        mem_state         <= MEM_WR_DATA;
                    end
                end
                MEM_WR_DATA: begin
                    if (m_axi_mem_wready) begin
                        m_axi_mem_wvalid <= 1'b0;
                        m_axi_mem_wlast  <= 1'b0;
                        m_axi_mem_bready <= 1'b1;
                        mem_state        <= MEM_WR_RESP;
                    end
                end
                MEM_WR_RESP: begin
                    if (m_axi_mem_bvalid) begin
                        m_axi_mem_bready <= 1'b0;
                        mem_state        <= MEM_DONE;
                    end
                end

                // ---- Read path ----
                MEM_RD_ADDR: begin
                    if (m_axi_mem_arready) begin
                        m_axi_mem_arvalid <= 1'b0;
                        m_axi_mem_rready  <= 1'b1;
                        mem_state         <= MEM_RD_DATA;
                    end
                end
                MEM_RD_DATA: begin
                    if (m_axi_mem_rvalid) begin
                        reg_mem_rdata    <= m_axi_mem_rdata[31:0];
                        m_axi_mem_rready <= 1'b0;
                        mem_state        <= MEM_DONE;
                    end
                end

                MEM_DONE: begin
                    reg_status[0] <= 1'b0; // busy = 0
                    reg_status[1] <= 1'b1; // done = 1
                    mem_state     <= MEM_IDLE;
                end

                default: mem_state <= MEM_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 3. AXI4-STREAM — BULK DATA PASS-THROUGH (demo only)
    //    Replace this block with real packet processing (e.g. market-data
    //    parsing, order-book update, filtering, timestamping, etc).
    //    As written: forwards s_axis_data -> m_axis_data unchanged and
    //    counts completed packets (tlast pulses) into reg_pkt_count.
    // =========================================================================
    always @(*) begin
        // Simple combinational pass-through; back-pressure propagates
        // naturally since tready is wired straight through.
        m_axis_data_tdata  = s_axis_data_tdata;
        m_axis_data_tkeep  = s_axis_data_tkeep;
        m_axis_data_tlast  = s_axis_data_tlast;
        m_axis_data_tvalid = s_axis_data_tvalid;
        s_axis_data_tready = m_axis_data_tready;
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            reg_pkt_count <= 32'h0;
        end else if (s_axis_data_tvalid && s_axis_data_tready && s_axis_data_tlast) begin
            reg_pkt_count <= reg_pkt_count + 32'h1;
        end
    end

endmodule
