-- Pure, dialect-agnostic SQL lexer. Never errors: unterminated strings, quoted
-- identifiers, and block comments close implicitly at end of input instead of
-- raising, because the buffer is routinely mid-edit when completion runs.
local M = {}

local function is_digit(c)
	return c ~= nil and c >= "0" and c <= "9"
end

local function is_ident_start(c)
	return c ~= nil and c:match("[%a_]") ~= nil
end

local function is_ident_char(c)
	return c ~= nil and c:match("[%w_]") ~= nil
end

-- All three connectors agree on '...' strings ('' escaping) and "..." quoted
-- identifiers ("" escaping); see connectors/{postgres,sqlite,trino}.lua.
function M.tokenize(lines)
	local content = table.concat(lines, "\n")
	local length = #content
	local tokens = {}
	local depth = 0
	local row, col = 1, 0
	local i = 1

	local function char(offset)
		local pos = i + (offset or 0)
		if pos < 1 or pos > length then
			return nil
		end
		return content:sub(pos, pos)
	end

	-- Advances past exactly one source byte, keeping row/col in sync. The
	-- injected "\n" separators are consumed here too, resetting col without
	-- ever producing a token, matching the original per-line byte columns.
	local function advance()
		local c = char()
		if c == "\n" then
			row = row + 1
			col = 0
		else
			col = col + 1
		end
		i = i + 1
	end

	local function emit(type_, start_row, start_col, text)
		table.insert(tokens, {
			type = type_,
			text = text,
			row = start_row,
			start_col = start_col,
			end_col = col,
			depth = depth,
		})
	end

	local function scan_delimited(quote, escape)
		local start_row, start_col = row, col
		local text = { quote }
		advance() -- opening quote
		while true do
			local c = char()
			if not c then
				break
			end
			if c == quote then
				if char(1) == quote then
					table.insert(text, quote)
					table.insert(text, quote)
					advance()
					advance()
				else
					table.insert(text, quote)
					advance()
					break
				end
			else
				table.insert(text, c)
				advance()
			end
		end
		return start_row, start_col, table.concat(text)
	end

	while i <= length do
		local c = char()

		if c == "\n" or c == " " or c == "\t" or c == "\r" then
			advance()
		elseif c == "-" and char(1) == "-" then
			local start_row, start_col = row, col
			while char() and char() ~= "\n" do
				advance()
			end
			emit("comment", start_row, start_col, "")
		elseif c == "/" and char(1) == "*" then
			local start_row, start_col = row, col
			advance()
			advance()
			-- Non-nested block comments are an accepted v1 simplification.
			while char() and not (char() == "*" and char(1) == "/") do
				advance()
			end
			if char() then
				advance()
				advance()
			end
			emit("comment", start_row, start_col, "")
		elseif c == '"' then
			local start_row, start_col, text = scan_delimited('"')
			emit("quoted_identifier", start_row, start_col, text)
		elseif c == "'" then
			local start_row, start_col, text = scan_delimited("'")
			emit("string", start_row, start_col, text)
		elseif is_digit(c) then
			local start_row, start_col = row, col
			while is_digit(char()) do
				advance()
			end
			if char() == "." and is_digit(char(1)) then
				advance()
				while is_digit(char()) do
					advance()
				end
			end
			emit("number", start_row, start_col, "")
		elseif is_ident_start(c) then
			local start_row, start_col = row, col
			local text = {}
			while is_ident_char(char()) do
				table.insert(text, char())
				advance()
			end
			emit("identifier", start_row, start_col, table.concat(text))
		elseif c == ";" then
			local start_row, start_col = row, col
			advance()
			emit("semicolon", start_row, start_col, ";")
		elseif c == "(" then
			local start_row, start_col = row, col
			advance()
			depth = depth + 1
			emit("punct", start_row, start_col, "(")
		elseif c == ")" then
			local start_row, start_col = row, col
			advance()
			depth = math.max(depth - 1, 0)
			emit("punct", start_row, start_col, ")")
		else
			local start_row, start_col = row, col
			advance()
			emit("punct", start_row, start_col, c)
		end
	end

	return tokens
end

-- Splits a possibly quoted, dot-separated identifier chain (either what the
-- user typed, or a connector's completion_word/qualified_name output) into
-- unquoted segments. The only place dot-splitting/unquoting logic lives.
function M.split_qualified(text)
	local segments = {}
	local buffer = {}
	local i = 1
	local n = #text
	while i <= n do
		local c = text:sub(i, i)
		if c == '"' then
			i = i + 1
			while i <= n do
				local d = text:sub(i, i)
				if d == '"' then
					if text:sub(i + 1, i + 1) == '"' then
						table.insert(buffer, '"')
						i = i + 2
					else
						i = i + 1
						break
					end
				else
					table.insert(buffer, d)
					i = i + 1
				end
			end
		elseif c == "." then
			table.insert(segments, table.concat(buffer))
			buffer = {}
			i = i + 1
		else
			table.insert(buffer, c)
			i = i + 1
		end
	end
	table.insert(segments, table.concat(buffer))
	return segments
end

return M
