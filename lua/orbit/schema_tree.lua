local schema = require("orbit.schema")
local adapters = require("orbit.adapters")

local M = {}

function M.new()
  return {
    expanded = {},
    loading_metadata = {},
    metadata = {},
    tables = {},
  }
end

function M.reset(tree)
  tree.expanded = {}
  tree.loading_metadata = {}
  tree.metadata = {}
  tree.tables = {}
end

function M.set_tables(tree, rows)
  tree.tables = rows
end

function M.object_name(row)
  return table.concat(vim.tbl_filter(function(value)
    return value and value ~= ""
  end, { row.catalog, row.schema, row.name }), ".")
end

local function group_key(schema_name, kind)
  return "group\0" .. schema_name .. "\0" .. kind
end

local function metadata_key(row, category_id)
  return "metadata\0" .. M.object_name(row) .. "\0" .. category_id
end

local function node_key(node)
  if node.kind == "schema" then
    return "schema\0" .. node.name
  end
  if node.kind == "group" then
    return group_key(node.schema, node.group)
  end
  if node.kind == "table" then
    return "table\0" .. M.object_name(node.row)
  end
  if node.kind == "metadata" then
    return metadata_key(node.row, node.category.id)
  end
end

function M.is_expanded(tree, node)
  local key = node_key(node)
  return key ~= nil and tree.expanded[key] or false
end

function M.toggle(tree, node)
  local key = node_key(node)
  if not key then
    return false
  end
  tree.expanded[key] = not tree.expanded[key] or nil
  return tree.expanded[key] or false
end

function M.is_metadata_loaded(tree, row, category_id)
  return tree.metadata[metadata_key(row, category_id)] ~= nil
end

function M.is_metadata_loading(tree, row, category_id)
  return tree.loading_metadata[metadata_key(row, category_id)] or false
end

function M.set_metadata_loading(tree, row, category_id, value)
  tree.loading_metadata[metadata_key(row, category_id)] = value
end

function M.set_metadata(tree, row, category_id, entries)
  tree.metadata[metadata_key(row, category_id)] = entries
end

local function metadata_label(category, row)
  if category == "columns" then
    return string.format("%s  %s", row.name, row.type or "")
  end
  if category == "primary_keys" then
    return string.format("primary key #%s (%s)", row.pk, row.name)
  end
  if category == "foreign_keys" then
    return string.format("foreign key #%s (%s) -> %s (%s)", row.id, row["from"], row.table, row.to)
  end
  if category == "indexes" then
    return row.name
  end
  return vim.inspect(row)
end

local function metadata_entry_icon(icons, category)
  if category == "columns" then
    return icons.column
  end
  if category == "primary_keys" or category == "foreign_keys" then
    return icons.key or icons.folder
  end
  if category == "indexes" then
    return icons.index or icons.folder
  end
  return icons.result
end

function M.lines(tree, profile, filter, options)
  local icons = options.icons
  local lines = {}
  local nodes = {}
  local highlights = {}

  local groups = schema.group(tree.tables, filter)
  if options.loading then
    table.insert(lines, "loading schema...")
  elseif #groups == 0 then
    table.insert(lines, "No matching tables or views")
  end
  for _, schema_group in ipairs(groups) do
    local schema_node = { kind = "schema", name = schema_group.name }
    local schema_expanded = M.is_expanded(tree, schema_node) or filter ~= ""
    table.insert(lines, string.format("%s %s", schema_expanded and icons.expanded or icons.collapsed, schema_group.name))
    nodes[#lines] = schema_node
    for _, kind in ipairs({ "tables", "views" }) do
      local objects = schema_group[kind]
      if schema_expanded and #objects > 0 then
        local group_node = { kind = "group", schema = schema_group.name, group = kind }
        local group_expanded = M.is_expanded(tree, group_node) or filter ~= ""
        table.insert(lines, string.format("  %s %s %d", group_expanded and icons.expanded or icons.collapsed, kind, #objects))
        nodes[#lines] = group_node
        if group_expanded then
          for _, row in ipairs(objects) do
            local object_kind = row.type == "view" and "view" or "table"
            local table_node = { kind = "table", profile = profile, row = row }
            local table_expanded = M.is_expanded(tree, table_node)
            table.insert(lines, string.format("    %s %s %s", table_expanded and icons.expanded or icons.collapsed, icons[object_kind], row.name))
            nodes[#lines] = table_node
            table.insert(highlights, { group = object_kind == "view" and "OrbitView" or "OrbitTable", line = #lines })
            if table_expanded then
              for _, category in ipairs(adapters.metadata_categories(profile, row)) do
                local metadata_node = { category = category, kind = "metadata", profile = profile, row = row }
                local metadata_expanded = M.is_expanded(tree, metadata_node)
                local entries = tree.metadata[metadata_key(row, category.id)]
                local label = entries and string.format("%s %d", category.label, #entries) or category.label
                table.insert(lines, string.format("      %s %s %s", metadata_expanded and icons.expanded or icons.collapsed, icons.folder, label))
                nodes[#lines] = metadata_node
                if metadata_expanded then
                  if entries then
                    for _, entry in ipairs(entries) do
                      table.insert(lines, string.format("        %s %s", metadata_entry_icon(icons, category.id), metadata_label(category.id, entry)))
                      table.insert(highlights, { group = category.id == "columns" and "OrbitColumn" or "OrbitTable", line = #lines })
                    end
                  else
                    table.insert(lines, "        loading " .. category.label .. "...")
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return lines, nodes, highlights, #groups > 0
end

return M
