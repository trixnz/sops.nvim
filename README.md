# sops.nvim

sops.nvim is a Neovim plugin for working with SOPS encrypted files. It provides
transparent decryption and encryption of SOPS files when they are opened and
saved.

You can toggle the plugin with the `SopsToggle` command. All open SOPS buffers must be fully loaded and saved before
disabling; the command will not write modified buffers automatically.

## Supported Files

- YAML
- JSON
- TOML
- ENV

## Requirements

You are required to have [sops](https://github.com/getsops/sops)
available on your path

## SSH Key Authentication

sops can decrypt using an SSH ed25519/RSA key as an age identity via the
`SOPS_AGE_SSH_PRIVATE_KEY_FILE` or `SOPS_AGE_SSH_PRIVATE_KEY_CMD` environment
variable. If that key is passphrase-protected, sops.nvim will prompt for the
passphrase with `vim.fn.inputsecret()` instead of failing, since sops itself
can only read such a passphrase from a real terminal.

## Installation

### Lazy

```lua
{
    "trixnz/sops.nvim",
    lazy = false,
    opts = {
        disabled = false,
    }
}
```

### Packer

```lua
use {
  "trixnz/sops.nvim"
}
```

## Acknowledgements

[vscode-sops](https://github.com/signageos/vscode-sops)
