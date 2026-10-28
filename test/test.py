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


async def recv_byte(dut):
    """Decode one 8N1 UART frame from uio_out[0] (TX)."""
    while int(dut.uio_out.value) & 1:
        await ClockCycles(dut.clk, 1)
    await ClockCycles(dut.clk, BIT_CYCLES // 2)
    assert int(dut.uio_out.value) & 1 == 0, "TX start bit"
    value = 0
    for i in range(8):
        await ClockCycles(dut.clk, BIT_CYCLES)
        value |= (int(dut.uio_out.value) & 1) << i
    await ClockCycles(dut.clk, BIT_CYCLES)
    assert int(dut.uio_out.value) & 1 == 1, "TX stop bit"
    return value


async def send_and_check_echo(dut, value):
    echo = cocotb.start_soon(recv_byte(dut))
    await send_byte(dut, value)
    assert await echo == value, f"echo of {value:#04x}"


async def pwm_period(dut, bit):
    """Clocks between two rising edges of a uo_out bit."""
    async def rising():
        while (int(dut.uo_out.value) >> bit) & 1:
            await ClockCycles(dut.clk, 1)
        while not (int(dut.uo_out.value) >> bit) & 1:
            await ClockCycles(dut.clk, 1)
    await rising()
    cycles = 0
    while (int(dut.uo_out.value) >> bit) & 1:
        await ClockCycles(dut.clk, 1)
        cycles += 1
    while not (int(dut.uo_out.value) >> bit) & 1:
        await ClockCycles(dut.clk, 1)
        cycles += 1
    return cycles


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

    # Channel 0 to full scale, channel 2 to about half; every byte is echoed on TX.
    for b in (0x80, 0x7F, 0x82, 0x40):
        await send_and_check_echo(dut, b)
    await ClockCycles(dut.clk, BIT_CYCLES * 2)

    full = await duty_of(dut, 0)
    half = await duty_of(dut, 2)
    off = await duty_of(dut, 1)
    dut._log.info(f"duty ch0={full:.3f} ch2={half:.3f} ch1={off:.3f}")
    assert full > 0.95
    assert 0.45 < half < 0.55
    assert off == 0

    # PWM runs at 100 MHz / 512 = 195 kHz, the same rate as at 50 MHz.
    period = await pwm_period(dut, 2)
    dut._log.info(f"PWM period {period} clocks")
    assert period == 512
