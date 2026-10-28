# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# Cycles per UART bit: prescale * 8, with prescale = 100 MHz / (115200 * 8) = 108.
BIT_CYCLES = 108 * 8


async def send_byte(dut, value):
    """Drive one 8N1 UART frame on ui_in[3] (RX)."""
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.ui_in.value = b << 3
        await ClockCycles(dut.clk, BIT_CYCLES)


async def duty_of(dut, bit, cycles=512):
    """Fraction of cycles a uo_out bit is high."""
    high = 0
    for _ in range(cycles):
        await ClockCycles(dut.clk, 1)
        high += (int(dut.uo_out.value) >> bit) & 1
    return high / cycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 1 << 3  # RX idles high
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, BIT_CYCLES)

    assert await duty_of(dut, 0) == 0, "channel 0 must be off after reset"

    # Channel 0 to full scale, channel 2 to about half.
    await send_byte(dut, 0x80)
    await send_byte(dut, 0x7F)
    await send_byte(dut, 0x82)
    await send_byte(dut, 0x40)
    await ClockCycles(dut.clk, BIT_CYCLES * 2)

    full = await duty_of(dut, 0)
    half = await duty_of(dut, 2)
    off = await duty_of(dut, 1)
    dut._log.info(f"duty ch0={full:.3f} ch2={half:.3f} ch1={off:.3f}")
    assert full > 0.95
    assert 0.45 < half < 0.55
    assert off == 0
