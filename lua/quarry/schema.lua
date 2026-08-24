local M = {}

function M.filter(rows, query)
	query = vim.trim(query or ""):lower()
	if query == "" then
		return rows
	end

	local matches = {}
	for _, row in ipairs(rows) do
		if row.name:lower():find(query, 1, true) then
			table.insert(matches, row)
		end
	end
	return matches
end

function M.group(rows, query)
	query = vim.trim(query or ""):lower()
	local by_schema = {}
	for _, row in ipairs(rows) do
		local schema_name = row.schema or "main"
		local schema_matches = query == "" or schema_name:lower():find(query, 1, true)
		local object_matches = query == "" or row.name:lower():find(query, 1, true)
		if schema_matches or object_matches then
			local group = by_schema[schema_name] or { name = schema_name, tables = {}, views = {} }
			by_schema[schema_name] = group
			table.insert(group[row.type == "view" and "views" or "tables"], row)
		end
	end
	local groups = {}
	for _, group in pairs(by_schema) do
		table.sort(group.tables, function(left, right)
			return left.name < right.name
		end)
		table.sort(group.views, function(left, right)
			return left.name < right.name
		end)
		table.insert(groups, group)
	end
	table.sort(groups, function(left, right)
		return left.name < right.name
	end)
	return groups
end

return M
