PROJ = top

PIN_DEF = top.pcf
DEVICE = up5k
PACKAGE = sg48
FREQ = 13
ADD_SRC = lcd.v
TEST_SRC = test_lcd.v

IMAGE = docker.io/davidsiaw/yosys-docker:latest
NODE_IMAGE = docker.io/node:lts-slim
HIDRAW := $(shell grep -l 1D50 /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null | head -1 | cut -d/ -f5)
DEVICE_ARGS = $(if $(HIDRAW),--device /dev/$(HIDRAW) --group-add keep-groups)
PODMAN = podman run --rm -v "$(CURDIR):/work" -w /work $(IMAGE)
PODMAN_NODE = podman run --rm -v "$(CURDIR):/work" -w /work $(NODE_IMAGE)
PODMAN_DEV = podman run --rm -v "$(CURDIR):/work" -w /work $(DEVICE_ARGS) $(IMAGE)

include ./main.mk
