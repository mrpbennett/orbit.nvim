local saved_queries = require("orbit.saved_queries")

local function location(name, path)
  return { name = name, path = path }
end

return {
  ["saved queries discover SQL files safely and sort directories first"] = function()
    local root = vim.fn.tempname()
    local nested = root .. "/Zulu"
    assert(vim.fn.mkdir(nested, "p") == 1)
    vim.fn.writefile({ "SELECT 1;" }, root .. "/alpha.sql")
    vim.fn.writefile({ "SELECT 2;" }, nested .. "/nested.SQL")
    vim.fn.writefile({ "ignored" }, root .. "/notes.txt")
    assert(vim.uv.fs_symlink(root .. "/alpha.sql", root .. "/linked.sql"))

    local entries = saved_queries.discover(root)

    assert(#entries == 2)
    assert(entries[1].kind == "saved_directory" and entries[1].name == "Zulu")
    assert(entries[1].children[1].name == "nested.SQL")
    assert(entries[2].kind == "saved_query" and entries[2].name == "alpha.sql")
  end,

  ["saved queries enumerate directories in configured order without symlink descendants"] = function()
    local first = vim.fn.tempname()
    local second = vim.fn.tempname()
    assert(vim.fn.mkdir(first .. "/b/A", "p") == 1)
    assert(vim.fn.mkdir(first .. "/B", "p") == 1)
    assert(vim.fn.mkdir(second .. "/child", "p") == 1)
    assert(vim.uv.fs_symlink(second .. "/child", first .. "/linked"))

    local directories = saved_queries.directories({ location("First", first), location("Second", second) })
    local labels = {}
    for _, directory in ipairs(directories) do
      table.insert(labels, directory.label)
    end

    assert(vim.deep_equal(labels, {
      "First",
      "First / B",
      "First / b",
      "First / b / A",
      "Second",
      "Second / child",
    }), vim.inspect(labels))
  end,

  ["saved queries validate filenames without accepting paths"] = function()
    assert(saved_queries.filename("report") == "report.sql")
    assert(saved_queries.filename("REPORT.SQL") == "REPORT.SQL")
    for _, invalid in ipairs({ "", "  ", ".", "..", "../report", "folder\\report", "bad\nname" }) do
      assert(saved_queries.filename(invalid) == nil, vim.inspect(invalid))
    end
  end,

  ["saved query relocation removes a copied destination when source unlink fails"] = function()
    local original_link = vim.uv.fs_link
    local original_unlink = vim.uv.fs_unlink
    local root = vim.fn.tempname()
    local destination_root = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(root, 448))
    assert(vim.uv.fs_mkdir(destination_root, 448))
    local source = root .. "/source.sql"
    local destination = destination_root .. "/source.sql"
    vim.fn.writefile({ "SELECT 1;" }, source)
    local directory = { location = location("Destination", destination_root), path = destination_root }
    local ok, err = xpcall(function()
		vim.uv.fs_link = function(source_path, destination_path)
			if destination_path == destination then
				return nil, "EXDEV", "EXDEV"
			end
			return original_link(source_path, destination_path)
      end
      vim.uv.fs_unlink = function(path)
        if path:find("/.orbit%-") then
          return nil, "EACCES: permission denied", "EACCES"
        end
        return original_unlink(path)
      end

      local moved, move_error = saved_queries.relocate({ path = source }, destination, directory)

      assert(not moved and move_error:match("permission denied"), tostring(move_error))
      assert(vim.uv.fs_stat(source))
      assert(vim.uv.fs_stat(destination) == nil)
    end, debug.traceback)
    vim.uv.fs_link = original_link
    vim.uv.fs_unlink = original_unlink
    assert(ok, err)
  end,

	["saved query deletion restores an open buffer name when unlink fails"] = function()
    local original_unlink = vim.uv.fs_unlink
    local root = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(root, 448))
    local path = root .. "/open.sql"
    vim.fn.writefile({ "SELECT 1;" }, path)
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    local ok, err = xpcall(function()
      local deletion = assert(saved_queries.deletion(path))
      assert(deletion.buffer == buffer)
      vim.uv.fs_unlink = function(target)
        if target:find("/.orbit%-") then
          return nil, "EACCES: permission denied", "EACCES"
        end
        return original_unlink(target)
      end

      local deleted, delete_error = saved_queries.delete(path, deletion)

      assert(not deleted and delete_error:match("permission denied"), tostring(delete_error))
      assert(vim.api.nvim_buf_get_name(buffer) == path)
      assert(vim.uv.fs_stat(path))
    end, debug.traceback)
    vim.uv.fs_unlink = original_unlink
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
		assert(ok, err)
	end,

	["saved query mutations keep replacements at the public path"] = function()
		local original_rename = vim.uv.fs_rename
		local root = vim.fn.tempname()
		local destination_root = vim.fn.tempname()
		assert(vim.uv.fs_mkdir(root, 448))
		assert(vim.uv.fs_mkdir(destination_root, 448))
		local delete_path = root .. "/delete.sql"
		local move_path = root .. "/move.sql"
		local destination = destination_root .. "/move.sql"
		vim.fn.writefile({ "original delete" }, delete_path)
		vim.fn.writefile({ "original move" }, move_path)
		local ok, err = xpcall(function()
			vim.uv.fs_rename = function(source, target)
				local moved, move_error, move_name = original_rename(source, target)
				if moved and (source == delete_path or source == move_path) then
					vim.fn.writefile({ "replacement" }, source)
				end
				return moved, move_error, move_name
			end

			local deletion = assert(saved_queries.deletion(delete_path))
			assert(saved_queries.delete(delete_path, deletion))
			assert(vim.fn.readfile(delete_path)[1] == "replacement")

			local directory = { location = location("Destination", destination_root), path = destination_root }
			assert(saved_queries.relocate({ path = move_path }, destination, directory))
			assert(vim.fn.readfile(move_path)[1] == "replacement")
			assert(vim.fn.readfile(destination)[1] == "original move")
		end, debug.traceback)
		vim.uv.fs_rename = original_rename
		assert(ok, err)
	end,

	["saved query saving refuses a destination replaced after confirmation"] = function()
    local root = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(root, 448))
    local destination = root .. "/existing.sql"
    local replacement = root .. "/replacement.sql"
    vim.fn.writefile({ "SELECT 'old';" }, destination)
    local expected = assert(saved_queries.save_destination(destination))
    assert(vim.uv.fs_unlink(destination))
    vim.fn.writefile({ "SELECT 'replacement';" }, replacement)
    assert(vim.uv.fs_rename(replacement, destination))
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "SELECT 'new';" })
		local directory = { location = location("Root", root), path = root }

		local ok, err = xpcall(function()
			local saved, save_error = saved_queries.save(buffer, destination, expected, directory)
			assert(not saved and save_error == "destination changed while awaiting confirmation", tostring(save_error))
			assert(vim.fn.readfile(destination)[1] == "SELECT 'replacement';")
			assert(vim.api.nvim_buf_get_name(buffer) == "")
		end, debug.traceback)
		if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
		assert(ok, err)
  end,
}
