-- Canonical Table metadata presentation shared by Connector declarations.
-- Connectors still choose which categories apply and in what order; this
-- module keeps each recognized category's row meaning in one place.
local M = {}

local definitions = {
	columns = {
		label = "columns",
		format = function(entry) return string.format("%s  %s", entry.name, entry.type or "") end,
		icons = { "column", "result" },
		row_highlight = "OrbitColumn",
		icon_highlight = "OrbitIconColumn",
	},
	primary_keys = {
		label = "primary keys",
		format = function(entry) return string.format("primary key #%s (%s)", entry.pk, entry.name) end,
		icons = { "key", "folder", "result" },
		icon_highlight = "OrbitIconKey",
	},
	foreign_keys = {
		label = "foreign keys",
		format = function(entry)
			return string.format("foreign key #%s (%s) -> %s (%s)", entry.id, entry["from"], entry.table, entry.to)
		end,
		icons = { "key", "folder", "result" },
		icon_highlight = "OrbitIconKey",
	},
	indexes = {
		label = "indexes",
		format = function(entry) return entry.name end,
		icons = { "index", "folder", "result" },
		icon_highlight = "OrbitIconIndex",
	},
	projections = {
		label = "projections",
		format = function(entry) return entry.name end,
		icons = { "result" },
		icon_highlight = "OrbitIconResult",
	},
}

function M.known(id)
	return definitions[id] ~= nil
end

-- Return a fresh descriptor so callers cannot mutate another Connector's
-- declaration through a shared presentation table.
function M.category(id)
	local definition = assert(definitions[id], "unknown Table metadata category: " .. tostring(id))
	return {
		id = id,
		label = definition.label,
		presentation = {
			format = definition.format,
			icons = vim.deepcopy(definition.icons),
			row_highlight = definition.row_highlight,
			icon_highlight = definition.icon_highlight,
		},
	}
end

return M
