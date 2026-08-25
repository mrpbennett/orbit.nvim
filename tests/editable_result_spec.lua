local editable_result = require("orbit.editable_result")

return {
  ["editable results retain deleted rows outside the visible order"] = function()
    local result = editable_result.new({ { id = 1 }, { id = 2 }, { id = 3 } })
    local visible = editable_result.visible_rows(result)

    editable_result.delete(result, { visible[2].id })

    assert(vim.deep_equal(vim.tbl_map(function(row)
      return row.values.id
    end, editable_result.visible_rows(result)), { 1, 3 }))
    assert(editable_result.changes(result).deleted[1].values.id == 2)
    assert(editable_result.changed(result))
  end,

  ["editable results insert above and below visible rows"] = function()
    local result = editable_result.new({ { id = 1 }, { id = 2 } })
    editable_result.insert(result, 1)
    editable_result.insert_before(result, 2)

    local rows = editable_result.visible_rows(result)
    assert(vim.deep_equal(vim.tbl_map(function(row)
      return row.state
    end, rows), { "unchanged", "inserted", "inserted", "unchanged" }))
  end,

  ["editable results track cell edits and undo local mutations"] = function()
    local result = editable_result.new({ { id = 1, name = "Alice" } })
    local row = editable_result.visible_rows(result)[1]

    assert(editable_result.set_value(result, row.id, "name", "Ada"))
    assert(editable_result.row(result, row.id).state == "modified")
    assert(editable_result.undo(result))
    assert(editable_result.row(result, row.id).values.name == "Alice")
    assert(not editable_result.changed(result))
  end,

  ["deleting an inserted row cancels its pending insert"] = function()
    local result = editable_result.new({ { id = 1 } })
    local inserted = editable_result.insert(result, 1)

    editable_result.delete(result, { inserted.id })

    assert(#editable_result.changes(result).inserted == 0)
    assert(#editable_result.changes(result).deleted == 0)
  end,
}
