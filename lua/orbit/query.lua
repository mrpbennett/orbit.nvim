local profiles = require("orbit.profiles")
local diagnostics = require("orbit.diagnostics")
local feedback = require("orbit.feedback")
local results = require("orbit.results")
local runner = require("orbit.runner")
local schema_cache = require("orbit.schema_cache")
local statements = require("orbit.statements")

local M = {}
local running = {}
local result_generation = {}

local mutating = {
	alter = true,
	create = true,
	delete = true,
	drop = true,
	insert = true,
	merge = true,
	replace = true,
	truncate = true,
	update = true,
}

local function requires_confirmation(statement)
	-- This deliberately conservative lexical check is not a SQL parser: ambiguity is treated as mutable.
	local without_comments = statement:gsub("^%s*%-%-[^\n]*\n", ""):gsub("^%s*/%*.-%*/", "")
	local keyword = without_comments:lower():match("^%s*([%a]+)")
	local semicolons = select(2, without_comments:gsub(";", ""))
	local one_statement = semicolons == 0 or (semicolons == 1 and without_comments:match(";%s*$"))
	local read_only = {
		describe = true,
		explain = true,
		select = true,
		show = true,
		use = true,
		values = true,
	}
	return not (one_statement and keyword and read_only[keyword])
end

local function stop_timer(state)
	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end
end

function M.profile_for_buffer(buffer, config)
	local document, load_err = profiles.load(config.profile_path)
	if not document then
		return nil, load_err
	end
	local name = vim.b[buffer].orbit_profile
	if not name then
		return nil, "select a connection profile first"
	end
	local profile = profiles.find(document, name)
	if not profile then
		return nil, string.format("connection profile %q does not exist", name)
	end
	return profile
end

function M.select_profile(buffer, config, on_select)
	require("orbit.workspace").select_profile(config, buffer, on_select)
end

function M.bind_profile(buffer, profile)
	vim.b[buffer].orbit_profile = profile.name
	if require("orbit").config.completion then
		require("orbit.completion").attach(buffer)
		require("orbit.completion").prewarm(profile)
	end
	vim.notify("Orbit profile: " .. profile.name)
end

function M.execute(buffer, config, selection)
	result_generation[buffer] = (result_generation[buffer] or 0) + 1
	local profile, profile_err = M.profile_for_buffer(buffer, config)
	if not profile then
		vim.notify(profile_err, vim.log.levels.ERROR)
		M.select_profile(buffer, config, function()
			M.execute(buffer, config, selection)
		end)
		return
	end

	local statement, statement_err = statements.target({
		lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		selection = selection,
	})
	if not statement then
		vim.notify(statement_err, vim.log.levels.ERROR)
		return
	end

	if config.confirm_mutations and profile.options.confirm_mutations ~= false and requires_confirmation(statement) then
		local choice = vim.fn.confirm("Execute mutating statement?", "&Execute\n&Cancel", 2)
		if choice ~= 1 then
			return
		end
	end

	if running[buffer] then
		vim.notify("An Orbit statement is already running in this buffer", vim.log.levels.WARN)
		return
	end

	local notice =
		feedback.start((runner.connected(profile.name) and "Running on " or "Querying on ") .. profile.name .. "...")
	local state = {
		cancelled = false,
		profile_name = profile.name,
		started_at = vim.uv.hrtime(),
		tabpage = vim.api.nvim_get_current_tabpage(),
		window = vim.api.nvim_get_current_win(),
		notice = notice,
		result_generation = result_generation[buffer],
	}
	running[buffer] = state
	state.timer = vim.uv.new_timer()
	state.timer:start(
		0,
		1000,
		vim.schedule_wrap(function()
			vim.cmd.redrawstatus()
		end)
	)
	vim.cmd.redrawstatus()
	state.process = runner.run(profile, statement, function(rows, run_err)
		-- A previous completion must not clear or render over a newer run in this buffer.
		if running[buffer] ~= state then
			return
		end
		running[buffer] = nil
		stop_timer(state)
		vim.cmd.redrawstatus()
		if state.cancelled then
			feedback.finish(state.notice, "Query cancelled: " .. profile.name, vim.log.levels.WARN)
			return
		end
		if run_err then
			feedback.finish(state.notice, "Query failed: " .. profile.name, vim.log.levels.ERROR)
			vim.notify(run_err, vim.log.levels.ERROR)
			diagnostics.open(run_err)
			return
		end
		local result_options = {
			confirm_mutations = config.confirm_mutations,
			height = config.result_height,
			limit = config.result_limit,
			max_cell_width = config.max_cell_width,
			focus = config.focus_results,
			profile_name = profile.name,
			source_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t") ~= ""
					and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":t")
				or "[No Name]",
			source_window = state.window,
			tabpage = state.tabpage,
			elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000),
		}
		local table = vim.b[buffer].orbit_table
		if table and vim.trim(statement) == vim.trim(vim.b[buffer].orbit_table_statement or "") then
			result_options.source_name = table.name
			result_options.reload = function(callback)
				runner.run(profile, statement, callback)
			end
			schema_cache.load_metadata(profile, table, "primary_keys", {}, function(primary_keys, metadata_err)
				if metadata_err then
					vim.notify(metadata_err, vim.log.levels.WARN)
				else
					local names = vim.tbl_map(function(primary_key)
						return primary_key.name
					end, primary_keys)
					local connector, connector_err = require("orbit.adapters").connector(profile)
					local editable, editable_err
					if connector and connector.editable_table then
						editable, editable_err = connector.editable_table(profile.options, table, names)
					else
						editable_err = connector_err
							or "Result is read-only: editing is not supported by this connection profile."
					end
					if editable then
						result_options.editable = editable
						result_options.profile = profile
					elseif editable_err then
						result_options.read_only_reason = editable_err
					end
				end
				schema_cache.load_columns(profile, table, {}, function(columns)
					if result_generation[buffer] ~= state.result_generation then
						return
					end
					if columns then
						result_options.columns = vim.tbl_map(function(column)
							return column.name
						end, columns)
					end
					local workspace = require("orbit.workspace")
					if workspace.is_workspace(state.tabpage) then
						workspace.open_results(rows, result_options)
					else
						results.open(rows, result_options)
					end
				end)
			end)
			feedback.finish(
				state.notice,
				string.format(
					"Query finished: %d rows in %ds",
					#rows,
					math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
				)
			)
			return
		end
		local workspace = require("orbit.workspace")
		if workspace.is_workspace(state.tabpage) then
			-- Workspace-owned grids preserve its fixed result region and close behavior.
			workspace.open_results(rows, result_options)
		else
			results.open(rows, result_options)
		end
		feedback.finish(
			state.notice,
			string.format(
				"Query finished: %d rows in %ds",
				#rows,
				math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
			)
		)
	end)
end

function M.cancel(buffer)
	if not running[buffer] then
		vim.notify("No Orbit statement is running in this buffer", vim.log.levels.INFO)
		return
	end
	running[buffer].cancelled = true
	feedback.finish(running[buffer].notice, "Cancelling query...")
	runner.cancel(running[buffer].process)
end

function M.disconnect(buffer)
	local profile_name = vim.b[buffer].orbit_profile
	if not profile_name then
		vim.notify("No Orbit profile is bound to this buffer", vim.log.levels.INFO)
		return
	end
	runner.close(profile_name)
	vim.notify("Orbit disconnected: " .. profile_name)
end

function M.status(buffer, config)
	local state = running[buffer]
	local profile_name = state and state.profile_name or vim.b[buffer].orbit_profile
	if not profile_name then
		return "Orbit: no profile"
	end
	if state then
		local elapsed = math.floor((vim.uv.hrtime() - state.started_at) / 1000000000)
		return string.format("Orbit: %s [%ds]", profile_name, elapsed)
	end
	return string.format("Orbit: %s [%s]", profile_name, runner.connected(profile_name) and "connected" or "bound")
end

return M
