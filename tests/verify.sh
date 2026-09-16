#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

nvim --headless -u NONE -l tests/run.lua
bash tests/java_spec.sh
git diff --check
