#!/bin/bash

HIDRAW=/dev/$(grep -l 1D50 /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null | head -1 | cut -d/ -f5)

DEVICE_ARGS=""
if [ -c "$HIDRAW" ]; then
    DEVICE_ARGS="--device $HIDRAW --group-add keep-groups"
fi

podman run --rm \
           -v "$(pwd):/work" \
           -w /work \
           $DEVICE_ARGS \
           docker.io/davidsiaw/yosys-docker:latest \
    sh -c "iverilog -g2012 -o test_lcd.vvp test_lcd.v lcd.v && \
           vvp test_lcd.vvp && \
           python3 vcd2svg.py test_lcd.vcd --output-dir waveforms && \
           yosys -p 'synth_ice40 -top TOP -json top.json' top.v lcd.v && \
           nextpnr-ice40 --up5k --package sg48 --json top.json --pcf top.pcf --asc top.asc && \
           icepack top.asc top.bin && \
	   if command -v icesprog >/dev/null; then icesprog top.bin; else echo 'Skipping flash: device not available'; fi"
