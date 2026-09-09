local schema_tree = require("orbit.schema_tree")

local icons = {
  collapsed = ">",
  column = ":",
  expanded = "v",
  folder = "+",
  index = "I",
  key = "K",
  schema = "@",
  table = "#",
  view = "~",
  with = "W",
}

local profile = { kind = "sqlite", name = "fixture", options = {} }

-- Use the rendered nodes just as workspace interaction does; labels are not keys.
local function expand_tables(tree)
  local _, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
  schema_tree.toggle(tree, nodes[1])
  _, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
  schema_tree.toggle(tree, nodes[2])
end

return {
  ["schema_tree disambiguates object labels without changing ordinary names"] = function()
    local tree = schema_tree.new()
    local first = { schema = "a.b", name = "c", type = "table" }
    local second = { schema = "a", name = "b.c", type = "table" }
    local quoted = { name = '"a"."b.c"', type = "table" }
    local ordinary = { schema = "public", name = "orders", type = "table" }
    schema_tree.set_tables(tree, { first, ordinary })
    assert(schema_tree.object_name(tree, first) == "a.b.c")
    assert(schema_tree.object_name(tree, ordinary) == "public.orders")

    schema_tree.set_tables(tree, { first, second, quoted, ordinary })
    assert(schema_tree.object_name(tree, first) == '"a.b"."c"')
    assert(schema_tree.object_name(tree, second) == '"a"."b.c"')
    assert(schema_tree.object_name(tree, quoted) == '"""a"".""b.c"""')
    assert(schema_tree.object_name(tree, ordinary) == "public.orders")
    schema_tree.lines(tree, profile, "b.c", { icons = icons })
    assert(schema_tree.object_name(tree, first) == '"a.b"."c"')

    schema_tree.reset(tree)
    -- A pending action can finish after refresh has removed its original row.
    assert(schema_tree.object_name(tree, first) == "a.b.c")
  end,

  ["schema_tree keeps colliding objects and metadata categories independent"] = function()
    local tree = schema_tree.new()
    local first = { schema = "a.b", name = "c", type = "table" }
    local second = { schema = "a", name = "b.c", type = "table" }
    schema_tree.set_tables(tree, { first, second })
    schema_tree.toggle(tree, { kind = "table", row = first })
    assert(not schema_tree.is_expanded(tree, { kind = "table", row = second }))
    assert(schema_tree.is_expanded(tree, { kind = "table", row = vim.deepcopy(first) }))

    local category = { id = "columns", label = "columns" }
    schema_tree.toggle(tree, { kind = "metadata", row = first, category = category })
    assert(not schema_tree.is_expanded(tree, { kind = "metadata", row = second, category = category }))
    schema_tree.set_metadata_loading(tree, first, "columns", true)
    assert(not schema_tree.is_metadata_loading(tree, second, "columns"))
    assert(not schema_tree.is_metadata_loading(tree, first, "primary_keys"))
    schema_tree.set_metadata(tree, first, "columns", { { name = "first_column" } })
    schema_tree.set_metadata_loading(tree, first, "columns", false)
    assert(not schema_tree.is_metadata_loaded(tree, second, "columns"))
    schema_tree.set_metadata(tree, second, "columns", {})
    assert(schema_tree.is_metadata_loaded(tree, second, "columns"))
    assert(not schema_tree.is_metadata_loaded(tree, second, "primary_keys"))

    local lines = schema_tree.lines(tree, profile, "a", { icons = icons })
    assert(table.concat(lines, "\n"):find("first_column", 1, true))
    lines = schema_tree.lines(tree, profile, "b.c", { icons = icons })
    assert(not table.concat(lines, "\n"):find("first_column", 1, true))
  end,

  ["schema_tree preserves expansion when namespace labels change or filtering hides a collision"] = function()
    local tree = schema_tree.new()
    local first = { catalog = "a.b", schema = "c", name = "first", type = "table" }
    local second = { catalog = "a", schema = "b.c", name = "second", type = "table" }
    schema_tree.set_tables(tree, { first })
    local lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(lines[1] == "> @ a.b.c")
    schema_tree.toggle(tree, nodes[1])
    _, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    schema_tree.toggle(tree, nodes[2])

    schema_tree.set_tables(tree, { first, second })
    lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(lines[1] == '> @ "a"."b.c"', vim.inspect(lines))
    assert(lines[2] == 'v @ "a.b"."c"', vim.inspect(lines))
    assert(nodes[4].row == first, "the first namespace's object group stays expanded")

    lines = schema_tree.lines(tree, profile, "second", { icons = icons })
    assert(lines[1] == 'v @ "a"."b.c"')
    lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(lines[1] == '> @ "a"."b.c"', "filtering must not overwrite expansion choices")
    assert(nodes[4].row == first)
  end,

  ["schema_tree.lines renders collapsed schemas and object groups"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, {
      { schema = "main", name = "sessions", type = "table" },
      { schema = "main", name = "active_sessions", type = "view" },
    })

    local lines, nodes, _, has_matches = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(has_matches)
    assert(lines[1] == "> @ main", vim.inspect(lines))
    assert(nodes[1].kind == "schema" and nodes[1].name == "main")
    assert(#lines == 1, "collapsed schema should not reveal its groups")
  end,

  ["schema_tree.toggle expands a schema to reveal its table and view groups"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, {
      { schema = "main", name = "sessions", type = "table" },
      { schema = "main", name = "active_sessions", type = "view" },
    })

    local _, collapsed_nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    schema_tree.toggle(tree, collapsed_nodes[1])
    local lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(lines[1] == "v @ main")
    assert(lines[2] == "  > W tables 1")
    assert(lines[3] == "  > views 1")
    assert(nodes[2].kind == "group" and nodes[2].group == "tables")
    assert(nodes[3].kind == "group" and nodes[3].group == "views")

    schema_tree.toggle(tree, nodes[3])
    lines = schema_tree.lines(tree, profile, "", { icons = icons })
    assert(lines[3] == "  v views 1")
    assert(lines[4] == "    > ~ active_sessions")
  end,

  ["schema_tree.toggle expands an object group to reveal its tables"] = function()
    local tree = schema_tree.new()
    schema_tree.set_tables(tree, { { schema = "main", name = "sessions", type = "table" } })
    expand_tables(tree)

    local lines, nodes = schema_tree.lines(tree, profile, "", { icons = icons })

    assert(lines[2] == "  v W tables 1")
    assert(lines[3] == "    > # sessions")
    assert(nodes[3].kind == "table")
    assert(nodes[3].row.name == "sessions")
  end,

  ["schema_tree.lines highlights semantic icons without coloring labels"] = function()
    local tree = schema_tree.new()
    local colored_icons = vim.tbl_extend("force", icons, { schema = "", table = "󰓫" })
    schema_tree.set_tables(tree, { { schema = "main", name = "sessions", type = "table" } })
    local _, nodes = schema_tree.lines(tree, profile, "", { icons = colored_icons })
    schema_tree.toggle(tree, nodes[1])
    _, nodes = schema_tree.lines(tree, profile, "", { icons = colored_icons })
    schema_tree.toggle(tree, nodes[2])

    local lines, _, highlights = schema_tree.lines(tree, profile, "", { icons = colored_icons })
    local by_group = {}
    for _, highlight in ipairs(highlights) do
      by_group[highlight.group] = highlight
    end

    assert(lines[1] == "v  main")
    assert(vim.deep_equal(by_group.OrbitIconSchema, {
      group = "OrbitIconSchema",
      line = 1,
      col_start = 2,
      col_end = 2 + #colored_icons.schema,
    }))
    assert(vim.deep_equal(by_group.OrbitIconTable, {
      group = "OrbitIconTable",
      line = 3,
      col_start = 6,
      col_end = 6 + #colored_icons.table,
    }))
  end,

  ["schema_tree.toggle expands a table to reveal its metadata categories"] = function()
    local tree = schema_tree.new()
    local row = { schema = "main", name = "sessions", type = "table" }
    schema_tree.set_tables(tree, { row })
    expand_tables(tree)
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
    expand_tables(tree)
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
    local _, nodes = schema_tree.lines(tree, profile, "", { icons = icons })
    schema_tree.toggle(tree, nodes[1])
    schema_tree.set_metadata(tree, row, "columns", { { name = "id" } })
    schema_tree.set_metadata_loading(tree, row, "foreign_keys", true)

    schema_tree.reset(tree)

    assert(#tree.tables == 0)
    assert(not schema_tree.is_expanded(tree, nodes[1]))
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
