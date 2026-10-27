# ESP32 OTA reference implementation: one command per step.
# Every target runs inside the Docker image, so only Docker is needed on the host.
#
#   make image                   build the Docker image (once)
#   make shell                   open a shell in the container
#   make build                   build bootloader, partition table and firmware for QEMU
#   make factory SERIAL=SIM-0001 provision a new simulated device
#   make run SERIAL=SIM-0001     boot that device in QEMU (Ctrl-] to exit)
#   make new-device SERIAL=...   delete a simulated device so it can be provisioned again
#   make clean                   delete build output

IDF_VERSION ?= v5.5.6
IMAGE       ?= ota-platforms/esp-idf:$(IDF_VERSION)
SERIAL      ?= SIM-0001
PROFILE     ?= qemu

PROJECT_DIR := firmware/esp32-ota
BUILD_DIR   := /project/build/$(PROFILE)
IDF_ARGS    := -C $(PROJECT_DIR) -B $(BUILD_DIR) \
               -D SDKCONFIG=$(BUILD_DIR)/sdkconfig \
               -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.$(PROFILE)"

# Interactive flags only when a terminal is attached (so CI can run targets too).
TTY := $(shell [ -t 0 ] && echo -it)

# Run as the host user so build files are not owned by root.
DOCKER_RUN := docker run --rm $(TTY) \
              -v "$(CURDIR)":/project -w /project \
              -u $(shell id -u):$(shell id -g) -e HOME=/tmp \
              $(IMAGE)

.PHONY: image shell build factory run new-device clean

image:
	docker build --build-arg IDF_VERSION=$(IDF_VERSION) -t $(IMAGE) docker

shell:
	$(DOCKER_RUN) bash

build:
	$(DOCKER_RUN) idf.py $(IDF_ARGS) build

factory: build
	$(DOCKER_RUN) bash factory/provision.sh $(SERIAL) $(PROFILE)

run:
	@test -f devices/$(SERIAL)/flash.bin || { echo "No device $(SERIAL). Run: make factory SERIAL=$(SERIAL)"; exit 1; }
	$(DOCKER_RUN) idf.py $(IDF_ARGS) qemu \
		--flash-file /project/devices/$(SERIAL)/flash.bin \
		--efuse-file /project/devices/$(SERIAL)/efuse.bin \
		monitor

new-device:
	rm -rf devices/$(SERIAL) factory/records/$(SERIAL).json

clean:
	rm -rf build
