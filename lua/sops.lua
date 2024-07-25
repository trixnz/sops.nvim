local util = require("util")

---@class SopsModule
local M = {}

local DECRYPTED_FILE_SUFFIX = ".decrypted~"
local SUPPORTED_FILE_FORMATS = {
  "*.yaml",
  "*.json",
}

---@param bufnr number
local function delete_decrypted_file(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local outpath = path .. DECRYPTED_FILE_SUFFIX

  vim.fn.delete(outpath)
end

---@param bufnr number
local function sops_decrypt_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fs.dirname(path)
  local decrypted_path = path .. DECRYPTED_FILE_SUFFIX

  vim.system({
    "sops",
    "--output",
    decrypted_path,
    "--decrypt",
    path,
  }, { cwd = cwd }, function(out)
    if out.code ~= 0 then
      vim.notify("Failed to decrypt file", vim.log.levels.WARN)

      -- Make sure the decrypted file is deleted, even if it failed. We don't want to leave decrypted files around.
      delete_decrypted_file(bufnr)

      return
    end

    vim.schedule(function()
      local decrypted_lines = vim.fn.readfile(decrypted_path)
      delete_decrypted_file(bufnr)

      -- Make this buffer writable only through our auto command
      vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })

      -- Swap the buffer contents with the decrypted contents
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, decrypted_lines)

      -- Clear the undo history
      local old_undo_levels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr })
      vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr })
      vim.cmd('exe "normal a \\<BS>\\<Esc>"')
      vim.api.nvim_set_option_value("undolevels", old_undo_levels, { buf = bufnr })

      -- Mark the file as not modified
      vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

      -- Run BufReadPost autocmds since the buffer contents have changed
      vim.api.nvim_exec_autocmds("BufReadPost", {
        buffer = bufnr,
      })
    end)
  end)
end

---@param bufnr number
local function sops_encrypt_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fs.dirname(path)
  local decrypted_path = path .. DECRYPTED_FILE_SUFFIX

  -- Write out the buffer to the decrypted file
  local plaintext_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if vim.fn.writefile(plaintext_lines, decrypted_path) ~= 0 then
    vim.notify("Failed to write decrypted file", vim.log.levels.WARN)

    return
  end

  -- We can't use async here, because scheduling the modified flag later seems to cause some weird undo quirks,
  -- and we obviously can't set the modified flag until we know the outcome of running SOPs.
  local out = vim
    .system({
      "sops",
      "--filename-override",
      path,
      "--output",
      path,
      "--encrypt",
      decrypted_path,
    }, { cwd = cwd })
    :wait()

  delete_decrypted_file(bufnr)

  if out.code ~= 0 then
    vim.notify("Failed to encrypt file: " .. out.stderr, vim.log.levels.WARN)

    return
  end

  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
end

M.setup = function()
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
          -- Clean up our autocmds
          vim.api.nvim_clear_autocmds({
            buffer = bufnr,
            group = au_group,
          })
        end,
      })

      vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        group = au_group,
        callback = function()
          -- Saving the file will always result in the SOPS-encrypted file changing, so there's no reason to save the
          -- file if the decrypted contents have not changed. Saves on false positive changes.
          if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
            vim.notify("Skipping sops encryption. Not modified", vim.log.levels.INFO)
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
