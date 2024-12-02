local util = require("util")

---@class SopsModule
local M = {}

local DEFAULT_SUPPORTED_FILE_FORMATS = {
  "*.yaml",
  "*.yml",
  "*.json",
  "*.dockerconfigjson",
}

---@type table
local SUPPORTED_FILE_FORMATS = vim.deepcopy(DEFAULT_SUPPORTED_FILE_FORMATS)

---@param bufnr number
local function sops_decrypt_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fs.dirname(path)

  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  vim.system(
    { "sops", "--decrypt", "--input-type", filetype, "--output-type", filetype, path },
    { cwd = cwd, text = true },
    function(out)
      if out.code ~= 0 then
        vim.notify("Failed to decrypt file", vim.log.levels.WARN)
        return
      end

      vim.schedule(function()
        local decrypted_lines = vim.fn.split(out.stdout, "\n", false)
        vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, decrypted_lines)

        -- Clear the undo history
        local old_undo_levels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr })
        vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr })
        vim.cmd('exe "normal a \\<BS>\\<Esc>"')
        vim.api.nvim_set_option_value("undolevels", old_undo_levels, { buf = bufnr })

        vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
        vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
      end)
    end
  )
end

---@param bufnr number
local function sops_encrypt_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fs.dirname(path)

  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  local channel = vim.fn.jobstart({
    "sops",
    "--filename-override",
    path,
    "--output",
    path,
    "--input-type",
    filetype,
    "--output-type",
    filetype,
    "--encrypt",
    "/dev/stdin",
  }, {
    cwd = cwd,
    pty = true,
  })

  if channel <= 0 then
    vim.notify("Failed to start job", vim.log.levels.WARN)
    return
  end

  local plaintext_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.fn.chansend(channel, plaintext_lines)
  vim.fn.chansend(channel, "\r\004")

  local code = vim.fn.jobwait({ channel }, 1000)[1]
  if code < 0 then
    vim.notify("Failed to run job", vim.log.levels.WARN)
    return
  end

  if code ~= 0 then
    vim.notify("SOPs failed to encrypt file: errno " .. code, vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
end

M.setup = function(opts)
  opts = opts or {}
  if opts.supported_file_formats then
    for _, format in ipairs(opts.supported_file_formats) do
      table.insert(SUPPORTED_FILE_FORMATS, format)
    end
    vim.notify("SOPS.nvim configuration updated with additional patterns.", vim.log.levels.INFO)
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "FileReadPost" }, {
    pattern = SUPPORTED_FILE_FORMATS,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if not util.is_sops_encrypted(bufnr) then
        return
      end

      local au_group = vim.api.nvim_create_augroup("sops.nvim" .. bufnr, { clear = true })

      vim.api.nvim_create_autocmd("BufDelete", {
        buffer = bufnr,
        group = au_group,
        callback = function()
          vim.api.nvim_clear_autocmds({ buffer = bufnr, group = au_group })
        end,
      })

      vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        group = au_group,
        callback = function()
          if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
            vim.notify("Skipping sops encryption. File has not been modified", vim.log.levels.INFO)
            return
          end
          sops_encrypt_buffer(bufnr)
        end,
      })

      sops_decrypt_buffer(bufnr)
    end,
  })
end

return M
