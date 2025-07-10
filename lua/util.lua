local M = {}

local SOPS_MARKER_BYTES = {
  ["yaml"] = "mac: ENC[",
  ["yaml.helm-values"] = "mac: ENC[",
  ["json"] = '"mac": "ENC[',
}

M.is_sops_encrypted = function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  local marker = SOPS_MARKER_BYTES[filetype]
  if not marker then
    return false
  end

  for _, line in ipairs(lines) do
    if string.find(line, marker, nil, true) then
      return true
    end
  end
end

return M
