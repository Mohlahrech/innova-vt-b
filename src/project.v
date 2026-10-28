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

  wire rst = !rst_n;

  wire [7:0] rx_data;
  wire       rx_valid;
  wire       txd;

  // Echo: every received byte goes straight back out.
  uart #(
      .DATA_WIDTH(8),
      .PRESCALE_WIDTH(PRESCALE_WIDTH)
  ) uart_inst (
      .clk(clk),
      .rst(rst),
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

  reg [7:0] duty [0:NUM_CH-1];
  reg [3:0] sel;
  reg       have_sel;
  reg [7:0] counter;
  reg       pwm_tick;  // counter steps every other clock, so PWM stays at 100 MHz / 512 = 195 kHz

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      have_sel <= 1'b0;
      sel      <= 4'd0;
      counter  <= 8'd0;
      pwm_tick <= 1'b0;
      for (i = 0; i < NUM_CH; i = i + 1) duty[i] <= 8'd0;
    end else begin
      pwm_tick <= !pwm_tick;
      if (pwm_tick) counter <= counter + 8'd1;
      if (rx_valid) begin
        if (rx_data[7]) begin
          sel      <= rx_data[3:0];
          have_sel <= 1'b1;
        end else if (have_sel) begin
          if (sel < NUM_CH) duty[sel] <= {rx_data[6:0], rx_data[6]};
          have_sel <= 1'b0;
        end
      end
    end
  end

  wire [NUM_CH-1:0] pwm;
  genvar g;
  generate
    for (g = 0; g < NUM_CH; g = g + 1) begin : ch
      assign pwm[g] = counter < duty[g];
    end
  endgenerate

  assign uo_out  = pwm[7:0];
  assign uio_out = {pwm[14:8], txd};
  assign uio_oe  = 8'hFF;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, ui_in[7:4], ui_in[2:0], uio_in, 1'b0};

endmodule
