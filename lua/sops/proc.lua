local M = {}

-- age (and anything sops shells out to for an SSH identity, via
-- SOPS_AGE_SSH_PRIVATE_KEY_FILE/_CMD) refuses to read an encrypted SSH key's
-- passphrase from anything but a real terminal. A plain vim.system() run
-- (pipes only, no controlling tty) always fails this way, and sops surfaces
-- the underlying age error verbatim, so this is how we notice.
local function looks_like_passphrase_failure(result)
  return result.code ~= 0 and result.stderr ~= nil and result.stderr:lower():find("passphrase", 1, true) ~= nil
end

local PROMPT_PATTERN = "enter passphrase.*:%s*$"

-- After a passphrase is sent, age's password reader echoes a newline and
-- repaints over the prompt line before real output resumes. This strips that
-- leading run of bare CR/LF bytes and ANSI CSI sequences without touching
-- the real content that follows it.
local function strip_leading_prompt_artifacts(text)
  local before
  repeat
    before = text
    text = text:gsub("^[\r\n]", "")
    text = text:gsub("^\27%[[%d;]*%a", "")
  until text == before
  return text
end

local function strip_ansi(text)
  return (text:gsub("\27%[[%d;]*%a", ""))
end

-- Runs `cmd` attached to a pseudo-terminal so an SSH identity's passphrase
-- prompt can be answered interactively, then reports a vim.system()-shaped
-- result. A pty merges stdout and stderr, so on success the combined output
-- is reported as stdout and on failure as stderr.
local function run_interactive(cmd, opts, callback)
  local output = {}
  local pending = ""
  local awaiting_response = false
  local job_id

  local function append(text)
    if text ~= "" then
      table.insert(output, text)
    end
  end

  local function ask_for_passphrase(prompt)
    awaiting_response = true
    vim.schedule(function()
      local passphrase = vim.fn.inputsecret(prompt)
      vim.fn.chansend(job_id, passphrase .. "\r")
    end)
  end

  job_id = vim.fn.jobstart(cmd, {
    pty = true,
    cwd = opts.cwd,
    env = opts.env,
    on_stdout = function(_, data)
      local text = table.concat(data, "\n")
      if text == "" then
        return
      end

      if awaiting_response then
        text = strip_leading_prompt_artifacts(text)
        if text == "" then
          return
        end
        awaiting_response = false
      end

      pending = pending .. text
      if pending:sub(-1) == "\n" then
        append(pending)
        pending = ""
      elseif pending:lower():match(PROMPT_PATTERN) then
        ask_for_passphrase(pending)
        pending = ""
      end
    end,
    on_exit = function(_, code)
      append(pending)
      local text = table.concat(output, ""):gsub("\r\n", "\n")
      if code ~= 0 then
        callback({ code = code, stdout = "", stderr = strip_ansi(text) })
      else
        callback({ code = code, stdout = text, stderr = "" })
      end
    end,
  })

  if not job_id or job_id <= 0 then
    error("sops.nvim: failed to start interactive job for " .. cmd[1], 0)
  end
end

--- Runs `cmd` via vim.system, retrying once over a pseudo-terminal if it
--- failed because an encrypted SSH identity needed an interactive
--- passphrase. `callback` receives a vim.system()-shaped result either way.
function M.run(cmd, opts, callback)
  vim.system(cmd, opts, function(result)
    if looks_like_passphrase_failure(result) then
      vim.schedule(function()
        run_interactive(cmd, opts, callback)
      end)
    else
      callback(result)
    end
  end)
end

return M
