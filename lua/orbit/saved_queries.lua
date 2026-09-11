-- Filesystem and buffer transactions for saved queries. Workspace owns the UI
-- around these operations; this module keeps path checks and rollback rules in
-- one place so every caller gets the same safety guarantees.
local M = {}

local function same_file(left, right)
	return left and right and left.type == right.type and left.dev == right.dev and left.ino == right.ino
end

-- Discover SQL files without following symlinks. Directories are listed before
-- files and both groups are sorted case-insensitively for stable rendering.
function M.discover(directory, root_path)
	root_path = root_path or directory
	local root_stat = vim.uv.fs_stat(root_path)
	local root_realpath = vim.uv.fs_realpath(root_path)
	if not root_stat or not root_realpath then
		return {}
	end
	local function scan(path)
		local handle = vim.uv.fs_scandir(path)
		if not handle then
			return {}
		end

		local entries = {}
		while true do
			local name, kind = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local entry_path = path .. "/" .. name
			if kind == "directory" then
				local children = scan(entry_path)
				if #children > 0 then
					table.insert(entries, {
						children = children,
						kind = "saved_directory",
						name = name,
						path = entry_path,
						root_path = root_path,
					})
				end
			elseif kind == "file" and name:lower():sub(-4) == ".sql" then
				local stat = vim.uv.fs_lstat(entry_path)
				if stat and stat.type == "file" then
					table.insert(entries, {
						kind = "saved_query",
						name = name,
						path = entry_path,
						root_path = root_path,
						root_stat = root_stat,
						root_realpath = root_realpath,
						stat = stat,
					})
				end
			end
		end
		table.sort(entries, function(left, right)
			if left.kind ~= right.kind then
				return left.kind == "saved_directory"
			end
			return left.name:lower() < right.name:lower()
		end)
		return entries
	end

	return scan(directory)
end

-- Enumerate real descendant directories in configured location order. lstat
-- excludes descendant symlinks so a selected directory cannot escape its root.
function M.directories(locations)
	local directories = {}
	local function scan(location, path, segments, ancestors)
		local path_stat = path == location.path and vim.uv.fs_stat(path) or vim.uv.fs_lstat(path)
		local root_stat = vim.uv.fs_stat(location.path)
		local realpath = vim.uv.fs_realpath(path)
		local root_realpath = vim.uv.fs_realpath(location.path)
		if not path_stat or path_stat.type ~= "directory" or not root_stat or not realpath or not root_realpath then
			return
		end
		table.insert(directories, {
			ancestors = vim.deepcopy(ancestors),
			identity = { path = path_stat, root = root_stat, realpath = realpath, root_realpath = root_realpath },
			label = location.name .. (#segments > 0 and " / " .. table.concat(segments, " / ") or ""),
			location = location,
			path = path,
		})
		local handle = vim.uv.fs_scandir(path)
		if not handle then
			return
		end
		local children = {}
		while true do
			local name, kind = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if kind == "directory" then
				table.insert(children, name)
			end
		end
		table.sort(children, function(left, right)
			local left_lower, right_lower = left:lower(), right:lower()
			return left_lower == right_lower and left < right or left_lower < right_lower
		end)
		for _, name in ipairs(children) do
			local child_path = path .. "/" .. name
			scan(
				location,
				child_path,
				vim.list_extend(vim.deepcopy(segments), { name }),
				vim.list_extend(vim.deepcopy(ancestors), { child_path })
			)
		end
	end

	-- ipairs intentionally preserves ADR-0001's configured location order.
	for _, location in ipairs(locations) do
		local stat = vim.uv.fs_stat(location.path)
		if stat and stat.type == "directory" then
			scan(location, location.path, {}, { location.path })
		end
	end
	return directories
end

function M.filename(filename)
	if filename:match("^%s*$") or filename == "." or filename == ".." or filename:find("[/\\%c]") then
		return nil
	end
	return filename:lower():sub(-4) == ".sql" and filename or filename .. ".sql"
end

function M.directory_available(directory)
	local stat = directory.path == directory.location.path and vim.uv.fs_stat(directory.path)
		or vim.uv.fs_lstat(directory.path)
	if not stat or stat.type ~= "directory" then
		return false
	end
	local root = vim.uv.fs_realpath(directory.location.path)
	local path = vim.uv.fs_realpath(directory.path)
	if not root or not path then
		return false
	end
	local root_prefix = root:sub(-1) == "/" and root or root .. "/"
	if path ~= root and path:sub(1, #root_prefix) ~= root_prefix then
		return false
	end
	local root_stat = vim.uv.fs_stat(directory.location.path)
	if not root_stat then
		return false
	end
	if directory.identity then
		return same_file(stat, directory.identity.path)
			and same_file(root_stat, directory.identity.root)
			and path == directory.identity.realpath
			and root == directory.identity.root_realpath
	end
	directory.identity = { path = stat, root = root_stat, realpath = path, root_realpath = root }
	return true
end

function M.refresh(locations)
	-- Every root must be rescanned because configured locations may overlap.
	for _, location in ipairs(locations) do
		location.children = M.discover(location.path)
	end
end

local function loaded_buffer(path)
	for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(buffer)
			and vim.api.nvim_buf_is_loaded(buffer)
			and vim.api.nvim_buf_get_name(buffer) == path
		then
			return buffer
		end
	end
end

local function source_available(node)
	local stat = vim.uv.fs_lstat(node.path)
	if not stat or stat.type ~= "file" or (node.stat and not same_file(stat, node.stat)) then
		return nil
	end
	if not node.root_stat then
		return stat
	end
	local root_stat = vim.uv.fs_stat(node.root_path)
	local root_realpath = vim.uv.fs_realpath(node.root_path)
	local parent_realpath = vim.uv.fs_realpath(vim.fs.dirname(node.path))
	local prefix = node.root_realpath:sub(-1) == "/" and node.root_realpath or node.root_realpath .. "/"
	if
		not same_file(root_stat, node.root_stat)
		or root_realpath ~= node.root_realpath
		or not parent_realpath
		or (parent_realpath ~= node.root_realpath and parent_realpath:sub(1, #prefix) ~= prefix)
	then
		return nil
	end
	return stat
end

-- Move a verified path to a private sibling on the same filesystem. Later
-- operations use this stable path, so replacing the public path cannot make
-- Orbit mutate a different file after validation.
local function quarantine(path, expected)
	local descriptor, staged = vim.uv.fs_mkstemp(vim.fs.dirname(path) .. "/.orbit-XXXXXX")
	if not descriptor then
		return nil, staged
	end
	vim.uv.fs_close(descriptor)
	local moved, move_error = vim.uv.fs_rename(path, staged)
	if not moved then
		local removed, remove_error = vim.uv.fs_unlink(staged)
		return nil, tostring(move_error)
			.. (not removed and "; temporary file cleanup failed: " .. tostring(remove_error) .. " at " .. staged or "")
	end
	if not same_file(vim.uv.fs_lstat(staged), expected) then
		local restored, restore_error
		if vim.uv.fs_lstat(path) then
			restore_error = "original path is occupied; verified file remains at " .. staged
		else
			restored, restore_error = vim.uv.fs_link(staged, path)
			if restored then
				local removed, remove_error = vim.uv.fs_unlink(staged)
				if not removed then
					restored, restore_error = nil, "temporary cleanup failed: " .. tostring(remove_error)
				end
			end
		end
		return nil, "the file changed before it could be secured"
			.. (not restored and "; restore failed: " .. tostring(restore_error) or "")
	end
	return { path = staged, original = path, stat = expected }
end

local function restore_quarantine(staging)
	if not same_file(vim.uv.fs_lstat(staging.path), staging.stat) then
		return nil, "verified file changed before restore: " .. staging.path
	end
	local restored, restore_error = vim.uv.fs_link(staging.path, staging.original)
	if not restored then
		return nil, tostring(restore_error) .. "; verified file remains at " .. staging.path
	end
	local removed, remove_error = vim.uv.fs_unlink(staging.path)
	if not removed then
		return true, "restored original path but temporary cleanup failed: " .. tostring(remove_error)
	end
	return true
end

local function discard_quarantine(staging)
	if not same_file(vim.uv.fs_lstat(staging.path), staging.stat) then
		return nil, "temporary file identity changed: " .. staging.path
	end
	local removed, remove_error = vim.uv.fs_unlink(staging.path)
	if not removed then
		return nil, remove_error
	end
	return true
end

local function remove_verified(path, expected)
	if not same_file(vim.uv.fs_lstat(path), expected) then
		return nil, "file identity changed and was not removed: " .. path
	end
	local staging, staging_error = quarantine(path, expected)
	if not staging then
		return nil, staging_error
	end
	return discard_quarantine(staging)
end

-- Create a destination exclusively from a quarantined source. The source is
-- retained until buffer synchronization succeeds, making rollback possible.
local function copy_exclusive(source, destination)
	local source_descriptor, source_error = vim.uv.fs_open(source, "r", 0)
	if not source_descriptor then
		return nil, source_error
	end
	local source_stat = vim.uv.fs_fstat(source_descriptor)
	local mode = source_stat and bit.band(source_stat.mode, 511) or 384
	local destination_descriptor, destination_error = vim.uv.fs_open(destination, "wx", mode)
	if not destination_descriptor then
		vim.uv.fs_close(source_descriptor)
		return nil, destination_error
	end

	local offset, copy_error = 0, nil
	while true do
		local data, read_error = vim.uv.fs_read(source_descriptor, 65536, offset)
		if not data then
			copy_error = read_error
			break
		end
		if data == "" then
			break
		end
		local written, write_error = vim.uv.fs_write(destination_descriptor, data, offset)
		if not written or written ~= #data then
			copy_error = write_error or "short write"
			break
		end
		offset = offset + written
	end
	local destination_stat = vim.uv.fs_fstat(destination_descriptor)
	vim.uv.fs_close(source_descriptor)
	vim.uv.fs_close(destination_descriptor)
	if copy_error then
		return nil, copy_error, destination_stat
	end
	return true, destination_stat
end

local function rollback_relocation(staging, destination, destination_stat, buffer)
	local errors = {}
	local current_destination = vim.uv.fs_lstat(destination)
	if current_destination then
		if same_file(current_destination, destination_stat) then
			local removed, remove_error = remove_verified(destination, destination_stat)
			if not removed then
				table.insert(errors, "destination cleanup failed: " .. tostring(remove_error))
			end
		else
			table.insert(errors, "destination was replaced and was not removed")
		end
	end
	local restored, restore_error = restore_quarantine(staging)
	if not restored then
		table.insert(errors, "source restore failed: " .. tostring(restore_error))
	elseif restore_error then
		table.insert(errors, restore_error)
	end
	if buffer and vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_get_name(buffer) ~= staging.original then
		local renamed, rename_error = pcall(vim.api.nvim_buf_set_name, buffer, staging.original)
		if not renamed then
			table.insert(errors, "buffer restore failed: " .. tostring(rename_error))
		end
	end
	return #errors == 0 and "filesystem change was rolled back" or table.concat(errors, "; ")
end

function M.relocate(node, destination, directory)
	local source_stat = source_available(node)
	local expected_source = node.stat or source_stat
	if not source_stat or source_stat.type ~= "file" or not same_file(source_stat, expected_source) then
		return nil, "the saved query no longer exists"
	end
	if not M.directory_available(directory) then
		return nil, "destination directory is no longer available"
	end
	if destination == node.path then
		return true, "unchanged"
	end
	if vim.uv.fs_lstat(destination) then
		return nil, "destination already exists: " .. destination
	end

	if vim.fs.dirname(destination) ~= directory.path then
		return nil, "destination is outside the selected directory"
	end
	local source_buffer = loaded_buffer(node.path)
	local destination_buffer = loaded_buffer(destination)
	if destination_buffer and destination_buffer ~= source_buffer then
		return nil, "destination is already loaded: " .. destination
	end

	local staging, staging_error = quarantine(node.path, expected_source)
	if not staging then
		return nil, tostring(staging_error)
	end
	local copied, copy_result, partial_stat = copy_exclusive(staging.path, destination)
	local destination_stat = copied and copy_result or partial_stat
	local copy_error = not copied and copy_result or nil
	if
		not copied
		or not destination_stat
		or destination_stat.type ~= "file"
		or not M.directory_available(directory)
	then
		local rollback = rollback_relocation(staging, destination, destination_stat)
		return nil, tostring(copy_error or "destination directory changed during the move")
			.. "; " .. rollback
	end
	if source_buffer then
		local renamed, rename_error = pcall(vim.api.nvim_buf_set_name, source_buffer, destination)
		if not renamed then
			local rollback = rollback_relocation(staging, destination, destination_stat)
			return nil, "failed to update the open buffer: " .. tostring(rename_error) .. "; " .. rollback, "buffer"
		end
	end
	if not same_file(vim.uv.fs_lstat(destination), destination_stat) then
		return nil, "destination changed during the move; "
			.. rollback_relocation(staging, destination, destination_stat, source_buffer)
	end
	local removed, remove_error = discard_quarantine(staging)
	if not removed then
		return nil, tostring(remove_error) .. "; " .. rollback_relocation(staging, destination, destination_stat, source_buffer)
	end
	return true
end

-- Capture the file identity and open buffer before confirmation. The identity
-- is checked again by delete so a replaced file is never removed accidentally.
function M.deletion(target)
	local node = type(target) == "table" and target or { path = target }
	local path = node.path
	local stat = source_available(node)
	if not stat or stat.type ~= "file" then
		return nil, "the saved query no longer exists"
	end
	local buffer = loaded_buffer(path)
	return { buffer = buffer, modified = buffer and vim.bo[buffer].modified or false, stat = stat }
end

function M.delete(path, deletion)
	local confirmed = vim.uv.fs_lstat(path)
	if not same_file(confirmed, deletion.stat) then
		return nil, "the file changed while awaiting confirmation"
	end

	local buffer = loaded_buffer(path)
	local staging, staging_error = quarantine(path, deletion.stat)
	if not staging then
		return nil, tostring(staging_error)
	end
	if buffer then
		local unnamed, unnamed_error = pcall(vim.api.nvim_buf_set_name, buffer, "")
		if not unnamed then
			local _, restore_error = restore_quarantine(staging)
			return nil, "failed to preserve its open buffer: " .. tostring(unnamed_error)
				.. (restore_error and "; restore failed: " .. tostring(restore_error) or ""), "buffer"
		end
	end
	local removed, remove_error = discard_quarantine(staging)
	if removed then
		return true
	end

	local restored, restore_error = restore_quarantine(staging)
	local buffer_restored, buffer_restore_error
	if buffer and restored then
		buffer_restored, buffer_restore_error = pcall(vim.api.nvim_buf_set_name, buffer, path)
	end
	local detail = not restored and "; file restore failed: " .. tostring(restore_error)
		or (restore_error and "; " .. restore_error or "")
	if buffer and restored and not buffer_restored then
		detail = detail .. "; buffer name restore failed: " .. tostring(buffer_restore_error)
	end
	return nil, tostring(remove_error) .. detail
end

function M.save_destination(path)
	local stat = vim.uv.fs_lstat(path)
	if stat and stat.type == "link" then
		return nil, "will not replace a symbolic link"
	end
	if stat and stat.type ~= "file" then
		return nil, "destination is not a file: " .. path
	end
	return stat
end

local function rollback_save(buffer, original, destination, written_stat, staging)
	local errors = {}
	local current = vim.uv.fs_lstat(destination)
	if current then
		if written_stat and same_file(current, written_stat) then
			local removed, remove_error = remove_verified(destination, written_stat)
			if not removed then table.insert(errors, "written file cleanup failed: " .. tostring(remove_error)) end
		else
			table.insert(errors, "destination was replaced and was not removed")
		end
	end
	if staging then
		local restored, restore_error = restore_quarantine(staging)
		if not restored then table.insert(errors, "replaced file restore failed: " .. tostring(restore_error)) end
		if restored and restore_error then table.insert(errors, restore_error) end
	end
	local renamed, rename_error = pcall(vim.api.nvim_buf_set_name, buffer, original.name)
	if not renamed then table.insert(errors, "buffer name restore failed: " .. tostring(rename_error)) end
	vim.bo[buffer].modified = original.modified
	return table.concat(errors, "; ")
end

function M.save(buffer, destination, expected, directory)
	if not vim.api.nvim_buf_is_valid(buffer) then
		return nil, "query buffer is no longer available"
	end
	if not M.directory_available(directory) or vim.fs.dirname(destination) ~= directory.path then
		return nil, "destination directory is no longer available"
	end
	local current = vim.uv.fs_lstat(destination)
	if
		(expected == nil and current ~= nil)
		or (expected ~= nil and current == nil)
		or (
			expected
			and current
			and (expected.type ~= current.type or expected.dev ~= current.dev or expected.ino ~= current.ino)
		)
	then
		return nil, "destination changed while awaiting confirmation"
	end
	local staging
	local original = { name = vim.api.nvim_buf_get_name(buffer), modified = vim.bo[buffer].modified }
	if expected then
		local staging_error
		staging, staging_error = quarantine(destination, expected)
		if not staging then
			return nil, "destination changed while awaiting confirmation: " .. tostring(staging_error)
		end
	end

	local descriptor, temporary = vim.uv.fs_mkstemp(directory.path .. "/.orbit-save-XXXXXX")
	if not descriptor then
		local rollback = rollback_save(buffer, original, destination, nil, staging)
		return nil, "could not create a private save file: " .. tostring(temporary)
			.. (rollback ~= "" and "; " .. rollback or "")
	end
	vim.uv.fs_close(descriptor)
	local ok, err = pcall(function()
		vim.api.nvim_buf_call(buffer, function()
			vim.api.nvim_cmd({ cmd = "write", args = { temporary }, bang = true }, {})
		end)
	end)
	local temporary_stat = vim.uv.fs_lstat(temporary)
	if not ok then
		local cleanup_error
		if temporary_stat then
			local removed
			removed, cleanup_error = remove_verified(temporary, temporary_stat)
			if removed then cleanup_error = nil end
		end
		local rollback = rollback_save(buffer, original, destination, nil, staging)
		return nil, "failed: " .. tostring(err) .. (rollback ~= "" and "; " .. rollback or "")
			.. (cleanup_error and "; private file cleanup failed: " .. tostring(cleanup_error) or "")
	end
	if not temporary_stat or temporary_stat.type ~= "file" or not M.directory_available(directory) then
		local cleanup_error = temporary_stat and select(2, remove_verified(temporary, temporary_stat)) or nil
		local rollback = rollback_save(buffer, original, destination, nil, staging)
		return nil, "destination directory changed during save"
			.. (rollback ~= "" and "; " .. rollback or "")
			.. (cleanup_error and "; private file cleanup failed: " .. tostring(cleanup_error) or "")
	end
	local linked, link_error = vim.uv.fs_link(temporary, destination)
	local written_stat = temporary_stat
	if not linked or not same_file(vim.uv.fs_lstat(destination), written_stat) or not M.directory_available(directory) then
		local cleanup_error = select(2, remove_verified(temporary, temporary_stat))
		local rollback = rollback_save(buffer, original, destination, temporary_stat, staging)
		return nil, "failed to publish saved query: " .. tostring(link_error or "destination changed")
			.. (rollback ~= "" and "; " .. rollback or "")
			.. (cleanup_error and "; private file cleanup failed: " .. tostring(cleanup_error) or "")
	end
	local renamed, rename_error = pcall(vim.api.nvim_buf_set_name, buffer, destination)
	if not renamed then
		local cleanup_error = select(2, remove_verified(temporary, temporary_stat))
		local rollback = rollback_save(buffer, original, destination, written_stat, staging)
		return nil, "failed to update the query buffer: " .. tostring(rename_error)
			.. (rollback ~= "" and "; " .. rollback or "")
			.. (cleanup_error and "; private file cleanup failed: " .. tostring(cleanup_error) or "")
	end
	local reloaded, reload_error = pcall(function()
		vim.api.nvim_buf_call(buffer, function()
			vim.api.nvim_cmd({ cmd = "edit", args = { destination }, bang = true }, {})
		end)
	end)
	if not reloaded then
		local cleanup_error = select(2, remove_verified(temporary, temporary_stat))
		local rollback = rollback_save(buffer, original, destination, written_stat, staging)
		return nil, "failed to finalize the query buffer: " .. tostring(reload_error)
			.. (rollback ~= "" and "; " .. rollback or "")
			.. (cleanup_error and "; private file cleanup failed: " .. tostring(cleanup_error) or "")
	end
	local temporary_removed, temporary_error = remove_verified(temporary, temporary_stat)
	if not temporary_removed then
		return true, "could not remove the private save file: " .. tostring(temporary_error)
	end
	if staging then
		local removed, remove_error = discard_quarantine(staging)
		if not removed then
			return true, "could not remove the replaced file: " .. tostring(remove_error)
				.. "; it remains at " .. staging.path
		end
	end
	return true
end

return M
