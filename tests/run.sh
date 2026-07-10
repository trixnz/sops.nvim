#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for test_name in setup real_open unload stale_decrypt pending_edit rename failed_encrypt disable; do
  SOPS_NVIM_TEST="$test_name" nvim --headless -u NONE \
    "+lua dofile('tests/sops_spec.lua')" \
    +qa!
done
