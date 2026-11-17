#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# pkg-config output intentionally supplies separate compiler arguments.
# shellcheck disable=SC2046
cc -std=c11 -O2 -Wall -Wextra -Werror native/viewer.c -o native/malachite-opal-viewer $(pkg-config --cflags --libs gtk+-3.0 epoxy) -lm
