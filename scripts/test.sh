#!/usr/bin/env bash

# Runs the plenary.nvim test suite under tests/atlas/, cloning plenary
# into .deps/ on first run.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

deps=.deps
mkdir -p "$deps"
if [[ ! -d "$deps/plenary.nvim" ]]; then
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$deps/plenary.nvim"
fi

nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/atlas { minimal_init = 'tests/minimal_init.lua' }"
