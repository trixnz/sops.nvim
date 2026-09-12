local M = {}

local SOPS_MARKER_BYTES = {
  ["yaml"] = "mac: ENC[",
  ["yaml.helm-values"] = "mac: ENC[",
  ["json"] = '"mac": "ENC[',
  ["binary"] = '"mac": "ENC[',
  ["toml"] = '"mac": "ENC[',
  ["env"] = "sops_mac=ENC[",
}

local is_conf_file = function(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local extension = vim.fn.fnamemodify(path, ":e")
  return extension == "conf"
end

M.is_sops_encrypted = function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  local marker
  if is_conf_file(bufnr) then
    marker = SOPS_MARKER_BYTES.binary
  else
    marker = SOPS_MARKER_BYTES[filetype]
  end
  if not marker then
    return false
  end

  for _, line in ipairs(lines) do
    if string.find(line, marker, nil, true) then
      return true
    end
  end
end

M.get_sops_format = function(bufnr)
  local nvim_filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local sops_filetype = nvim_filetype

  if is_conf_file(bufnr) then -- conf does not have a standard format, so binary is assumed for maximum compatibility
      sops_filetype = "binary"
  elseif nvim_filetype == "env" then -- neovim refers to dotenv files as 'env'
      sops_filetype = "dotenv" -- sops refers to dotenv files as 'dotenv'
  elseif nvim_filetype == "toml" then -- sops doesn't support toml yet, but can be encrypted as binary for a work around
      sops_filetype = "binary"
  end
  return sops_filetype
end

return M
