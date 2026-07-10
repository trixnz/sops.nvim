local repo = vim.fn.getcwd()
vim.opt.runtimepath:append(repo)

local function fail(message)
  error(message, 0)
end

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message or "values differ") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

local function assert_true(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function wait_for_scheduled_callbacks()
  vim.wait(100, function()
    return false
  end, 10)
end

local function encrypted_lines(name)
  return {
    "name: " .. name,
    "sops:",
    "  mac: ENC[AES256_GCM,data:ciphertext]",
  }
end

local function write_encrypted_file(path, name)
  assert_equal(0, vim.fn.writefile(encrypted_lines(name), path), "failed to create fixture")
end

local pending_system_calls = {}
local notifications = {}
-- luacheck: push ignore 122
vim.system = function(command, options, callback)
  table.insert(pending_system_calls, {
    command = command,
    options = options,
    callback = callback,
  })
  return {}
end
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
-- luacheck: pop

local function assert_toggle_warning(sops, expected_message)
  local notification_count = #notifications
  local ok, result = pcall(sops.toggle)
  assert_true(ok, "expected toggle warning, got error: " .. tostring(result))
  assert_equal(false, result, "rejected toggle did not return false")
  assert_equal(notification_count + 1, #notifications, "toggle did not emit one warning")
  local notification = notifications[#notifications]
  assert_equal(vim.log.levels.WARN, notification.level, "toggle refusal was not a warning")
  assert_true(
    string.find(notification.message, expected_message, 1, true),
    "unexpected warning: " .. notification.message
  )
end

local function take_system_call(expected_operation)
  if #pending_system_calls == 0 then
    vim.wait(100, function()
      return #pending_system_calls > 0
    end, 10)
  end
  local call = table.remove(pending_system_calls, 1)
  assert_true(call, "expected a pending vim.system call")
  assert_equal(expected_operation, call.command[2], "unexpected sops operation")
  return call
end

local function open_encrypted_file(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_option_value("filetype", "yaml", { buf = bufnr })
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
  return bufnr
end

local function complete_decryption(plaintext)
  local call = take_system_call("--decrypt")
  call.callback({ code = 0, stdout = plaintext .. "\n", stderr = "" })
  wait_for_scheduled_callbacks()
end

local function complete_encryption(path, name)
  local call = take_system_call("edit")
  assert_equal(path, call.command[3], "encrypted the wrong file")
  write_encrypted_file(path, name)
  call.callback({ code = 0, stdout = "", stderr = "" })
  wait_for_scheduled_callbacks()
end

local function count_buffer_write_autocmds(bufnr)
  return #vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = bufnr })
end

local function test_setup_is_idempotent()
  local sops = require("sops")
  sops.setup({ supported_file_formats = { "*.env" } })
  local first_count = #vim.api.nvim_get_autocmds({ group = "sops.nvim" })

  sops.setup({ supported_file_formats = { "*.env" } })
  local second_count = #vim.api.nvim_get_autocmds({ group = "sops.nvim" })

  assert_true(first_count > 0, "setup did not register read autocmds")
  assert_equal(first_count, second_count, "repeated setup duplicated read autocmds")
  assert_equal(
    0,
    #vim.api.nvim_get_autocmds({ group = "sops.nvim", event = "FileReadPost" }),
    "FileReadPost must not decrypt the destination of :read"
  )
end

local function test_decrypt_started_by_real_bufreadpost_is_not_rejected()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/real-open.yaml"
  write_encrypted_file(path, "real-open")

  vim.api.nvim_create_autocmd("BufReadPre", {
    pattern = "*.yaml",
    callback = function(args)
      vim.api.nvim_set_option_value("filetype", "yaml", { buf = args.buf })
    end,
  })

  local sops = require("sops")
  sops.setup()
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  complete_decryption("secret: plaintext")

  assert_equal({ "secret: plaintext" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_equal("acwrite", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))
  assert_equal(1, count_buffer_write_autocmds(bufnr))

  vim.fn.delete(directory, "rf")
end

local function test_unload_tears_down_buffer_management()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/unload.yaml"
  write_encrypted_file(path, "unload")

  local sops = require("sops")
  sops.setup()
  local bufnr = open_encrypted_file(path)
  complete_decryption("secret: plaintext")
  assert_equal("acwrite", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))

  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  vim.cmd("bunload " .. bufnr)
  assert_true(vim.api.nvim_buf_is_valid(bufnr), "bunload unexpectedly deleted the buffer")
  assert_true(not vim.api.nvim_buf_is_loaded(bufnr), "buffer was not unloaded")
  assert_equal("", vim.api.nvim_get_option_value("buftype", { buf = bufnr }), "buftype survived BufUnload")
  assert_equal(0, count_buffer_write_autocmds(bufnr), "BufWriteCmd survived BufUnload")

  sops.toggle()
  assert_true(sops.disabled, "stale unloaded management prevented disable")

  vim.fn.delete(directory, "rf")
end

local function test_disable_rejects_pending_decryption()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/pending.yaml"
  write_encrypted_file(path, "pending")

  local sops = require("sops")
  sops.setup()
  local bufnr = open_encrypted_file(path)
  local decrypt_call = take_system_call("--decrypt")

  assert_toggle_warning(sops, "wait for decryption to finish")
  assert_true(not sops.disabled, "failed disable changed plugin state")

  decrypt_call.callback({ code = 0, stdout = "secret: plaintext\n", stderr = "" })
  wait_for_scheduled_callbacks()
  assert_equal({ "secret: plaintext" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

  sops.toggle()
  assert_true(sops.disabled, "disable failed after decryption completed")
  assert_equal(encrypted_lines("pending"), vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_equal("", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))
  assert_equal(0, count_buffer_write_autocmds(bufnr))

  sops.toggle()
  complete_decryption("secret: enabled again")
  assert_equal({ "secret: enabled again" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_equal("acwrite", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))
  assert_equal(1, count_buffer_write_autocmds(bufnr))

  vim.fn.delete(directory, "rf")
end

local function test_edited_pending_decryption_requires_reload()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/edited-during-decrypt.yaml"
  write_encrypted_file(path, "pending-edit")

  local sops = require("sops")
  sops.setup()
  local bufnr = open_encrypted_file(path)
  local decrypt_call = take_system_call("--decrypt")
  assert_toggle_warning(sops, "wait for decryption to finish")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "secret: user edit" })

  decrypt_call.callback({ code = 0, stdout = "secret: decrypted\n", stderr = "" })
  wait_for_scheduled_callbacks()

  assert_true(not sops.disabled, "disable committed after pending decryption rejected user edits")
  assert_equal({ "secret: user edit" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_true(vim.api.nvim_get_option_value("modified", { buf = bufnr }), "user edit was marked saved")
  assert_toggle_warning(sops, "reload buffer before disabling")

  -- Reloading ciphertext is the explicit recovery path and makes the buffer manageable again.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("edit!")
  end)
  complete_decryption("secret: recovered")
  assert_equal({ "secret: recovered" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_equal("acwrite", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))
  sops.toggle()
  assert_true(sops.disabled, "disable did not recover after reloading the unsafe buffer")

  vim.fn.delete(directory, "rf")
end

local function test_renamed_buffers_reject_async_results()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local decrypt_path = directory .. "/decrypt.yaml"
  local encrypt_path = directory .. "/encrypt.yaml"
  write_encrypted_file(decrypt_path, "decrypt")
  write_encrypted_file(encrypt_path, "encrypt")

  local sops = require("sops")
  sops.setup()

  local decrypt_bufnr = open_encrypted_file(decrypt_path)
  local decrypt_call = take_system_call("--decrypt")
  local renamed_decrypt_path = directory .. "/decrypt-renamed.yaml"
  vim.api.nvim_buf_set_name(decrypt_bufnr, renamed_decrypt_path)
  decrypt_call.callback({ code = 0, stdout = "secret: wrong file\n", stderr = "" })
  wait_for_scheduled_callbacks()
  assert_equal(encrypted_lines("decrypt"), vim.api.nvim_buf_get_lines(decrypt_bufnr, 0, -1, false))
  assert_equal("", vim.api.nvim_get_option_value("buftype", { buf = decrypt_bufnr }))
  assert_equal(1, count_buffer_write_autocmds(decrypt_bufnr))

  local encrypt_bufnr = open_encrypted_file(encrypt_path)
  complete_decryption("secret: original")
  vim.api.nvim_buf_set_lines(encrypt_bufnr, 0, -1, false, { "secret: changed" })
  vim.api.nvim_buf_call(encrypt_bufnr, function()
    vim.cmd.write()
  end)
  local encrypt_call = take_system_call("edit")
  local renamed_encrypt_path = directory .. "/encrypt-renamed.yaml"
  vim.api.nvim_buf_set_name(encrypt_bufnr, renamed_encrypt_path)
  encrypt_call.callback({ code = 0, stdout = "", stderr = "" })
  wait_for_scheduled_callbacks()
  assert_true(vim.api.nvim_get_option_value("modified", { buf = encrypt_bufnr }), "rename cleared modified")
  assert_equal(1, count_buffer_write_autocmds(encrypt_bufnr))

  -- The state returned to ready, so a retry targets the new name instead of becoming permanently back-pressured.
  vim.api.nvim_buf_call(encrypt_bufnr, function()
    vim.cmd.write()
  end)
  local retry_call = take_system_call("edit")
  assert_equal(renamed_encrypt_path, retry_call.command[3], "retry targeted the original path")
  retry_call.callback({ code = 1, stdout = "", stderr = "expected retry failure" })
  wait_for_scheduled_callbacks()
  assert_true(#notifications >= 2, "renamed asynchronous results were not reported")

  vim.fn.delete(directory, "rf")
end

local function test_failed_save_preserves_plaintext()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/failure.yaml"
  write_encrypted_file(path, "failure-old")

  local sops = require("sops")
  sops.setup()
  local bufnr = open_encrypted_file(path)
  complete_decryption("secret: original")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "secret: must survive" })

  assert_toggle_warning(sops, "save changes before disabling")
  assert_equal(0, #pending_system_calls, "toggle started an encryption process")

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd.write()
  end)
  local encrypt_call = take_system_call("edit")
  encrypt_call.callback({ code = 1, stdout = "", stderr = "test failure" })
  wait_for_scheduled_callbacks()

  assert_true(not sops.disabled, "failed encryption disabled the plugin")
  assert_equal(nil, sops.transitioning, "internal pending work leaked into the public module state")
  assert_equal({ "secret: must survive" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  assert_true(vim.api.nvim_get_option_value("modified", { buf = bufnr }), "failed encryption cleared modified")
  assert_equal("acwrite", vim.api.nvim_get_option_value("buftype", { buf = bufnr }))
  assert_equal(1, count_buffer_write_autocmds(bufnr))
  assert_true(#notifications > 0, "failed asynchronous transition was not reported")
  assert_equal(vim.log.levels.ERROR, notifications[#notifications].level)

  vim.fn.delete(directory, "rf")
end

local function test_disable_requires_saved_buffers_and_ignores_current_scratch_buffer()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local first_path = directory .. "/first.yaml"
  local second_path = directory .. "/second.yaml"
  write_encrypted_file(first_path, "first-old")
  write_encrypted_file(second_path, "second-old")

  local sops = require("sops")
  sops.setup()

  local first_bufnr = open_encrypted_file(first_path)
  complete_decryption("secret: first plaintext")
  local second_bufnr = open_encrypted_file(second_path)
  complete_decryption("secret: second plaintext")

  vim.api.nvim_buf_set_lines(first_bufnr, 0, -1, false, { "secret: first changed" })
  vim.api.nvim_buf_set_lines(second_bufnr, 0, -1, false, { "secret: second changed" })

  local scratch_bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(scratch_bufnr)
  vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, { "unrelated unsaved text" })

  assert_toggle_warning(sops, "save changes before disabling")
  assert_true(not sops.disabled, "failed disable changed plugin state")
  assert_equal(0, #pending_system_calls, "toggle started encryption")
  assert_equal({ "unrelated unsaved text" }, vim.api.nvim_buf_get_lines(scratch_bufnr, 0, -1, false))

  vim.api.nvim_buf_call(first_bufnr, function()
    vim.cmd.write()
  end)
  complete_encryption(first_path, "first-new")
  vim.api.nvim_buf_call(second_bufnr, function()
    vim.cmd.write()
  end)
  complete_encryption(second_path, "second-new")

  sops.toggle()
  assert_true(sops.disabled, "disable failed after buffers were saved")
  assert_equal(encrypted_lines("first-new"), vim.api.nvim_buf_get_lines(first_bufnr, 0, -1, false))
  assert_equal(encrypted_lines("second-new"), vim.api.nvim_buf_get_lines(second_bufnr, 0, -1, false))
  assert_equal("", vim.api.nvim_get_option_value("buftype", { buf = first_bufnr }))
  assert_equal("", vim.api.nvim_get_option_value("buftype", { buf = second_bufnr }))
  assert_equal(0, count_buffer_write_autocmds(first_bufnr))
  assert_equal(0, count_buffer_write_autocmds(second_bufnr))
  assert_equal({ "unrelated unsaved text" }, vim.api.nvim_buf_get_lines(scratch_bufnr, 0, -1, false))
  assert_true(
    vim.api.nvim_get_option_value("modified", { buf = scratch_bufnr }),
    "scratch buffer was saved or reloaded"
  )

  vim.fn.delete(directory, "rf")
end

local tests = {
  setup = test_setup_is_idempotent,
  real_open = test_decrypt_started_by_real_bufreadpost_is_not_rejected,
  unload = test_unload_tears_down_buffer_management,
  stale_decrypt = test_disable_rejects_pending_decryption,
  pending_edit = test_edited_pending_decryption_requires_reload,
  rename = test_renamed_buffers_reject_async_results,
  failed_encrypt = test_failed_save_preserves_plaintext,
  disable = test_disable_requires_saved_buffers_and_ignores_current_scratch_buffer,
}

local test_name = vim.env.SOPS_NVIM_TEST
local test = tests[test_name]
if not test then
  fail("unknown SOPS_NVIM_TEST: " .. tostring(test_name))
end

local ok, test_error = xpcall(test, debug.traceback)
if not ok then
  io.stderr:write(test_error .. "\n")
  vim.cmd("cquit 1")
end

print("PASS " .. test_name)
