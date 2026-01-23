local util = require("sops.util")

local M = {
  disabled = false,
}

local DEFAULT_SUPPORTED_FILE_FORMATS = {
  "*.yaml",
  "*.yml",
  "*.json",
  -- Assumes the `filetype` is set to `json`.
  "*.dockerconfigjson",
  "*.toml",
}

local supported_file_formats = {}
local buffers = {}
local manage_buffer

local function invalidate(buffer)
  buffer.token = buffer.token + 1
end

local function is_current(bufnr, buffer, token)
  return buffers[bufnr] == buffer
    and buffer.token == token
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
end

local function notify_error(message)
  -- External-process callbacks cannot return errors to the initiating command. Keep the buffer modified and report the
  -- failure at the editor boundary so the operation is visible and can be retried.
  vim.notify(message, vim.log.levels.ERROR)
end

local function stop_managing(bufnr, buffer, restore_buftype)
  if buffers[bufnr] ~= buffer then
    return
  end

  invalidate(buffer)
  vim.api.nvim_clear_autocmds({ group = buffer.augroup })
  buffers[bufnr] = nil
  if restore_buftype and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_option_value("buftype", "", { buf = bufnr })
  end
end

local function text_to_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function decrypt_buffer(bufnr, buffer)
  invalidate(buffer)
  local token = buffer.token
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local input_type = filetype
  local output_type = filetype
  if filetype == "toml" then -- sops doesn't support toml yet, but can be encrypted as binary for a work around
      input_type = "binary"
      output_type = "binary"
  end
  vim.system(
    { "sops", "--decrypt", "--input-type", input_type, "--output-type", output_type, path },
    { cwd = vim.fs.dirname(path), text = true },
    function(result)
      vim.schedule(function()
        if not is_current(bufnr, buffer, token) then
          return
        end
        if vim.api.nvim_buf_get_name(bufnr) ~= path then
          buffer.status = "unsafe"
          notify_error("Refusing to apply decryption after buffer path changed: " .. path)
          return
        end
        if result.code ~= 0 then
          stop_managing(bufnr, buffer, true)
          notify_error("Failed to decrypt " .. path .. ": " .. (result.stderr or "unknown sops error"))
          return
        end
        if vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
          buffer.status = "unsafe"
          notify_error("Refusing to replace buffer changed while decrypting: " .. path)
          return
        end

        local old_undo_levels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr })
        vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
        vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text_to_lines(result.stdout or ""))
        vim.api.nvim_set_option_value("undolevels", old_undo_levels, { buf = bufnr })
        vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
        buffer.status = "ready"
        vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
      end)
    end
  )
end

local function schedule_decryption(bufnr, buffer)
  local token = buffer.token
  vim.schedule(function()
    if is_current(bufnr, buffer, token) and buffer.status == "decrypting" and not M.disabled then
      decrypt_buffer(bufnr, buffer)
    end
  end)
end

local function editor_script_path()
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"):sub(1, -4)
  return vim.fs.joinpath(plugin_root, "scripts", "sops-editor.sh")
end

-- Starts SOPS against a snapshot of the current plaintext. The callback still runs if the buffer is unloaded so the
-- temporary plaintext is always removed.
local function start_encryption(bufnr, buffer, callback)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local editor_script = editor_script_path()
  if vim.fn.filereadable(editor_script) == 0 then
    return false, "SOPS editor script not found: " .. editor_script
  end

  local temp_file = vim.fn.tempname()
  if vim.fn.writefile(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), temp_file) ~= 0 then
    vim.fn.delete(temp_file)
    return false, "Failed to write temporary plaintext for " .. path
  end

  local token = buffer.token
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  vim.system({ "sops", "edit", path }, {
    cwd = vim.fs.dirname(path),
    env = {
      SOPS_EDITOR = editor_script,
      SOPS_NVIM_TEMP_FILE = temp_file,
    },
    text = true,
  }, function(result)
    vim.schedule(function()
      if vim.fn.delete(temp_file) ~= 0 then
        notify_error("Failed to remove temporary plaintext file: " .. temp_file)
      end

      local active = is_current(bufnr, buffer, token)
      callback({
        active = active,
        path_unchanged = active and vim.api.nvim_buf_get_name(bufnr) == path,
        success = result.code == 0,
        error = result.code ~= 0
            and ("SOPS failed to edit " .. path .. ": " .. (result.stderr or "unknown sops error"))
          or nil,
        changedtick = changedtick,
      })
    end)
  end)

  return true
end

local function write_buffer(bufnr, buffer)
  if M.disabled or buffers[bufnr] ~= buffer then
    error("Refusing to write a SOPS buffer that is not actively managed", 0)
  end
  if buffer.status ~= "ready" then
    error("Cannot write a SOPS buffer while it is " .. buffer.status, 0)
  end
  if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    vim.notify("Skipping sops encryption. File has not been modified", vim.log.levels.INFO)
    return
  end

  buffer.status = "writing"
  invalidate(buffer)
  local started, start_error = start_encryption(bufnr, buffer, function(result)
    if not result.active then
      return
    end

    buffer.status = "ready"
    if not result.path_unchanged then
      notify_error("SOPS wrote the original path after the buffer was renamed; the buffer remains modified")
      return
    end
    if not result.success then
      notify_error(result.error)
      return
    end

    if vim.api.nvim_buf_get_changedtick(bufnr) == result.changedtick then
      vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
    end
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
  end)

  if not started then
    buffer.status = "ready"
    error(start_error, 0)
  end
end

local function is_supported_path(path)
  local filename = vim.fs.basename(path)
  for _, pattern in ipairs(supported_file_formats) do
    if vim.fn.match(filename, vim.fn.glob2regpat(pattern)) ~= -1 then
      return true
    end
  end
  return false
end

local function scan_loaded_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" and is_supported_path(path) then
        manage_buffer(bufnr)
      end
    end
  end
end

local function toggle_warning(message)
  vim.notify("SopsToggle: " .. message, vim.log.levels.WARN)
  return false
end

local function disable()
  local stale = {}
  local targets = {}

  for bufnr, buffer in pairs(buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      table.insert(stale, { bufnr = bufnr, buffer = buffer })
    else
      local path = vim.api.nvim_buf_get_name(bufnr)
      if buffer.status == "decrypting" then
        return toggle_warning("wait for decryption to finish: " .. path)
      elseif buffer.status == "writing" then
        return toggle_warning("wait for encryption to finish: " .. path)
      elseif buffer.status == "unsafe" then
        return toggle_warning("reload buffer before disabling: " .. path)
      elseif buffer.status ~= "ready" then
        error("sops.nvim: unexpected buffer status: " .. buffer.status, 0)
      end
      if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
        return toggle_warning("save changes before disabling: " .. path)
      end
      if not vim.api.nvim_get_option_value("modifiable", { buf = bufnr }) then
        return toggle_warning("buffer is not modifiable: " .. path)
      end

      -- Read every ciphertext before changing any buffer. A read failure aborts the command without a partial toggle.
      table.insert(targets, {
        bufnr = bufnr,
        buffer = buffer,
        ciphertext = vim.fn.readfile(path),
      })
    end
  end

  for _, entry in ipairs(stale) do
    stop_managing(entry.bufnr, entry.buffer, true)
  end
  for _, target in ipairs(targets) do
    stop_managing(target.bufnr, target.buffer, true)
    vim.api.nvim_buf_set_lines(target.bufnr, 0, -1, false, target.ciphertext)
    vim.api.nvim_set_option_value("modified", false, { buf = target.bufnr })
  end

  M.disabled = true
  for _, target in ipairs(targets) do
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = target.bufnr })
  end
  return true
end

manage_buffer = function(bufnr)
  if M.disabled or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local existing = buffers[bufnr]
  if existing then
    if existing.status ~= "unsafe" or not util.is_sops_encrypted(bufnr) then
      return
    end
    stop_managing(bufnr, existing, true)
  elseif not util.is_sops_encrypted(bufnr) then
    return
  end

  local buffer = {
    augroup = vim.api.nvim_create_augroup("sops.nvim.buffer." .. bufnr, { clear = true }),
    token = 0,
    status = "decrypting",
  }
  buffers[bufnr] = buffer

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    buffer = bufnr,
    group = buffer.augroup,
    callback = function()
      stop_managing(bufnr, buffer, true)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    group = buffer.augroup,
    callback = function()
      write_buffer(bufnr, buffer)
    end,
  })

  -- Neovim increments changedtick once more after BufReadPost. Defer so the stale-result guard sees the stable tick.
  schedule_decryption(bufnr, buffer)
end

local function enable()
  M.disabled = false
  scan_loaded_buffers()
  return true
end

M.toggle = function()
  if M.disabled then
    return enable()
  end
  return disable()
end

M.setup = function(opts)
  opts = opts or {}
  if opts.disabled ~= nil then
    if type(opts.disabled) ~= "boolean" then
      error("sops.nvim: opts.disabled must be a boolean", 0)
    end
    if opts.disabled ~= M.disabled and next(buffers) ~= nil then
      error("sops.nvim: use SopsToggle to change disabled state while SOPS buffers are managed", 0)
    end
    M.disabled = opts.disabled
  end

  -- Rebuild configuration and the augroup so repeated setup calls (including Lazy's automatic setup) are idempotent.
  supported_file_formats = vim.deepcopy(DEFAULT_SUPPORTED_FILE_FORMATS)
  for _, format in ipairs(opts.supported_file_formats or {}) do
    if not vim.tbl_contains(supported_file_formats, format) then
      table.insert(supported_file_formats, format)
    end
  end

  vim.api.nvim_create_user_command("SopsToggle", M.toggle, { force = true })
  local group = vim.api.nvim_create_augroup("sops.nvim", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = supported_file_formats,
    callback = function(args)
      manage_buffer(args.buf)
    end,
  })
end

return M
