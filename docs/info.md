<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A UART receiver (115200 baud, 8N1, on `ui[3]`) sets the duty cycle of 15 PWM outputs. A byte with bit 7 set selects a
channel (bits 3:0, channels 0 to 14). The next byte with bit 7 clear sets that channel's duty, 0 to 127, stretched to 0 to 255.
Every received byte is echoed back on TX (`uio[0]`).

The design runs from a 100 MHz clock. Each PWM output runs at 100 MHz / 512, about 195 kHz, with 256 duty steps.
All channels are off after reset.

## How to test

Connect a 3.3 V USB-UART adapter: its TX to `ui[3]` and its RX to `uio[0]`. Set it to 115200 baud, 8N1. Send `0x80 0x7F` to turn
channel 0 fully on, or `0x82 0x40` to set channel 2 to about 50%. Each byte you send is echoed back.

## External hardware

A USB-UART adapter and up to 15 LEDs (with series resistors) on `uo[7:0]` and `uio[7:1]`.
