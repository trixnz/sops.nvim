local util = require("util")

---@class SopsModule
local M = {}

-- Default file formats supported by the plugin
local DEFAULT_SUPPORTED_FILE_FORMATS = {
  "*.yaml",
  "*.yml",
  "*.json",
  -- Assumes the `filetype` is set to `json`
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
      vim.schedule(function()
        if out.code ~= 0 then
          vim.notify("Failed to decrypt file", vim.log.levels.WARN)

          return
        end

        local decrypted_lines = vim.fn.split(out.stdout, "\n", false)

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
    end
  )
end

---@param bufnr number
local function sops_encrypt_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fs.dirname(path)

  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
  local editor_script = vim.fs.joinpath(plugin_root, "scripts", "sops-editor.sh")

  if vim.fn.filereadable(editor_script) == 0 then
    vim.notify("SOPS editor script not found: " .. editor_script, vim.log.levels.WARN)

    return
  end

  local temp_file = vim.fn.tempname()
  local function cleanup()
    vim.fn.delete(temp_file)
  end

  local plaintext_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local success = vim.fn.writefile(plaintext_lines, temp_file) == 0

  if not success then
    cleanup()
    vim.notify("Failed to write temp file", vim.log.levels.WARN)

    return
  end

  vim.system({ "sops", "edit", path }, {
    cwd = cwd,
    env = {
      SOPS_EDITOR = editor_script,
      SOPS_NVIM_TEMP_FILE = temp_file,
    },
    text = true,
  }, function(out)
    vim.schedule(function()
      cleanup()

      if out.code ~= 0 then
        vim.notify("SOPS failed to edit file: " .. (out.stderr or ""), vim.log.levels.WARN)
        return
      end

      -- Mark the file as not modified
      vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

      -- Run BufReadPost autocmds since the buffer contents have changed
      vim.api.nvim_exec_autocmds("BufReadPost", {
        buffer = bufnr,
      })
    end)
  end)
end

---@param opts table
M.setup = function(opts)
  opts = opts or {}

  -- Allow overriding or appending to the supported file formats
  if opts.supported_file_formats then
    for _, format in ipairs(opts.supported_file_formats) do
      table.insert(SUPPORTED_FILE_FORMATS, format)
    end
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
