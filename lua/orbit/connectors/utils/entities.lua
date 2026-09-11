-- Strict XML-compatible entity decoding shared by machine-readable Connector
-- formats. Invalid entities and code points fail instead of changing data.
local M = {}

local function valid_character(number)
	return number ~= nil and (number == 9
		or number == 10
		or number == 13
		or (number >= 32 and number <= 55295)
		or (number >= 57344 and number <= 65533)
		or (number >= 65536 and number <= 1114111))
end

function M.decode(value, format)
	local unknown = value
		:gsub("&quot;", "")
		:gsub("&apos;", "")
		:gsub("&lt;", "")
		:gsub("&gt;", "")
		:gsub("&amp;", "")
		:gsub("&#x[%x]+;", "")
		:gsub("&#%d+;", "")
	if unknown:find("&", 1, true) then
		return nil, "invalid " .. format .. " entity"
	end
	for hexadecimal in value:gmatch("&#x([%x]+);") do
		if not valid_character(tonumber(hexadecimal, 16)) then
			return nil, "invalid " .. format .. " character reference"
		end
	end
	for decimal in value:gmatch("&#(%d+);") do
		if not valid_character(tonumber(decimal)) then
			return nil, "invalid " .. format .. " character reference"
		end
	end

	value = value:gsub("&#x([%x]+);", function(number)
		return vim.fn.nr2char(tonumber(number, 16))
	end):gsub("&#(%d+);", function(number)
		return vim.fn.nr2char(tonumber(number))
	end)
	value = value:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
	value = value:gsub("&amp;", "&")
	return value
end

return M
