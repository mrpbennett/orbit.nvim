-- orbit/connectors/utils/rows.lua
--
-- The Result row interface every Connector parser must produce: a list of
-- row tables whose keys are non-empty column-name strings. The runner calls
-- M.normalize after every parse, so no caller ever sees a malformed row.
local M = {}

-- Enforce the row-map interface after every Connector parser. This is the
-- final guard before callers treat each entry as a Result row.
function M.normalize(rows)
	if type(rows) ~= "table" or not vim.islist(rows) then
		return nil, "CLI output rows must be a list"
	end
	for row_index, row in ipairs(rows) do
		if type(row) ~= "table" or (next(row) ~= nil and vim.islist(row)) then
			return nil, string.format("CLI output row %d must be an object", row_index)
		end
		for key in pairs(row) do
			if type(key) ~= "string" or key == "" then
				return nil, string.format("CLI output row %d has an invalid column name", row_index)
			end
		end
	end
	return rows
end

return M
