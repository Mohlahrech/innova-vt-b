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

  // rst_n is registered so the synchronous resets load flops, not the input
  // pad: reset takes effect, and releases, one clock later. Identical copies
  // split the loads; keep on the always block stops synthesis merging them.
  // rst[0]: UART, rst[1]: channel select, rst[2..3]: channel group 0..1.
  wire [3:0] rst;
  genvar r;
  generate
    for (r = 0; r < 4; r = r + 1) begin : rst_sync
      reg q;
      (* keep *) always @(posedge clk) q <= !rst_n;
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
      .rst(rst[0]),
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
    if (rst[1]) begin
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

  // The channels are split into two groups (0-7, 8-14), each with its own
  // PWM counter and write stage, so no counter or data bit drives all 15
  // channels. keep stops synthesis merging the identical copies.
  wire [NUM_CH-1:0] pwm;
  genvar g, d;
  generate
    for (g = 0; g < 2; g = g + 1) begin : grp
      // PWM counter: bits 8:1 step every other clock, so PWM stays at
      // 100 MHz / 512 = 195 kHz with 256 duty steps.
      reg [8:0] count;
      (* keep *) always @(posedge clk) begin
        if (rst[2 + g]) count <= 9'd0;
        else count <= count + 9'd1;
      end

      // Write stage: a duty write lands one clock after its byte arrives.
      // Reset clears duty through the same port: wclr writes 0 to every
      // channel, which saves a reset gate on each of the duty bits.
      reg       wclr;
      reg       wen;
      reg [3:0] wsel;
      reg [6:0] wdata;
      (* keep *) always @(posedge clk) begin
        wclr  <= rst[2 + g];
        wen   <= duty_we;
        wsel  <= sel;
        wdata <= rst[2 + g] ? 7'd0 : rx_data[6:0];
      end

      // Duty is stored as the 7 bits received; the 8-bit value is {d, d[6]}.
      for (d = g * 8; d < (g == 0 ? 8 : NUM_CH); d = d + 1) begin : ch
        reg [6:0] duty;
        always @(posedge clk)
          if (wclr || (wen && wsel == d)) duty <= wdata;
        assign pwm[d] = count[8:1] < {duty, duty[6]};
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
