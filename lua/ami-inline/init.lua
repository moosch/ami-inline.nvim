-- ami-inline: native Copilot-style ghost-text (FIM) completion for ami.
--
-- Extracted from ami core into its own extension repo. Talks directly to LM Studio's
-- /v1/completions endpoint (not through amid) to keep latency low. Manual trigger by
-- default; optional debounced auto-trigger. Advisor ethos preserved: suggestions are
-- ghost text you explicitly accept or dismiss — nothing is written until you accept.
--
-- Install alongside ami and register it:
--   require("ami").setup({ extensions = { require("ami-inline") } })
--
-- It registers a "fim" model slot, so :AmiModel lists it; its model/endpoint fall
-- back to ami's default model slot unless you set inline.model / inline.endpoint.

local ns = vim.api.nvim_create_namespace("ami_inline")
local augroup = nil

local A = nil -- the ami extension API, set in setup()

-- Current suggestion state.
local state = { text = nil, bufnr = nil, row = nil, col = nil }
local gen = 0        -- request generation, to drop stale responses
local inflight = nil -- in-flight vim.system handle
local auto_timer = nil

local function cfg()
  return A.config
end

-- The effective provider for FIM: the "fim" slot's override, else ami's default.
local function provider()
  return A.models.effective("fim")
end

-- Ghost text -----------------------------------------------------------------

local function clear()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  end
  state.text, state.bufnr, state.row, state.col = nil, nil, nil, nil
end

local function show(bufnr, row, col, text)
  clear()
  local lines = vim.split(text, "\n", { plain = true })
  local opts = {
    virt_text = { { lines[1], "AmiInlineGhost" } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  }
  if #lines > 1 then
    local vlines = {}
    for i = 2, #lines do
      vlines[#vlines + 1] = { { lines[i], "AmiInlineGhost" } }
    end
    opts.virt_lines = vlines
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, opts)
  state.text, state.bufnr, state.row, state.col = text, bufnr, row, col
end

-- FIM request ----------------------------------------------------------------

-- Build (prefix, suffix) around the cursor, bounded by the configured line windows.
local function context(bufnr, win)
  local c = cfg()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local total = vim.api.nvim_buf_line_count(bufnr)

  local first = math.max(0, row - (c.context_before_lines or 120))
  local last = math.min(total, row + 1 + (c.context_after_lines or 60))

  local cur = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local before = vim.api.nvim_buf_get_lines(bufnr, first, row, false)
  local after = vim.api.nvim_buf_get_lines(bufnr, row + 1, last, false)

  local prefix = table.concat(before, "\n")
  if #before > 0 then
    prefix = prefix .. "\n"
  end
  prefix = prefix .. cur:sub(1, col)

  local suffix = cur:sub(col + 1)
  if #after > 0 then
    suffix = suffix .. "\n" .. table.concat(after, "\n")
  end
  return prefix, suffix, row, col
end

-- Keep at most max_lines lines (0 = unlimited) and drop a purely-empty result.
local function postprocess(text, max_lines)
  if max_lines and max_lines > 0 then
    local lines = vim.split(text, "\n", { plain = true })
    if #lines > max_lines then
      lines = vim.list_slice(lines, 1, max_lines)
      text = table.concat(lines, "\n")
    end
  end
  return text
end

local function request(bufnr, win, cb, silent)
  local c = cfg()
  local eff = provider()
  local prefix, suffix, row, col = context(bufnr, win)
  local fim = c.fim or {}
  local prompt = (fim.prefix or "") .. prefix .. (fim.suffix or "") .. suffix .. (fim.middle or "")

  local body = {
    model = eff.model,
    prompt = prompt,
    max_tokens = c.max_tokens or 128,
    temperature = c.temperature or 0.2,
    stop = c.stop,
    stream = false,
  }
  local url = (eff.endpoint or ""):gsub("/$", "") .. "/completions"
  local timeout_s = math.max(1, math.floor((c.timeout_ms or 20000) / 1000))
  A.log.debug(("inline: POST %s (prefix=%d, suffix=%d bytes, timeout=%ds)"):format(url, #prefix, #suffix, timeout_s))

  if inflight then
    pcall(function() inflight:kill(9) end)
    inflight = nil
  end

  -- Report a failure: quiet (debug) for auto-trigger, loud (warn) for manual.
  local function fail(reason)
    if silent then
      A.log.debug("inline: " .. reason)
    else
      A.log.warn("inline: " .. reason) -- log.warn also notifies
    end
    cb(nil, row, col)
  end

  local uv = vim.uv or vim.loop
  local start = uv.hrtime()

  inflight = vim.system(
    {
      "curl", "-sS", "-m", tostring(timeout_s),
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", vim.json.encode(body), url,
    },
    { text = true },
    function(res)
      vim.schedule(function()
        inflight = nil
        local ms = math.floor((uv.hrtime() - start) / 1e6)
        if res.code ~= 0 then
          if res.code == 28 then
            return fail(("request timed out after %ds — is the model loaded? The first completion can be slow while LM Studio loads it; try again once it's warm, raise inline.timeout_ms, or use a smaller FIM model."):format(timeout_s))
          elseif res.code == 7 then
            return fail("could not connect to " .. url .. " — check the fim model's endpoint (inline.endpoint or ami's default model.endpoint)")
          end
          return fail(("curl exit %d: %s"):format(res.code, (res.stderr or ""):gsub("%s+$", "")))
        end
        local ok, data = pcall(vim.json.decode, res.stdout)
        if ok and type(data) == "table" and data.error then
          local em = type(data.error) == "table" and (data.error.message or vim.inspect(data.error)) or tostring(data.error)
          return fail("server error: " .. em)
        end
        if not ok or not (data.choices and data.choices[1]) then
          return fail("unexpected response: " .. tostring(res.stdout):sub(1, 200))
        end
        local text = postprocess(data.choices[1].text or "", c.max_lines)
        if vim.trim(text) == "" then
          A.log.debug(("inline: empty completion (%dms)"):format(ms))
          return cb(nil, row, col)
        end
        A.log.debug(("inline: completion in %dms (%d chars)"):format(ms, #text))
        cb(text, row, col)
      end)
    end
  )
  return inflight
end

-- Public actions -------------------------------------------------------------

local function trigger(silent)
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if vim.bo[bufnr].buftype ~= "" then
    return -- only normal file buffers
  end

  clear()
  gen = gen + 1
  local my = gen

  request(bufnr, win, function(text, row, col)
    if not text or my ~= gen then
      return -- stale or empty
    end
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
      return
    end
    if vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    local cur = vim.api.nvim_win_get_cursor(win)
    if cur[1] - 1 ~= row or cur[2] ~= col then
      return
    end
    show(bufnr, row, col, text)
  end, silent)
end

local function accept()
  if not state.text then
    return false
  end
  local text, bufnr = state.text, state.bufnr
  clear()

  local win = vim.api.nvim_get_current_win()
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1] - 1, cur[2]
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)

  local new_row = row + #lines - 1
  local last = lines[#lines]
  local new_col = (#lines == 1) and (col + #last) or #last
  vim.api.nvim_win_set_cursor(win, { new_row + 1, new_col })
  return true
end

local function dismiss()
  clear()
end

-- Auto-trigger ---------------------------------------------------------------

local function schedule_auto()
  if auto_timer then
    auto_timer:stop()
    auto_timer = nil
  end
  auto_timer = vim.defer_fn(function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      trigger(true) -- auto-trigger: keep failures quiet
    end
  end, cfg().debounce_ms or 400)
end

local function toggle_auto()
  local c = cfg()
  c.auto = not c.auto
  A.log.info("inline: auto-trigger " .. (c.auto and "ON" or "OFF"))
  A.notify("inline: auto-trigger " .. (c.auto and "on" or "off"))
end

-- Fire one tiny FIM request so LM Studio loads the model before the first real
-- completion. Fire-and-forget; the result is discarded.
local function prewarm()
  local c = cfg()
  if c.enabled == false or c.prewarm == false then
    return
  end
  local eff = provider()
  local fim = c.fim or {}
  local body = {
    model = eff.model,
    prompt = (fim.prefix or "") .. "def _ami_warmup():\n    " .. (fim.suffix or "") .. (fim.middle or ""),
    max_tokens = 1,
    temperature = 0,
    stream = false,
  }
  local url = (eff.endpoint or ""):gsub("/$", "") .. "/completions"
  A.log.debug("inline: pre-warming model at " .. url)
  local uv = vim.uv or vim.loop
  local start = uv.hrtime()
  vim.system(
    {
      "curl", "-sS", "-m", "120", "-X", "POST",
      "-H", "Content-Type: application/json", "-d", vim.json.encode(body), url,
    },
    { text = true },
    function(res)
      vim.schedule(function()
        local ms = math.floor((uv.hrtime() - start) / 1e6)
        if res.code == 0 then
          A.log.info(("inline: model warmed in %dms"):format(ms))
        else
          A.log.debug(("inline: pre-warm failed (curl exit %d) — model will load on first use"):format(res.code))
        end
      end)
    end
  )
end

-- Extension spec --------------------------------------------------------------

return {
  name = "inline",

  -- Options (user overrides under `inline` in ami.setup win). endpoint/model are
  -- nil by default: the fim model slot inherits ami's default model slot.
  config = {
    enabled = true,
    endpoint = nil, -- nil = inherit ami's default model.endpoint
    model = nil,    -- nil = inherit ami's default model.model
    prewarm = true,
    auto = false,
    debounce_ms = 400,
    max_tokens = 256,
    max_lines = 0,
    temperature = 0.2,
    context_before_lines = 120,
    context_after_lines = 60,
    timeout_ms = 20000,
    fim = {
      prefix = "<|fim_prefix|>",
      suffix = "<|fim_suffix|>",
      middle = "<|fim_middle|>",
    },
    stop = { "<|fim_pad|>", "<|endoftext|>", "<|file_sep|>", "<|repo_name|>",
      "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>" },
    keymaps = {
      trigger = "<C-g>",
      accept = "<Tab>",
      dismiss = "<C-]>",
    },
  },

  commands = {
    AmiComplete = {
      desc = "Request an inline (ghost-text) completion",
      fn = function() trigger(false) end,
    },
    AmiInlineAuto = {
      desc = "Toggle inline auto-trigger on/off",
      fn = function() toggle_auto() end,
    },
  },

  setup = function(api)
    A = api
    if api.config.enabled == false then
      return
    end

    -- Register the fim model slot so :AmiModel can target it; falls back to ami's
    -- default model when inline.model/endpoint are unset.
    api.models.register({
      name = "fim",
      label = "Inline (FIM)",
      endpoint = function() return api.config.endpoint end,
      get = function() return api.config.model end,
      set = function(m) api.config.model = m end,
    })

    vim.api.nvim_set_hl(0, "AmiInlineGhost", { link = "Comment", default = true })

    local km = api.config.keymaps or {}
    if km.trigger then
      vim.keymap.set("i", km.trigger, function() trigger(false) end, { desc = "ami: request inline completion" })
    end
    if km.dismiss then
      vim.keymap.set("i", km.dismiss, dismiss, { desc = "ami: dismiss inline completion" })
    end
    if km.accept then
      vim.keymap.set("i", km.accept, function()
        if accept() then
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(km.accept, true, false, true), "n", false)
      end, { desc = "ami: accept inline completion (or fallback)" })
    end

    augroup = vim.api.nvim_create_augroup("AmiInline", { clear = true })
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = augroup,
      callback = function() clear() end,
    })
    vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
      group = augroup,
      callback = function()
        clear()
        if cfg().auto then
          schedule_auto()
        end
      end,
    })

    vim.defer_fn(prewarm, 500)
  end,
}
