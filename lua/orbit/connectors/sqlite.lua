local M = {}

local function append(arguments, values)
  for _, value in ipairs(values) do
    table.insert(arguments, value)
  end
end

local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

function M.validate_options(profile_name, options)
  local allowed = {
    arguments = true,
    confirm_mutations = true,
    executable = true,
    path = true,
  }
  for name in pairs(options) do
    if not allowed[name] then
      return nil, string.format("profile %q has unsupported SQLite option %q", profile_name, name)
    end
  end
  return true
end

function M.prepare(options, statement)
  local command = { options.executable or "sqlite3" }
  append(command, options.arguments or {})
  append(command, { "-json", options.path, statement })
  return command
end

function M.schema_statement(_, node)
  if node.type == "tables" then
    return "SELECT 'main' AS schema, name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
  end
  if node.type == "columns" and node.name then
    return "PRAGMA table_info(" .. literal(node.name) .. ")"
  end
  return nil, "unsupported schema node"
end

return M
