#!/bin/bash

podman run --rm -v "$(pwd):/work" -w /work docker.io/davidsiaw/yosys-docker:latest \
    sh -c "yosys -p 'synth_ice40 -top TOP -json top.json' top.v lcd.v && \
           nextpnr-ice40 --up5k --package sg48 --json top.json --pcf top.pcf --asc top.asc && \
           icepack top.asc top.bin"

