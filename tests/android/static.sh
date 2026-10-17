#!/usr/bin/env bash
set -euo pipefail

readelf -d "$PHP_BINARIES" | grep -q 'There is no dynamic section'
