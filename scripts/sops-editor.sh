#!/usr/bin/env bash
# SOPS editor script for sops.nvim
# This script copies the content from SOPS_NVIM_TEMP_FILE to the file specified by sops
# Usage: SOPS_NVIM_TEMP_FILE=/path/to/temp/file sops-editor.sh /path/to/sops/temp/file

# Credit for this hack goes to the vscode-sops extension.
# https://github.com/signageos/vscode-sops/blob/9cc9a3f83a7328ec257ca7e5586b3b790b3f8410/src/extension.ts#L27-L32

if [ -z "$SOPS_NVIM_TEMP_FILE" ]; then
  echo "Error: SOPS_NVIM_TEMP_FILE environment variable not set" >&2
  exit 1
fi

if [ ! -f "$SOPS_NVIM_TEMP_FILE" ]; then
  echo "Error: SOPS_NVIM_TEMP_FILE does not exist: $SOPS_NVIM_TEMP_FILE" >&2
  exit 1
fi

if [ -z "$1" ]; then
  echo "Error: No target file specified" >&2
  exit 1
fi

cat "$SOPS_NVIM_TEMP_FILE" >"$1"

