-- Strict CSV decoding shared by connectors whose CLIs emit a header row.
local M = {}

-- Parses RFC-style quoted CSV into row tables. Quoted fields may contain
-- commas, newlines, and doubled quotes; malformed records fail as a unit so
-- callers never render cells under the wrong headers.
function M.parse(output, options)
	options = options or {}
	local records, record, field = {}, {}, {}
	local quoted, in_quotes, closed_quote, index = false, false, false, 1

	local function finish_field()
		table.insert(record, { value = table.concat(field), quoted = quoted })
		field, quoted, closed_quote = {}, false, false
	end

	local function finish_record()
		finish_field()
		table.insert(records, record)
		record = {}
	end

	output = output or ""
	while index <= #output do
		local character = output:sub(index, index)
		if in_quotes then
			if character == '"' and output:sub(index + 1, index + 1) == '"' then
				table.insert(field, '"')
				index = index + 1
			elseif character == '"' then
				in_quotes, closed_quote = false, true
			else
				table.insert(field, character)
			end
		elseif closed_quote and character ~= "," and character ~= "\n" and character ~= "\r" then
			return nil, "CLI output is not valid CSV: unexpected character after closing quote"
		elseif character == "\r" and output:sub(index + 1, index + 1) ~= "\n" then
			return nil, "CLI output is not valid CSV: bare carriage return"
		elseif character == '"' and #field == 0 then
			quoted, in_quotes = true, true
		elseif character == '"' then
			return nil, "CLI output is not valid CSV: unexpected quote in unquoted field"
		elseif character == "," then
			finish_field()
		elseif character == "\n" then
			finish_record()
		elseif character ~= "\r" then
			table.insert(field, character)
		end
		index = index + 1
	end

	if in_quotes then
		return nil, "CLI output is not valid CSV: unterminated quoted field"
	end
	if #field > 0 or quoted or #record > 0 then
		finish_record()
	end
	if #records == 0 then
		return {}
	end

	local headers, rows = records[1], {}
	for record_index = 2, #records do
		local fields = records[record_index]
		if #fields ~= #headers then
			return nil, string.format(
				"CLI output is not valid CSV: row %d has %d fields; expected %d",
				record_index - 1,
				#fields,
				#headers
			)
		end
		local row = {}
		for column_index, header in ipairs(headers) do
			local value = fields[column_index]
			row[header.value] = options.unquoted_empty_is_null and value.value == "" and not value.quoted and vim.NIL
				or value.value
		end
		table.insert(rows, row)
	end
	return rows
end

return M
