local snipai = require("snipai")
local statusline = require("snipai.statusline")
local events_mod = require("snipai.events")
local notify_mod = require("snipai.notify")
local history_mod = require("snipai.history")
local json = require("tests.helpers.json")

-- Minimal setup harness — mirrors tests/unit/init_spec.lua but trimmed to
-- just what statusline smoke tests need.
local function new_in_memory_fs()
  local files = {}
  return {
    read_all = function(path)
      if files[path] == nil then
        return nil, "No such file"
      end
      return files[path]
    end,
    append = function(path, text)
      files[path] = (files[path] or "") .. text
      return true
    end,
    write_all = function(path, text)
      files[path] = text
      return true
    end,
    remove = function(path)
      files[path] = nil
      return true
    end,
    mkdir_p = function()
      return true
    end,
  }
end

local function new_fake_runner()
  local rec = { spawns = {} }
  rec.spawn = function(prompt, opts, on_event, on_exit)
    local slot = { prompt = prompt, opts = opts, on_event = on_event, on_exit = on_exit }
    slot.handle = {
      cancel = function()
        slot.cancelled = true
        return true
      end,
    }
    rec.spawns[#rec.spawns + 1] = slot
    return slot.handle
  end
  return rec
end

local function new_recording_notify()
  return notify_mod.new({
    backend = function() end,
    levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 },
  })
end

local FIXTURE_PATH = "/snippets.json"
local FIXTURE_JSON = json.encode({
  no_params = { prefix = "np", body = "do the thing" },
})

local function setup()
  local runner = new_fake_runner()
  snipai.setup({
    config_paths = { FIXTURE_PATH },
    claude = { cmd = "claude" },
    history = { path = "/history.jsonl", max_entries = 500, per_project = true },
    ui = { notify = "auto" },
    _deps = {
      events = events_mod.new(),
      notify = new_recording_notify(),
      history = history_mod.new({
        path = "/history.jsonl",
        fs = new_in_memory_fs(),
        json_encode = json.encode,
        json_decode = json.decode,
        cwd = "/proj",
        now = (function()
          local t = 0
          return function()
            t = t + 1
            return 10000 + t
          end
        end)(),
      }),
      runner = runner,
      reader = function(p)
        if p == FIXTURE_PATH then
          return FIXTURE_JSON
        end
        return nil, "No such file"
      end,
      json_decode = json.decode,
      gather_builtins = function()
        return { cursor_file = "/proj/a.lua", cursor_line = 1, cursor_col = 1, cwd = "/proj" }
      end,
      place_insert = function() end,
      save_buffer = function() end,
      refresh_buffers = function() end,
      keymap_set = function() end,
    },
  })
  return runner
end

describe("snipai.statusline.status", function()
  before_each(function()
    statusline._reset()
    snipai._reset()
  end)

  it("returns empty string before setup", function()
    assert.equals("", statusline.status())
  end)

  it("returns empty for any buffer when no job is running", function()
    setup()
    assert.equals("", statusline.status(0))
  end)

  it("shows the indicator immediately on the triggering file (before any tool_use)", function()
    local runner = setup()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/proj/a.lua")

    snipai.trigger("no_params")
    -- No on_event yet — files_changed is empty. Attribution must come
    -- from the job's cursor_file captured at spawn time.
    assert.matches("snipai", statusline.status(buf))

    runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
    assert.equals("", statusline.status(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("shows the indicator when an active job has already touched this buffer's file", function()
    local runner = setup()
    snipai.trigger("no_params")
    runner.spawns[1].on_event({
      kind = "tool_use",
      tool = "Edit",
      input = { file_path = "/proj/b.lua" }, -- different from cursor_file
    })

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/proj/b.lua")
    assert.matches("snipai", statusline.status(buf))

    runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
    assert.equals("", statusline.status(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns empty for a buffer neither triggered-from nor touched", function()
    local runner = setup()
    snipai.trigger("no_params")

    local other = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(other, "/proj/unrelated.lua")
    assert.equals("", statusline.status(other))

    runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("returns empty for unnamed scratch buffers even with an active run", function()
    local runner = setup()
    snipai.trigger("no_params")
    local buf = vim.api.nvim_create_buf(false, true)
    assert.equals("", statusline.status(buf))
    runner.spawns[1].on_exit(0, { cancelled = false, stderr = "", parser_errors = {} })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
