local mutation_sql = require("orbit.connectors.utils.mutation_sql")

local function identifier(value)
  return '"' .. value:gsub('"', '""') .. '"'
end

local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function changes(overrides)
  return vim.tbl_extend("force", { deleted = {}, modified = {}, inserted = {} }, overrides or {})
end

return {
  ["editable_table rejects a view"] = function()
    local target, err = mutation_sql.editable_table({ type = "view", name = "v" }, { "id" })
    assert(target == nil)
    assert(err:match("read%-only"))
  end,

  ["editable_table rejects a table with no primary key"] = function()
    local target, err = mutation_sql.editable_table({ type = "table", name = "t" }, {})
    assert(target == nil)
    assert(err:match("read%-only"))
  end,

  ["editable_table accepts a table with a primary key"] = function()
    local target = assert(mutation_sql.editable_table({ type = "table", name = "t", schema = "s" }, { "id" }))
    assert(target.name == "t")
    assert(target.schema == "s")
    assert(target.primary_keys[1] == "id")
  end,

  ["build refuses to delete a row with a NULL primary key"] = function()
    local sql, err = mutation_sql.build('"t"', identifier, literal, "BEGIN", { "id" }, changes({
      deleted = { { original = { id = vim.NIL } } },
    }))
    assert(sql == nil)
    assert(err == "Cannot delete a row with a NULL primary key.")
  end,

  ["build refuses to update a primary key column"] = function()
    local sql, err = mutation_sql.build('"t"', identifier, literal, "BEGIN", { "id" }, changes({
      modified = { { original = { id = 1 }, values = { id = 2 } } },
    }))
    assert(sql == nil)
    assert(err == "Editing primary key values is not supported.")
  end,

  ["build skips a no-op update when nothing actually changed"] = function()
    local sql = assert(mutation_sql.build('"t"', identifier, literal, "BEGIN", { "id" }, changes({
      modified = { { original = { id = 1, name = "a" }, values = { id = 1, name = "a" } } },
    })))
    assert(sql == "BEGIN;\nCOMMIT;", sql)
  end,

  ["build orders inserted columns deterministically"] = function()
    local sql = assert(mutation_sql.build('"t"', identifier, literal, "BEGIN", { "id" }, changes({
      inserted = { { values = { z = 1, a = 2 } } },
    })))
    assert(sql:match("INSERT INTO \"t\" %(\"a\", \"z\"%) VALUES %('2', '1'%)"), sql)
  end,

  ["build falls back to DEFAULT VALUES when every column is unset"] = function()
    local sql = assert(mutation_sql.build('"t"', identifier, literal, "BEGIN", { "id" }, changes({
      inserted = { { values = {} } },
    })))
    assert(sql:match('INSERT INTO "t" DEFAULT VALUES'), sql)
  end,

  ["build wraps statements with the given begin_stmt"] = function()
    local sql = assert(mutation_sql.build('"t"', identifier, literal, "BEGIN IMMEDIATE", { "id" }, changes({
      deleted = { { original = { id = 1 } } },
    })))
    assert(sql == "BEGIN IMMEDIATE;\nDELETE FROM \"t\" WHERE \"id\" = '1';\nCOMMIT;", sql)
  end,
}
