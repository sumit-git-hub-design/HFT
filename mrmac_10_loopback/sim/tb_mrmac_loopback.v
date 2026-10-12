`timescale 1ps / 1ps
//------------------------------------------------------------------------------
// tb_mrmac_loopback.v
//
// Basic testbench for design_1_wrapper (MRMAC + GT Quad)
//   Config : 10GE, Static, Low Latency, 32-bit AXI4-Stream, Non-segmented
//   Port   : Port 0 / Client 0  (GT lane 0)
//
// Data path that is exercised
//   TB AXIS TX -> MRMAC TX -> GT Quad TX -> (serial wire) -> GT Quad RX
//   -> MRMAC RX -> AXIS RX -> TB checker
//
// The serial TX pins are wired to the serial RX pins inside this TB (this
// replaces the SFP+ cable/loopback module). Every packet sent on the TX AXIS
// bus must come back on the RX AXIS bus with identical bytes.
//
// MRMAC adds the FCS on TX (it is not part of the TB data). On RX the FCS may
// or may not be stripped depending on the IP setting, so the checker accepts
// rx_len == tx_len (stripped) or rx_len == tx_len + 4 (kept).
//------------------------------------------------------------------------------
module tb_mrmac_loopback;

  //---------------------------------------------------------------------------
  // User knobs
  //---------------------------------------------------------------------------
  parameter integer REFCLK_PERIOD_PS = 6400;   // 156.25 MHz. Must match GT refclk set in the GT wizard
  parameter integer APB_CLK_PERIOD_PS = 10000; // 100 MHz, used for apb3clk_quad and s_axi_aclk
  parameter integer NUM_PKTS         = 8;
  parameter integer MAX_PKT_BYTES    = 2048;   // storage per packet
  parameter [2:0]   GT_LOOPBACK      = 3'b000; // 000 = use the external serial wire below
                                               // 010 = GT near-end PMA loopback
  parameter integer GT_RST_TIMEOUT_US = 500;
  parameter integer LINK_TIMEOUT_US   = 500;
  parameter integer SIM_TIMEOUT_US    = 3000;

  //---------------------------------------------------------------------------
  // Clocks that the TB generates
  //---------------------------------------------------------------------------
  reg refclk  = 1'b0;
  reg apb_clk = 1'b0;
  always #(REFCLK_PERIOD_PS/2)  refclk  = ~refclk;
  always #(APB_CLK_PERIOD_PS/2) apb_clk = ~apb_clk;

  wire [0:0] clk_in_p = refclk;
  wire [0:0] clk_in_n = ~refclk;

  //---------------------------------------------------------------------------
  // GT serial pins: TX wired back to RX (stand-in for the SFP loopback)
  //---------------------------------------------------------------------------
  wire [3:0] gt_txp, gt_txn;
  wire [3:0] gt_rxp = gt_txp;
  wire [3:0] gt_rxn = gt_txn;

  //---------------------------------------------------------------------------
  // GT user clocks come out of the wrapper and go back into it
  //---------------------------------------------------------------------------
  wire [0:0] ch0_tx_usr_clk, ch1_tx_usr_clk, ch2_tx_usr_clk, ch3_tx_usr_clk;
  wire [0:0] ch0_rx_usr_clk, ch1_rx_usr_clk, ch2_rx_usr_clk, ch3_rx_usr_clk;
  wire [3:0] tx_usr_clk = {ch3_tx_usr_clk, ch2_tx_usr_clk, ch1_tx_usr_clk, ch0_tx_usr_clk};
  wire [3:0] rx_usr_clk = {ch3_rx_usr_clk, ch2_rx_usr_clk, ch1_rx_usr_clk, ch0_rx_usr_clk};

  // Port 0 AXI4-Stream clocks (Low Latency mode, 10GE):
  //   TX side = tx_core_clk[0], RX side = rx_serdes_clk[0]
  wire tx_clk0 = tx_usr_clk[0];
  wire rx_clk0 = rx_usr_clk[0];

  //---------------------------------------------------------------------------
  // Resets
  //---------------------------------------------------------------------------
  reg       s_axi_aresetn   = 1'b0;
  reg [3:0] gt_reset_all    = 4'hF;
  reg [3:0] tx_core_reset   = 4'hF;
  reg [3:0] rx_core_reset   = 4'hF;
  reg [3:0] tx_serdes_reset = 4'hF;
  reg [3:0] rx_serdes_reset = 4'hF;

  wire [3:0] gt_tx_done, gt_rx_done;
  wire       gtpowergood;

  //---------------------------------------------------------------------------
  // AXI4-Stream, Port 0 (32-bit)
  //---------------------------------------------------------------------------
  reg         tx_tvalid = 1'b0;
  reg  [31:0] tx_tdata  = 32'h0;
  reg  [3:0]  tx_tkeep  = 4'h0;
  reg         tx_tlast  = 1'b0;
  reg         tx_terr   = 1'b0;
  wire        tx_tready;

  wire        rx_tvalid;
  wire        rx_tlast;
  wire [63:0] rx_tdata;
  wire [10:0] rx_tkeep_user;

  //---------------------------------------------------------------------------
  // Status (port 0)
  //---------------------------------------------------------------------------
  wire        st_rx_status, st_rx_hi_ber, st_rx_local_fault;
  wire [19:0] st_rx_block_lock;
  wire        st_rx_bad_fcs, st_rx_axis_err, st_rx_fifo_ovf, st_rx_truncated;
  wire        st_tx_axis_unf, st_tx_axis_err, st_tx_local_fault;

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  design_1_wrapper dut (
    // APB3 to GT Quad (not used)
    .APB3_INTF_paddr   (16'h0000),
    .APB3_INTF_penable (1'b0),
    .APB3_INTF_psel    (1'b0),
    .APB3_INTF_pwdata  (32'h0000_0000),
    .APB3_INTF_pwrite  (1'b0),
    .apb3clk_quad      (apb_clk),

    // GT reference clock and serial pins
    .CLK_IN_D_clk_p    (clk_in_p),
    .CLK_IN_D_clk_n    (clk_in_n),
    .GT_Serial_grx_p   (gt_rxp),
    .GT_Serial_grx_n   (gt_rxn),
    .GT_Serial_gtx_p   (gt_txp),
    .GT_Serial_gtx_n   (gt_txn),

    // GT per-channel controls and user clocks
    .ch0_loopback  (GT_LOOPBACK), .ch1_loopback  (GT_LOOPBACK),
    .ch2_loopback  (GT_LOOPBACK), .ch3_loopback  (GT_LOOPBACK),
    .ch0_rxrate    (8'h00),       .ch1_rxrate    (8'h00),
    .ch2_rxrate    (8'h00),       .ch3_rxrate    (8'h00),
    .ch0_txrate    (8'h00),       .ch1_txrate    (8'h00),
    .ch2_txrate    (8'h00),       .ch3_txrate    (8'h00),
    .ch0_tx_usr_clk(ch0_tx_usr_clk), .ch1_tx_usr_clk(ch1_tx_usr_clk),
    .ch2_tx_usr_clk(ch2_tx_usr_clk), .ch3_tx_usr_clk(ch3_tx_usr_clk),
    .ch0_rx_usr_clk(ch0_rx_usr_clk), .ch1_rx_usr_clk(ch1_rx_usr_clk),
    .ch2_rx_usr_clk(ch2_rx_usr_clk), .ch3_rx_usr_clk(ch3_rx_usr_clk),
    .ch0_txusrclk  (ch0_tx_usr_clk), .ch1_txusrclk  (ch1_tx_usr_clk),
    .ch2_txusrclk  (ch2_tx_usr_clk), .ch3_txusrclk  (ch3_tx_usr_clk),
    .ch0_rxusrclk  (ch0_rx_usr_clk), .ch1_rxusrclk  (ch1_rx_usr_clk),
    .ch2_rxusrclk  (ch2_rx_usr_clk), .ch3_rxusrclk  (ch3_rx_usr_clk),

    // GT resets
    .gt_reset_all_in         (gt_reset_all),
    .gt_reset_rx_datapath_in (4'h0),
    .gt_reset_tx_datapath_in (4'h0),
    .gt_rx_reset_done_out    (gt_rx_done),
    .gt_tx_reset_done_out    (gt_tx_done),
    .gtpowergood             (gtpowergood),
    .gtpowergood_in          (gtpowergood),

    // MRMAC clocks (narrow-mode style connection, see notes in the reply)
    .tx_core_clk       (tx_usr_clk),
    .rx_core_clk       (rx_usr_clk),
    .rx_serdes_clk     (rx_usr_clk),
    .tx_alt_serdes_clk (tx_usr_clk),
    .rx_alt_serdes_clk (rx_usr_clk),
    .tx_axi_clk        (tx_usr_clk),
    .rx_axi_clk        (rx_usr_clk),
    .tx_flexif_clk     (tx_usr_clk),
    .rx_flexif_clk     (rx_usr_clk),
    .tx_ts_clk         ({4{apb_clk}}),
    .rx_ts_clk         ({4{apb_clk}}),

    // MRMAC resets (only port 0 is released, ports 1..3 stay in reset)
    .tx_core_reset     (tx_core_reset),
    .rx_core_reset     (rx_core_reset),
    .rx_flexif_reset   (rx_core_reset),
    .tx_serdes_reset   (tx_serdes_reset),
    .rx_serdes_reset   (rx_serdes_reset),

    // AXI4-Lite (static config: nothing to write, clock and reset only)
    .s_axi_aclk    (apb_clk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_araddr  (32'h0), .s_axi_arvalid (1'b0),
    .s_axi_awaddr  (32'h0), .s_axi_awvalid (1'b0),
    .s_axi_wdata   (32'h0), .s_axi_wvalid  (1'b0),
    .s_axi_bready  (1'b0),  .s_axi_rready  (1'b0),

    // Misc inputs, tied off
    .pm_tick (4'h0),
    .tx_preamblein_tx_preamblein_0 (56'h0),
    .tx_preamblein_tx_preamblein_1 (56'h0),
    .tx_preamblein_tx_preamblein_2 (56'h0),
    .tx_preamblein_tx_preamblein_3 (56'h0),
    .ctl_tx_port0_ctl_tx_lane0_vlm_bip7_override       (1'b0),
    .ctl_tx_port0_ctl_tx_lane0_vlm_bip7_override_value (8'h00),
    .ctl_tx_port0_ctl_tx_send_idle_in (1'b0),
    .ctl_tx_port0_ctl_tx_send_lfi_in  (1'b0),
    .ctl_tx_port0_ctl_tx_send_rfi_in  (1'b0),
    .ctl_tx_port1_ctl_tx_send_idle_in (1'b0),
    .ctl_tx_port1_ctl_tx_send_lfi_in  (1'b0),
    .ctl_tx_port1_ctl_tx_send_rfi_in  (1'b0),
    .ctl_tx_port2_ctl_tx_lane0_vlm_bip7_override       (1'b0),
    .ctl_tx_port2_ctl_tx_lane0_vlm_bip7_override_value (8'h00),
    .ctl_tx_port2_ctl_tx_send_idle_in (1'b0),
    .ctl_tx_port2_ctl_tx_send_lfi_in  (1'b0),
    .ctl_tx_port2_ctl_tx_send_rfi_in  (1'b0),
    .ctl_tx_port3_ctl_tx_send_idle_in (1'b0),
    .ctl_tx_port3_ctl_tx_send_lfi_in  (1'b0),
    .ctl_tx_port3_ctl_tx_send_rfi_in  (1'b0),

    // Port 0 TX AXI4-Stream
    .tx_axis_tvalid_0     (tx_tvalid),
    .tx_axis_tready_0     (tx_tready),
    .tx_axis_tlast_0      (tx_tlast),
    .tx_axis_tdata0       ({32'h0, tx_tdata}),
    .tx_axis_tkeep_user0  ({2'b00, tx_terr, 4'b0000, tx_tkeep}),

    // Port 0 RX AXI4-Stream
    .rx_axis_tvalid_0     (rx_tvalid),
    .rx_axis_tlast_0      (rx_tlast),
    .rx_axis_tdata0       (rx_tdata),
    .rx_axis_tkeep_user0  (rx_tkeep_user),

    // Ports 1..3 AXI4-Stream tied off
    .tx_axis_tvalid_1 (1'b0), .tx_axis_tvalid_2 (1'b0), .tx_axis_tvalid_3 (1'b0),
    .tx_axis_tlast_1  (1'b0), .tx_axis_tlast_2  (1'b0), .tx_axis_tlast_3  (1'b0),
    .tx_axis_tdata2   (64'h0), .tx_axis_tdata4  (64'h0), .tx_axis_tdata6  (64'h0),
    .tx_axis_tkeep_user2 (11'h0), .tx_axis_tkeep_user4 (11'h0), .tx_axis_tkeep_user6 (11'h0),

    // Port 0 status
    .stat_rx_port0_stat_rx_status            (st_rx_status),
    .stat_rx_port0_stat_rx_hi_ber            (st_rx_hi_ber),
    .stat_rx_port0_stat_rx_local_fault       (st_rx_local_fault),
    .stat_rx_port0_stat_rx_block_lock        (st_rx_block_lock),
    .stat_rx_port0_stat_rx_bad_fcs           (st_rx_bad_fcs),
    .stat_rx_port0_stat_rx_axis_err          (st_rx_axis_err),
    .stat_rx_port0_stat_rx_axis_fifo_overflow(st_rx_fifo_ovf),
    .stat_rx_port0_stat_rx_truncated         (st_rx_truncated),
    .stat_tx_port0_stat_tx_axis_unf          (st_tx_axis_unf),
    .stat_tx_port0_stat_tx_axis_err          (st_tx_axis_err),
    .stat_tx_port0_stat_tx_local_fault       (st_tx_local_fault)
  );

  //---------------------------------------------------------------------------
  // Clock frequency measurement (informational)
  //---------------------------------------------------------------------------
  realtime t_tx_last = 0.0, t_rx_last = 0.0;
  real     tx_period_ps = 0.0, rx_period_ps = 0.0;
  always @(posedge tx_clk0) begin
    tx_period_ps = $realtime - t_tx_last;
    t_tx_last    = $realtime;
  end
  always @(posedge rx_clk0) begin
    rx_period_ps = $realtime - t_rx_last;
    t_rx_last    = $realtime;
  end

  //---------------------------------------------------------------------------
  // Packet memory
  //---------------------------------------------------------------------------
  reg [7:0] tx_mem [0:NUM_PKTS*MAX_PKT_BYTES-1];
  reg [7:0] rx_mem [0:NUM_PKTS*MAX_PKT_BYTES-1];
  integer   tx_len [0:NUM_PKTS-1];
  integer   rx_len [0:NUM_PKTS-1];
  reg       rx_perr [0:NUM_PKTS-1];

  // Packet lengths WITHOUT FCS. 60 bytes + 4 byte FCS = 64 byte minimum frame.
  // Lengths 60..63 cover every tkeep pattern of the last 32-bit word.
  function integer pkt_len;
    input integer n;
    begin
      case (n % 8)
        0: pkt_len = 60;
        1: pkt_len = 61;
        2: pkt_len = 62;
        3: pkt_len = 63;
        4: pkt_len = 64;
        5: pkt_len = 128;
        6: pkt_len = 300;
        default: pkt_len = 1000;
      endcase
    end
  endfunction

  task build_packets;
    integer n, i, base;
    begin
      for (n = 0; n < NUM_PKTS; n = n + 1) begin
        tx_len[n] = pkt_len(n);
        base      = n * MAX_PKT_BYTES;
        // Destination MAC
        tx_mem[base+0] = 8'h00; tx_mem[base+1] = 8'h0A; tx_mem[base+2] = 8'h35;
        tx_mem[base+3] = 8'h00; tx_mem[base+4] = 8'h00; tx_mem[base+5] = 8'h01;
        // Source MAC
        tx_mem[base+6] = 8'h00; tx_mem[base+7] = 8'h0A; tx_mem[base+8] = 8'h35;
        tx_mem[base+9] = 8'h00; tx_mem[base+10] = 8'h00; tx_mem[base+11] = 8'h02;
        // EtherType 0x88B5 (IEEE local experimental)
        tx_mem[base+12] = 8'h88; tx_mem[base+13] = 8'hB5;
        // Payload: byte 14 = packet number, rest = deterministic pattern
        tx_mem[base+14] = n;
        for (i = 15; i < tx_len[n]; i = i + 1)
          tx_mem[base+i] = i*13 + n*37 + 90;
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // TX driver
  // Data is changed 100 ps after a rising edge. tready is sampled on the
  // falling edge, so it is the value the MRMAC sees on the next rising edge.
  //---------------------------------------------------------------------------
  task send_packet;
    input integer n;
    integer w, nwords, base, len, rem, b;
    reg [31:0] d;
    reg [3:0]  k;
    reg        accepted;
    begin
      len    = tx_len[n];
      base   = n * MAX_PKT_BYTES;
      nwords = (len + 3) / 4;

      @(posedge tx_clk0); #100;
      for (w = 0; w < nwords; w = w + 1) begin
        d = 32'h0;
        for (b = 0; b < 4; b = b + 1)
          if (w*4 + b < len) d[8*b +: 8] = tx_mem[base + w*4 + b];

        rem = len - w*4;
        if (w == nwords-1) begin
          tx_tlast = 1'b1;
          k = (rem >= 4) ? 4'hF : ((4'h1 << rem) - 4'h1);
        end else begin
          tx_tlast = 1'b0;
          k = 4'hF;
        end

        tx_tdata  = d;
        tx_tkeep  = k;
        tx_tvalid = 1'b1;

        accepted = 1'b0;
        while (!accepted) begin
          @(negedge tx_clk0);
          accepted = (tx_tready === 1'b1);
          @(posedge tx_clk0); #100;
        end
      end
      tx_tvalid = 1'b0;
      tx_tlast  = 1'b0;
      tx_tkeep  = 4'h0;
      tx_tdata  = 32'h0;
    end
  endtask

  //---------------------------------------------------------------------------
  // RX monitor (samples on the falling edge of the RX clock)
  //---------------------------------------------------------------------------
  integer rx_pkts  = 0;
  integer rx_cur   = 0;
  integer rx_extra = 0;
  integer nb, bb;
  reg     rx_en    = 1'b0;

  always @(negedge rx_clk0) begin
    if (rx_en && (rx_tvalid === 1'b1)) begin
      if (rx_tlast === 1'b1) begin
        case (rx_tkeep_user[3:0])
          4'b0001: nb = 1;
          4'b0011: nb = 2;
          4'b0111: nb = 3;
          default: nb = 4;
        endcase
      end else begin
        nb = 4;
      end

      if (rx_pkts < NUM_PKTS) begin
        for (bb = 0; bb < nb; bb = bb + 1) begin
          if (rx_cur < MAX_PKT_BYTES)
            rx_mem[rx_pkts*MAX_PKT_BYTES + rx_cur] = rx_tdata[8*bb +: 8];
          rx_cur = rx_cur + 1;
        end
      end else begin
        rx_cur = rx_cur + nb;
      end

      if (rx_tlast === 1'b1) begin
        if (rx_pkts < NUM_PKTS) begin
          rx_len[rx_pkts]  = rx_cur;
          rx_perr[rx_pkts] = (rx_tkeep_user[8] === 1'b1);
        end else begin
          rx_extra = rx_extra + 1;
        end
        rx_pkts = rx_pkts + 1;
        rx_cur  = 0;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Sticky error flags (only after traffic starts)
  //---------------------------------------------------------------------------
  reg traffic_on = 1'b0;
  reg sticky_rx_bad_fcs = 1'b0, sticky_rx_axis_err = 1'b0, sticky_rx_ovf = 1'b0;
  reg sticky_rx_trunc = 1'b0, sticky_tx_unf = 1'b0, sticky_tx_err = 1'b0;
  always @(posedge apb_clk) begin
    if (traffic_on) begin
      if (st_rx_bad_fcs   === 1'b1) sticky_rx_bad_fcs  <= 1'b1;
      if (st_rx_axis_err  === 1'b1) sticky_rx_axis_err <= 1'b1;
      if (st_rx_fifo_ovf  === 1'b1) sticky_rx_ovf      <= 1'b1;
      if (st_rx_truncated === 1'b1) sticky_rx_trunc    <= 1'b1;
      if (st_tx_axis_unf  === 1'b1) sticky_tx_unf      <= 1'b1;
      if (st_tx_axis_err  === 1'b1) sticky_tx_err      <= 1'b1;
    end
  end

  //---------------------------------------------------------------------------
  // Main sequence
  //---------------------------------------------------------------------------
  integer t, n, i, errors, fcs_delta, mism;

  initial begin
    errors = 0;
    build_packets;

    $display("[%0t] TB start. 10GE low-latency 32-bit non-segmented, port 0", $time);

    // ---- reset / GT bring-up ----
    #200000;                         // 200 ns
    s_axi_aresetn = 1'b1;
    repeat (20) @(posedge apb_clk);
    gt_reset_all = 4'h0;             // release GT reset, bridge runs the reset sequence
    $display("[%0t] gt_reset_all released", $time);

    t = 0;
    while (((gt_tx_done[0] !== 1'b1) || (gt_rx_done[0] !== 1'b1)) && (t < GT_RST_TIMEOUT_US)) begin
      #1000000; t = t + 1;
    end
    if ((gt_tx_done[0] !== 1'b1) || (gt_rx_done[0] !== 1'b1)) begin
      $display("[%0t] ERROR: GT reset done not seen. gtpowergood=%b tx_done=%b rx_done=%b",
               $time, gtpowergood, gt_tx_done, gt_rx_done);
      $display("*** TEST FAILED ***");
      $finish;
    end
    $display("[%0t] GT reset done (gtpowergood=%b)", $time, gtpowergood);

    // ---- release MRMAC port 0 resets (ports 1..3 stay in reset) ----
    #100000;
    tx_serdes_reset[0] = 1'b0;
    rx_serdes_reset[0] = 1'b0;
    repeat (20) @(posedge tx_clk0);
    tx_core_reset[0] = 1'b0;
    rx_core_reset[0] = 1'b0;
    $display("[%0t] MRMAC port 0 resets released", $time);

    // ---- wait for PCS block lock / link ----
    t = 0;
    while ((st_rx_status !== 1'b1) && (t < LINK_TIMEOUT_US)) begin
      #1000000; t = t + 1;
    end
    if (st_rx_status !== 1'b1) begin
      $display("[%0t] ERROR: stat_rx_status never went high.", $time);
      $display("        block_lock[0]=%b hi_ber=%b rx_local_fault=%b tx_local_fault=%b",
               st_rx_block_lock[0], st_rx_hi_ber, st_rx_local_fault, st_tx_local_fault);
      $display("        tx_core_clk period=%0.1f ps, rx_serdes_clk period=%0.1f ps",
               tx_period_ps, rx_period_ps);
      $display("*** TEST FAILED ***");
      $finish;
    end
    $display("[%0t] Link up: block_lock[0]=%b. tx_clk period=%0.1f ps, rx_clk period=%0.1f ps",
             $time, st_rx_block_lock[0], tx_period_ps, rx_period_ps);

    #2000000;                        // 2 us settle
    traffic_on = 1'b1;
    rx_en      = 1'b1;

    // ---- send packets ----
    for (n = 0; n < NUM_PKTS; n = n + 1) begin
      $display("[%0t] TX packet %0d, %0d bytes (without FCS)", $time, n, tx_len[n]);
      send_packet(n);
      repeat (16) @(posedge tx_clk0);
    end

    // ---- wait for all packets to come back ----
    t = 0;
    while ((rx_pkts < NUM_PKTS) && (t < 100)) begin
      #1000000; t = t + 1;
    end
    #2000000;                        // catch unexpected extra packets

    // ---- check ----
    fcs_delta = -1;
    for (n = 0; n < NUM_PKTS; n = n + 1) begin
      if (n >= rx_pkts) begin
        $display("ERROR: packet %0d not received", n);
        errors = errors + 1;
      end else begin
        if (fcs_delta < 0) fcs_delta = rx_len[n] - tx_len[n];
        if ((rx_len[n] - tx_len[n]) != fcs_delta || (fcs_delta != 0 && fcs_delta != 4)) begin
          $display("ERROR: packet %0d length mismatch: tx=%0d rx=%0d", n, tx_len[n], rx_len[n]);
          errors = errors + 1;
        end
        mism = 0;
        for (i = 0; i < tx_len[n]; i = i + 1)
          if (rx_mem[n*MAX_PKT_BYTES + i] !== tx_mem[n*MAX_PKT_BYTES + i]) begin
            if (mism < 4)
              $display("ERROR: packet %0d byte %0d: tx=%02h rx=%02h", n, i,
                       tx_mem[n*MAX_PKT_BYTES + i], rx_mem[n*MAX_PKT_BYTES + i]);
            mism = mism + 1;
          end
        if (mism != 0) errors = errors + 1;
        if (rx_perr[n]) begin
          $display("ERROR: packet %0d received with error flag (tkeep_user[8])", n);
          errors = errors + 1;
        end
        if ((mism == 0) && !rx_perr[n] && ((rx_len[n] - tx_len[n]) == fcs_delta))
          $display("PASS : packet %0d, %0d bytes", n, tx_len[n]);
      end
    end

    if (rx_extra != 0) begin
      $display("ERROR: %0d unexpected extra packet(s) received", rx_extra);
      errors = errors + 1;
    end
    if (sticky_rx_bad_fcs || sticky_rx_axis_err || sticky_rx_ovf ||
        sticky_rx_trunc   || sticky_tx_unf      || sticky_tx_err) begin
      $display("ERROR: status flags set: rx_bad_fcs=%b rx_axis_err=%b rx_fifo_ovf=%b rx_trunc=%b tx_unf=%b tx_axis_err=%b",
               sticky_rx_bad_fcs, sticky_rx_axis_err, sticky_rx_ovf,
               sticky_rx_trunc, sticky_tx_unf, sticky_tx_err);
      errors = errors + 1;
    end

    $display("Summary: sent=%0d received=%0d rx_len-tx_len=%0d (0 = FCS stripped, 4 = FCS kept)",
             NUM_PKTS, rx_pkts, fcs_delta);
    if (errors == 0) $display("*** TEST PASSED ***");
    else             $display("*** TEST FAILED (%0d errors) ***", errors);
    $finish;
  end

  //---------------------------------------------------------------------------
  // Global watchdog
  //---------------------------------------------------------------------------
  initial begin
    repeat (SIM_TIMEOUT_US) #1000000;
    $display("[%0t] ERROR: global simulation timeout", $time);
    $display("*** TEST FAILED ***");
    $finish;
  end

endmodule
