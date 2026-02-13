#!/bin/bash

HIDRAW=/dev/$(grep -l 1D50 /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null | head -1 | cut -d/ -f5)

podman run --rm \
           -v "$(pwd):/work" \
           -w /work \
           --device "$HIDRAW" \
           --group-add keep-groups \
           docker.io/davidsiaw/yosys-docker:latest \
    sh -c "yosys -p 'synth_ice40 -top TOP -json top.json' top.v lcd.v && \
           nextpnr-ice40 --up5k --package sg48 --json top.json --pcf top.pcf --asc top.asc && \
           icepack top.asc top.bin && \
	   icesprog top.bin"
