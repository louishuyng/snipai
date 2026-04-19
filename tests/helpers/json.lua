-- Pure-Lua JSON decoder for the test suite.
--
-- Production code never imports this: it uses vim.json.decode. The test
-- suite, however, must also run under standalone busted where `vim` is
-- nil, so we ship a small decoder here. Encoding is not implemented —
-- tests only need to parse fixtures.
--
-- Spec coverage: strings with escapes and \uXXXX, numbers (int/float/sci),
-- true/false/null, objects, arrays, nested structures. Good enough for our
-- fixtures (Claude Code stream-json output) without pulling in dkjson.

local M = {}

local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    else
      break
    end
  end
  return i
end

local parse_value

local function parse_string(s, i)
  if s:sub(i, i) ~= '"' then
    error(("expected string at position %d"):format(i))
  end
  i = i + 1
  local buf = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local esc = s:sub(i + 1, i + 1)
      if esc == '"' or esc == "\\" or esc == "/" then
        buf[#buf + 1] = esc
        i = i + 2
      elseif esc == "n" then
        buf[#buf + 1] = "\n"
        i = i + 2
      elseif esc == "t" then
        buf[#buf + 1] = "\t"
        i = i + 2
      elseif esc == "r" then
        buf[#buf + 1] = "\r"
        i = i + 2
      elseif esc == "b" then
        buf[#buf + 1] = "\b"
        i = i + 2
      elseif esc == "f" then
        buf[#buf + 1] = "\f"
        i = i + 2
      elseif esc == "u" then
        local hex = s:sub(i + 2, i + 5)
        if #hex ~= 4 or not hex:match("^%x%x%x%x$") then
          error(("bad \\u escape at %d"):format(i))
        end
        local n = tonumber(hex, 16)
        -- minimal UTF-8 encoding for BMP chars; surrogate pairs unsupported
        if n < 0x80 then
          buf[#buf + 1] = string.char(n)
        elseif n < 0x800 then
          buf[#buf + 1] = string.char(0xC0 + math.floor(n / 0x40))
            .. string.char(0x80 + (n % 0x40))
        else
          buf[#buf + 1] = string.char(0xE0 + math.floor(n / 0x1000))
            .. string.char(0x80 + (math.floor(n / 0x40) % 0x40))
            .. string.char(0x80 + (n % 0x40))
        end
        i = i + 6
      else
        error(("unknown escape \\%s at %d"):format(esc, i))
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  error("unterminated string")
end

local function parse_number(s, i)
  local start = i
  -- optional sign
  if s:sub(i, i) == "-" then
    i = i + 1
  end
  -- integer part
  while i <= #s and s:sub(i, i):match("%d") do
    i = i + 1
  end
  -- fraction
  if s:sub(i, i) == "." then
    i = i + 1
    while i <= #s and s:sub(i, i):match("%d") do
      i = i + 1
    end
  end
  -- exponent
  local e = s:sub(i, i)
  if e == "e" or e == "E" then
    i = i + 1
    local sign = s:sub(i, i)
    if sign == "+" or sign == "-" then
      i = i + 1
    end
    while i <= #s and s:sub(i, i):match("%d") do
      i = i + 1
    end
  end
  local n = tonumber(s:sub(start, i - 1))
  if n == nil then
    error(("invalid number at %d"):format(start))
  end
  return n, i
end

local function parse_object(s, i)
  if s:sub(i, i) ~= "{" then
    error("expected {")
  end
  i = skip_ws(s, i + 1)
  local obj = {}
  if s:sub(i, i) == "}" then
    return obj, i + 1
  end
  while true do
    i = skip_ws(s, i)
    local key
    key, i = parse_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then
      error(("expected : at %d"):format(i))
    end
    i = skip_ws(s, i + 1)
    local value
    value, i = parse_value(s, i)
    obj[key] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "}" then
      return obj, i + 1
    else
      error(("expected , or } at %d"):format(i))
    end
  end
end

local function parse_array(s, i)
  if s:sub(i, i) ~= "[" then
    error("expected [")
  end
  i = skip_ws(s, i + 1)
  local arr = {}
  if s:sub(i, i) == "]" then
    return arr, i + 1
  end
  while true do
    local value
    value, i = parse_value(s, i)
    arr[#arr + 1] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      error(("expected , or ] at %d"):format(i))
    end
  end
end

function parse_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return parse_string(s, i)
  elseif c == "{" then
    return parse_object(s, i)
  elseif c == "[" then
    return parse_array(s, i)
  elseif c == "-" or c:match("%d") then
    return parse_number(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    error(("unexpected character %q at %d"):format(c, i))
  end
end

-- Decode a JSON string. Returns (value) on success or (nil, err) on failure.
function M.decode(str)
  if type(str) ~= "string" then
    return nil, "input must be a string"
  end
  local ok, result, rest = pcall(function()
    local value, i = parse_value(str, 1)
    return value, i
  end)
  if not ok then
    return nil, result
  end
  -- rest is the index just past the value; trailing whitespace is OK.
  local tail = skip_ws(str, rest or 1)
  if tail <= #str then
    return nil, ("trailing content at position %d"):format(tail)
  end
  return result
end

return M
