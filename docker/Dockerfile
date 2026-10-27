# Build environment for the ESP32 OTA reference implementation.
#
# Espressif's official ESP-IDF image already contains the ESP-IDF tools,
# the Python environment and QEMU (qemu-system-xtensa) with its libraries.
# We pin one ESP-IDF version so every laptop builds the same binaries.
ARG IDF_VERSION=v5.5.6
FROM espressif/idf:${IDF_VERSION}

# Small extras used by the factory scripts.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq xxd \
    && rm -rf /var/lib/apt/lists/*

# The repository is mounted here by the Makefile.
WORKDIR /project

# Let git work inside the mounted repository even when the container user
# differs from the owner of the files.
ENV IDF_GIT_SAFE_DIR=/project

# The base image's entrypoint sources $IDF_PATH/export.sh, so idf.py,
# esptool and qemu-system-xtensa are on PATH in every command.
