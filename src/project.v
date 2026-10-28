/*
 * Copyright (c) 2026 Innova
 * SPDX-License-Identifier: Apache-2.0
 *
 * 15-channel PWM LED driver, set over a 115200-baud UART.
 *
 * Protocol: a byte with bit 7 set selects a channel (bits 3:0, 0..14);
 * the next byte (bit 7 clear) is that channel's duty, 0..127, stretched to 0..255.
 * Every received byte is echoed back on TX.
 */

`default_nettype none

module tt_um_innova_pwm (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  localparam CLK_HZ   = 100_000_000;
  localparam BAUD     = 115_200;
  localparam [15:0] PRESCALE = CLK_HZ / (BAUD * 8);
  localparam NUM_CH   = 15;
  // Wide enough for the longest bit period (PRESCALE * 8 clocks), and no wider.
  localparam PRESCALE_WIDTH = $clog2(PRESCALE * 8 + 1);

  // Every net below is kept to about ten loads or fewer. Past that the flow
  // buffers it with weak delay cells, which miss the 0.75 ns slew limit at the
  // slow corner. So the reset, the PWM counter and the duty write data are
  // replicated per group of channels; keep on each always block stops synthesis
  // merging the identical copies back together.
  localparam GRP_CH  = 3;                // channels per group
  localparam NUM_GRP = NUM_CH / GRP_CH;  // 5 groups

  // Reset: rst_n is registered twice, through a small tree, so each copy drives
  // one block. Reset takes effect, and releases, two clocks (20 ns) later.
  // rst[0..14]: duty of channel 0..14, rst[15..19]: counter of group 0..4,
  // rst[20]: UART, rst[21]: channel select.
  localparam NUM_RST = NUM_CH + NUM_GRP + 2;
  localparam RST_UART = NUM_CH + NUM_GRP;
  localparam RST_CTRL = NUM_CH + NUM_GRP + 1;
  localparam NUM_RST_A = 5;
  wire [NUM_RST_A-1:0] rst_a;
  wire [NUM_RST-1:0] rst;
  genvar r;
  generate
    for (r = 0; r < NUM_RST_A; r = r + 1) begin : rst_tree
      reg q;
      (* keep *) always @(posedge clk) q <= !rst_n;
      assign rst_a[r] = q;
    end
    for (r = 0; r < NUM_RST; r = r + 1) begin : rst_sync
      reg q;
      (* keep *) always @(posedge clk) q <= rst_a[r % NUM_RST_A];
      assign rst[r] = q;
    end
  endgenerate

  wire [7:0] rx_data;
  wire       rx_valid;
  wire       txd;

  // Echo: every received byte goes straight back out.
  uart #(
      .DATA_WIDTH(8),
      .PRESCALE_WIDTH(PRESCALE_WIDTH)
  ) uart_inst (
      .clk(clk),
      .rst(rst[RST_UART]),
      .s_axis_tdata(rx_data),
      .s_axis_tvalid(rx_valid),
      .s_axis_tready(),
      .m_axis_tdata(rx_data),
      .m_axis_tvalid(rx_valid),
      .m_axis_tready(1'b1),
      .rxd(ui_in[3]),
      .txd(txd),
      .tx_busy(),
      .rx_busy(),
      .rx_overrun_error(),
      .rx_frame_error(),
      .prescale(PRESCALE)
  );

  reg [3:0] sel;
  reg       have_sel;

  always @(posedge clk) begin
    if (rst[RST_CTRL]) begin
      have_sel <= 1'b0;
      sel      <= 4'd0;
    end else if (rx_valid) begin
      if (rx_data[7]) begin
        sel      <= rx_data[3:0];
        have_sel <= 1'b1;
      end else if (have_sel) begin
        have_sel <= 1'b0;
      end
    end
  end

  wire duty_we = rx_valid && !rx_data[7] && have_sel;

  wire [NUM_CH-1:0] pwm;
  genvar g, c;
  generate
    for (g = 0; g < NUM_GRP; g = g + 1) begin : grp
      // PWM counter: bits 8:1 step every other clock, so PWM stays at
      // 100 MHz / 512 = 195 kHz with 256 duty steps.
      reg [8:0] count;
      (* keep *) always @(posedge clk) begin
        if (rst[NUM_CH + g]) count <= 9'd0;
        else count <= count + 9'd1;
      end

      // Write stage: the byte and select are copied per group, then decoded
      // into a registered enable per channel, so a duty write lands two clocks
      // after its byte arrives. rx_data holds the byte until the next one, so
      // wdata is still that byte when the enable fires.
      reg       wen;
      reg [3:0] wsel;
      reg [6:0] wdata;
      (* keep *) always @(posedge clk) begin
        wen   <= duty_we;
        wsel  <= sel;
        wdata <= rx_data[6:0];
      end

      for (c = 0; c < GRP_CH; c = c + 1) begin : ch
        localparam D = g * GRP_CH + c;
        reg [7:0] duty;
        reg       we;
        always @(posedge clk) begin
          we <= wen && wsel == D;
          if (rst[D]) duty <= 8'd0;
          else if (we) duty <= {wdata, wdata[6]};
        end
        assign pwm[D] = count[8:1] < duty;
      end
    end
  endgenerate

  // Registered so the comparators do not eat into the output-pad budget:
  // every PWM edge is one clock (10 ns) later than the comparison.
  reg [NUM_CH-1:0] pwm_q;
  always @(posedge clk) pwm_q <= pwm;  // zero in reset: duty is cleared

  assign uo_out  = pwm_q[7:0];
  assign uio_out = {pwm_q[14:8], txd};
  assign uio_oe  = 8'hFF;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, ui_in[7:4], ui_in[2:0], uio_in, 1'b0};

endmodule
