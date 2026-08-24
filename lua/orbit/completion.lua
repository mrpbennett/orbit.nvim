local cache = require("orbit.schema_cache")
local profiles = require("orbit.profiles")

local M = {}

local function item(word, kind, detail)
  return {
    abbr = word,
    kind = kind,
    menu = detail,
    word = word,
  }
end

local function sorted(items)
  table.sort(items, function(left, right)
    return left.word < right.word
  end)
  return items
end

local function table_items(profile, prefix)
  local items = {}
  for _, row in ipairs(cache.tables(profile.name)) do
    if prefix == "" or not row.schema or prefix == row.schema .. "." then
      local name = row.schema and row.schema .. "." .. row.name or row.name
      local word = prefix ~= "" and prefix .. row.name or name
      table.insert(items, item(word, row.type == "view" and "View" or "Table", profile.name))
    end
  end
  return sorted(items)
end

local function column_items(profile, table_name, prefix)
  local items = {}
  for _, column in ipairs(cache.columns(profile.name, table_name)) do
    table.insert(items, item(prefix .. column.name, "Column", column.type or ""))
  end
  return sorted(items)
end

function M.items(profile, line, cursor)
  local before = line:sub(1, cursor)
  local qualifier = before:match("([%w_]+%.)[%w_]*$")
  if qualifier then
    local object = qualifier:sub(1, -2)
    if #cache.columns(profile.name, object) > 0 then
      return column_items(profile, object, qualifier)
    end
    if profile.kind == "trino" then
      for _, row in ipairs(cache.tables(profile.name)) do
        if row.schema == object then
          return table_items(profile, qualifier)
        end
      end
    end
  end

  local keyword = before:upper():match("([A-Z]+)%s+[%w_%.]*$")
  if keyword == "FROM" or keyword == "JOIN" or keyword == "UPDATE" or keyword == "INTO" then
    return table_items(profile, "")
  end
  return {}
end

local function profile_for_buffer(buffer)
  local orbit = require("orbit")
  local document = profiles.load(orbit.config.profile_path)
  if not document then
    return nil
  end
  local name = vim.b[buffer].orbit_profile
  return profiles.find(document, name)
end

function M.omnifunc(findstart, base)
  local cursor = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_get_current_line()
  if findstart == 1 then
    local word = line:sub(1, cursor):match("[%w_%.]*$") or ""
    return cursor - #word
  end
  local profile = profile_for_buffer(vim.api.nvim_get_current_buf())
  if not profile then
    return {}
  end
  local items = M.items(profile, line, cursor)
  if base ~= "" then
    local filtered = {}
    for _, candidate in ipairs(items) do
      if candidate.word:sub(1, #base) == base then
        table.insert(filtered, candidate)
      end
    end
    return filtered
  end
  return items
end

function M.attach(buffer)
  vim.bo[buffer].omnifunc = "v:lua.OrbitComplete"
end

function M.prewarm(profile)
  cache.load_tables(profile)
end

return M
