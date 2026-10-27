cmake_minimum_required(VERSION 3.16)

# Network helper from ESP-IDF's examples. It connects over Wi-Fi on the real
# board or over the emulated Ethernet port in QEMU, chosen by sdkconfig.
# It is a stand-in until the product has its own Wi-Fi provisioning.
set(EXTRA_COMPONENT_DIRS $ENV{IDF_PATH}/examples/common_components/protocol_examples_common)

# The firmware version comes from version.txt in this folder.
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp32-ota)
