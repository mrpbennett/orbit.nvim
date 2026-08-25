local schema_tree = require("orbit.schema_tree")

local icons = {
  collapsed = ">",
  column = ":",
  expanded = "v",
  folder = "+",
  index = "I",
  key = "K",
  table = "#",
  view = "~",
}

local profile = { kind = "sqlite", name = "fixture", options = {} }

return {
  ["schema_tree.lines renders collapsed schemas and object groups"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, {
      { schema = "main", name = "sessions", type = "table" },
      { schema = "main", name = "active_sessions", type = "view" },
    })

    local lines, nodes, _, has_matches = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(has_matches)
    assert(lines[1]:match("^> main$"), vim.inspect(lines))
    assert(nodes[1].kind == "schema" and nodes[1].name == "main")
    assert(#lines == 1, "collapsed schema should not reveal its groups")
  end,

  ["schema_tree.toggle expands a schema to reveal its table and view groups"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, {
      { schema = "main", name = "sessions", type = "table" },
      { schema = "main", name = "active_sessions", type = "view" },
    })

    schema_tree.toggle(tree, { kind = "schema", name = "main" })
    local lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(lines[1]:match("^v main$"))
    assert(lines[2]:match("tables 1$"))
    assert(lines[3]:match("views 1$"))
    assert(nodes[2].kind == "group" and nodes[2].group == "tables")
    assert(nodes[3].kind == "group" and nodes[3].group == "views")
  end,

  ["schema_tree.toggle expands an object group to reveal its tables"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, { { schema = "main", name = "sessions", type = "table" } })
    schema_tree.toggle(tree, { kind = "schema", name = "main" })
    schema_tree.toggle(tree, { group = "tables", kind = "group", schema = "main" })

    local lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(lines[3]:match("sessions$"))
    assert(nodes[3].kind == "table")
    assert(nodes[3].row.name == "sessions")
  end,

  ["schema_tree.toggle expands a table to reveal its metadata categories"] = function()
    local tree = schema_tree.new()
    local row = { schema = "main", name = "sessions", type = "table" }
    schema_tree.set_tables(tree, { row })
    schema_tree.toggle(tree, { kind = "schema", name = "main" })
    schema_tree.toggle(tree, { group = "tables", kind = "group", schema = "main" })
    schema_tree.toggle(tree, { kind = "table", profile = profile, row = row })

    local lines = schema_tree.lines(tree, profile, "", { icons = icons })

    local folders = table.concat(lines, "\n")
    assert(folders:match("columns"))
    assert(folders:match("primary keys"))
    assert(folders:match("foreign keys"))
    assert(folders:match("indexes"))
    assert(folders:match("%+ primary keys"))
    assert(folders:match("%+ foreign keys"))
    assert(folders:match("%+ indexes"))
  end,

  ["schema_tree.lines shows loading placeholders for pending metadata"] = function()
    local tree = schema_tree.new()
    local row = { schema = "main", name = "sessions", type = "table" }
    schema_tree.set_tables(tree, { row })
    schema_tree.toggle(tree, { kind = "schema", name = "main" })
    schema_tree.toggle(tree, { group = "tables", kind = "group", schema = "main" })
    schema_tree.toggle(tree, { kind = "table", profile = profile, row = row })
    local category = { id = "columns", label = "columns" }
    schema_tree.toggle(tree, { category = category, kind = "metadata", profile = profile, row = row })

    local lines = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(table.concat(lines, "\n"):match("loading columns"))

    schema_tree.set_metadata(tree, row, "columns", { { name = "id", type = "INTEGER" } })
    lines = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(table.concat(lines, "\n"):match("id  INTEGER"))
  end,

  ["schema_tree.reset clears tables, metadata, and expansion state"] = function()
    local tree = schema_tree.new()
    local row = { schema = "main", name = "sessions", type = "table" }
    schema_tree.set_tables(tree, { row })
    schema_tree.toggle(tree, { kind = "schema", name = "main" })
    schema_tree.set_metadata(tree, row, "columns", { { name = "id" } })
    schema_tree.set_metadata_loading(tree, row, "foreign_keys", true)

    schema_tree.reset(tree)

    assert(#tree.tables == 0)
    assert(not schema_tree.is_expanded(tree, { kind = "schema", name = "main" }))
    assert(not schema_tree.is_metadata_loaded(tree, row, "columns"))
    assert(not schema_tree.is_metadata_loading(tree, row, "foreign_keys"))
  end,

  ["schema_tree.lines filters schemas and objects by name"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, {
      { schema = "main", name = "sessions", type = "table" },
      { schema = "reporting", name = "orders", type = "table" },
    })

    local _, _, _, has_matches = schema_tree.lines(tree, profile, "orders", { icons = icons })
    assert(has_matches)

    local lines = schema_tree.lines(tree, profile, "orders", { icons = icons })
    assert(table.concat(lines, "\n"):match("reporting"))
    assert(not table.concat(lines, "\n"):match("^main$"))
  end,

  ["schema_tree.lines reports no matches for an unrelated filter"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, { { schema = "main", name = "sessions", type = "table" } })

    local _, _, _, has_matches = schema_tree.lines(tree, profile, "nonexistent", { icons = icons })
    assert(not has_matches)
  end,
}
