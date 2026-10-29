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

# diffview.nvim, pinned so review/annotate tests run against a known version.
diffview_rev=4516612fe98ff56ae0415a259ff6361a89419b0a
if [[ ! -d "$deps/diffview.nvim" ]]; then
  git clone -q https://github.com/sindrets/diffview.nvim "$deps/diffview.nvim"
fi
git -C "$deps/diffview.nvim" checkout -q "$diffview_rev"

nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/atlas { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 300000 }"
