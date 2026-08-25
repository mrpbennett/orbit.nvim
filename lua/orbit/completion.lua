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

local function postgres_identifier(value)
  return '"' .. value:gsub('"', '""') .. '"'
end

local function postgres_schema_prefix(value)
  -- Decode a quoted prefix for cache lookup; inserted completion words stay SQL-escaped.
  local schema = value:sub(1, -2)
  if schema:sub(1, 1) == '"' and schema:sub(-1) == '"' then
    return schema:sub(2, -2):gsub('""', '"')
  end
  return schema
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
    local postgres_prefix = row.schema and postgres_identifier(row.schema) .. "." or nil
    if prefix == "" or not row.schema or prefix == row.schema .. "." or (profile.kind == "postgres" and prefix == postgres_prefix) then
      local name = row.schema and row.schema .. "." .. row.name or row.name
      if profile.kind == "trino" and row.catalog and row.catalog ~= profile.options.catalog then
        name = row.catalog .. "." .. name
      end
      if profile.kind == "postgres" and row.schema then
        name = postgres_identifier(row.schema) .. "." .. postgres_identifier(row.name)
      end
      local word = profile.kind == "postgres" and name or prefix ~= "" and prefix .. row.name or name
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
  local qualifier = before:match("([%w_\"]+%.)[%w_\"]*$")
  if qualifier then
    -- Prefer columns on a known object, then schema-qualified objects, before keyword completion.
    local object = qualifier:sub(1, -2)
    if #cache.columns(profile.name, object) > 0 then
      return column_items(profile, object, qualifier)
    end
    if profile.kind == "trino" or profile.kind == "postgres" then
      local schema = profile.kind == "postgres" and postgres_schema_prefix(qualifier) or object
      for _, row in ipairs(cache.tables(profile.name)) do
        if row.schema == schema then
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
    -- Neovim supplies a byte column; Lua's byte-oriented string indexing matches it here.
    local word = line:sub(1, cursor):match("[%w_%.\"]*$") or ""
    return cursor - #word
  end
  local profile = profile_for_buffer(vim.api.nvim_get_current_buf())
  if not profile then
    return {}
  end
  local items = M.items(profile, line, cursor)
  if base ~= "" then
    -- Item generation can be broad; omnifunc applies the final exact prefix filter.
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
