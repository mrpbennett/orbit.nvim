-- Shared glob-style matching for the `schema_patterns` profile option,
-- used by every SQL connector (postgres, vertica, trino) to build the
-- `information_schema` filter clause, and by sqlite to test its single
-- implicit "main" schema client-side.
--
-- Patterns support `*` (any run of characters) and `?` (single character),
-- e.g. `"PROF*"` matches `PROF_SALES`, `PROFIT`, etc. A pattern with no
-- wildcard characters matches only that exact schema name.
local M = {}

local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function has_wildcard(pattern)
  return pattern:find("[%*%?]") ~= nil
end

-- Converts a glob into a SQL LIKE pattern, escaping any literal `%`, `_`,
-- or `\` first so they aren't mistaken for LIKE wildcards themselves.
local function to_like_pattern(glob)
  local escaped = glob:gsub("[%%_\\]", "\\%0")
  return (escaped:gsub("%*", "%%"):gsub("%?", "_"))
end

-- Builds a SQL boolean expression restricting `column` to `patterns` (an
-- array of schema names, some of which may contain `*`/`?` wildcards).
-- Plain names are combined into a single `IN (...)`; wildcard entries
-- become `LIKE ... ESCAPE '\'` clauses, all OR'd together.
-- Returns nil if `patterns` is nil or empty (meaning "no filter").
function M.sql_clause(column, patterns)
  if not patterns or #patterns == 0 then
    return nil
  end
  local exact, clauses = {}, {}
  for _, pattern in ipairs(patterns) do
    if has_wildcard(pattern) then
      table.insert(clauses, column .. " LIKE " .. literal(to_like_pattern(pattern)) .. " ESCAPE '\\'")
    else
      table.insert(exact, literal(pattern))
    end
  end
  if #exact > 0 then
    table.insert(clauses, 1, column .. " IN (" .. table.concat(exact, ", ") .. ")")
  end
  return "(" .. table.concat(clauses, " OR ") .. ")"
end

-- Client-side equivalent of sql_clause for connectors with no SQL access
-- to the schema name being tested (sqlite's implicit "main" schema).
function M.matches(pattern, value)
  if not has_wildcard(pattern) then
    return pattern == value
  end
  local lua_pattern = "^" .. pattern:gsub("[%(%)%.%%%+%-%[%]%^%$]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
  return value:match(lua_pattern) ~= nil
end

return M
