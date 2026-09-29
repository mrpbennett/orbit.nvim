local sidebar_tree = require("orbit.sidebar_tree")
local schema_tree = require("orbit.schema_tree")

local icons = {
	collapsed = ">",
	column = ":",
	expanded = "v",
	folder = "+",
	profile = "@",
	saved_query = "#",
	schema = "@",
	table = "#",
	view = "~",
	workspace = "*",
}

local sqlite = { name = "local", kind = "sqlite", options = { path = ":memory:" } }
local cache = { name = "cache", kind = "redis", options = { host = "localhost" } }

-- A model shaped like the Workspace state table, with nothing expanded.
local function model(overrides)
	return vim.tbl_extend("force", {
		profiles = { sqlite, cache },
		selected = nil,
		filter = "",
		loading = false,
		schema_profile = nil,
		tree = schema_tree.new(),
		saved_query_locations = {},
		expanded_saved_dirs = {},
	}, overrides or {})
end

local function saved_location()
	return {
		name = "Work",
		path = "/sql/work",
		children = {
			{
				kind = "saved_directory",
				name = "reports",
				path = "/sql/work/reports",
				root_path = "/sql/work",
				children = {
					{ kind = "saved_query", name = "daily.sql", path = "/sql/work/reports/daily.sql", root_path = "/sql/work" },
				},
			},
			{ kind = "saved_query", name = "scratch.sql", path = "/sql/work/scratch.sql", root_path = "/sql/work" },
		},
	}
end

return {
	["sidebar_tree renders title and collapsed profiles with line-keyed nodes"] = function()
		local lines, nodes, highlights = sidebar_tree.lines(model(), { icons = icons })
		assert(lines[1] == "* Orbit Workspace", lines[1])
		assert(lines[3] == "Profiles:")
		assert(lines[4] == "  > @ local (sqlite)", lines[4])
		assert(lines[5] == "  > @ cache (redis)", lines[5])
		assert(nodes[4].kind == "profile" and nodes[4].profile == sqlite)
		assert(nodes[5].profile == cache)
		assert(highlights[1].group == "OrbitIconWorkspace" and highlights[1].line == 1)

		lines = sidebar_tree.lines(model({ selected = sqlite }), { icons = icons })
		assert(lines[1] == "@ local", lines[1])
	end,

	["sidebar_tree filters profiles by name or kind"] = function()
		local lines = sidebar_tree.lines(model({ filter = "REDIS" }), { icons = icons })
		assert(#lines == 4, vim.inspect(lines))
		assert(lines[4]:match("cache"))
	end,

	["sidebar_tree shows the expanded Redis profile's key index status"] = function()
		local lines = sidebar_tree.lines(model({ schema_profile = "cache" }), {
			icons = icons,
			redis_status = function(profile)
				assert(profile == cache)
				return { loaded = true, count = 12, truncated = true }
			end,
		})
		assert(lines[5] == "  v @ cache (redis)", lines[5])
		assert(lines[6] == "    Redis keys: 12 (truncated)", lines[6])

		lines = sidebar_tree.lines(model({ schema_profile = "cache", loading = true }), { icons = icons })
		assert(lines[6] == "    Redis keys: loading", lines[6])
		lines = sidebar_tree.lines(model({ schema_profile = "cache" }), { icons = icons })
		assert(lines[6] == "    Redis keys: not loaded", lines[6])
	end,

	["sidebar_tree splices the expanded schema tree with shifted lines and indent"] = function()
		local m = model({ schema_profile = "local" })
		schema_tree.set_tables(m.tree, { { schema = "main", name = "sessions", type = "table" } })
		local lines, nodes, highlights = sidebar_tree.lines(m, { icons = icons })
		assert(lines[4] == "  v @ local (sqlite)", lines[4])
		assert(nodes[5] and nodes[5].kind == "schema", vim.inspect(nodes[5]))
		assert(lines[5]:sub(1, 4) == "    ", lines[5])
		for _, highlight in ipairs(highlights) do
			if highlight.line == 5 and highlight.col_start then
				assert(highlight.col_start >= 4, vim.inspect(highlight))
			end
		end
		-- The collapsed Redis profile follows the spliced schema lines.
		assert(nodes[#lines].profile == cache)
	end,

	["sidebar_tree filters saved queries while keeping and opening matching folders"] = function()
		local m = model({ profiles = {}, saved_query_locations = { saved_location() } })
		local lines = sidebar_tree.lines(m, { icons = icons })
		assert(lines[#lines] == "  > + Work", vim.inspect(lines))

		m.filter = "daily"
		local filtered, nodes = sidebar_tree.lines(m, { icons = icons })
		assert(vim.tbl_contains(filtered, "  v + Work"), vim.inspect(filtered))
		assert(vim.tbl_contains(filtered, "    v + reports"), vim.inspect(filtered))
		assert(vim.tbl_contains(filtered, "      # daily.sql"), vim.inspect(filtered))
		assert(not vim.tbl_contains(filtered, "    # scratch.sql"), vim.inspect(filtered))
		assert(nodes[#filtered].kind == "saved_query" and nodes[#filtered].name == "daily.sql")
	end,

	["sidebar_tree expands and collapses each node kind through one interface"] = function()
		local m = model({ saved_query_locations = { saved_location() } })
		local folder = saved_location().children[1]
		assert(sidebar_tree.expand(m, folder))
		assert(sidebar_tree.is_expanded(m, folder))
		assert(not sidebar_tree.expand(m, folder), "expanding an open node is a no-op")
		assert(sidebar_tree.collapse(m, folder))
		assert(not sidebar_tree.is_expanded(m, folder))

		local leaf = folder.children[1]
		assert(not sidebar_tree.expand(m, leaf) and not sidebar_tree.is_expanded(m, leaf))

		local profile_node = { kind = "profile", profile = sqlite }
		schema_tree.set_tables(m.tree, { { schema = "main", name = "sessions", type = "table" } })
		assert(sidebar_tree.expand(m, profile_node))
		assert(m.schema_profile == "local" and #m.tree.tables == 0, "switching profile resets the tree")
		schema_tree.set_tables(m.tree, { { schema = "main", name = "sessions", type = "table" } })
		local schema_node = select(2, sidebar_tree.lines(m, { icons = icons }))[5]
		assert(sidebar_tree.expand(m, schema_node) and sidebar_tree.is_expanded(m, schema_node))
		assert(not sidebar_tree.open_schema(m, "local"), "re-opening the same profile keeps its tree")
		assert(sidebar_tree.is_expanded(m, schema_node))

		assert(sidebar_tree.collapse(m, profile_node))
		assert(m.schema_profile == nil and not sidebar_tree.is_expanded(m, schema_node))
		assert(not sidebar_tree.close_schema(m))
	end,
}
