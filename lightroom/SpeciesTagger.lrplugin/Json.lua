-- Minimal JSON decoder (Lightroom's Lua 5.1 has none). Decodes objects, arrays, strings
-- (including \uXXXX escapes and surrogate pairs, to UTF-8), numbers, true, false and null.
-- null decodes to nil, so a key with a null value is simply absent from the table.

local Json = {}

local function decodeError(str, pos, msg)
	error(string.format("JSON error at character %d: %s", pos, msg), 0)
end

local function skipSpace(str, pos)
	return (string.find(str, "[^ \t\r\n]", pos)) or (#str + 1)
end

local function utf8char(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	else
		return string.char(0xF0 + math.floor(cp / 0x40000),
			0x80 + math.floor(cp / 0x1000) % 0x40,
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
end

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local decodeValue

local function decodeString(str, pos)
	-- pos is at the opening quote
	local parts = {}
	local i = pos + 1
	while true do
		local j = string.find(str, '["\\]', i)
		if not j then
			decodeError(str, pos, "unterminated string")
		end
		parts[#parts + 1] = string.sub(str, i, j - 1)
		local c = string.sub(str, j, j)
		if c == '"' then
			return table.concat(parts), j + 1
		end
		local e = string.sub(str, j + 1, j + 1)
		if e == 'u' then
			local hex = string.sub(str, j + 2, j + 5)
			local cp = tonumber(hex, 16)
			if not cp or #hex ~= 4 then
				decodeError(str, j, "bad \\u escape")
			end
			i = j + 6
			if cp >= 0xD800 and cp <= 0xDBFF and string.sub(str, i, i + 1) == '\\u' then
				local lo = tonumber(string.sub(str, i + 2, i + 5), 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					i = i + 6
				end
			end
			parts[#parts + 1] = utf8char(cp)
		elseif escapes[e] then
			parts[#parts + 1] = escapes[e]
			i = j + 2
		else
			decodeError(str, j, "bad escape")
		end
	end
end

local function decodeArray(str, pos)
	local result, n = {}, 0
	pos = skipSpace(str, pos + 1)
	if string.sub(str, pos, pos) == ']' then
		return result, pos + 1
	end
	while true do
		local value
		value, pos = decodeValue(str, pos)
		n = n + 1
		result[n] = value
		pos = skipSpace(str, pos)
		local c = string.sub(str, pos, pos)
		if c == ']' then
			return result, pos + 1
		elseif c ~= ',' then
			decodeError(str, pos, "expected ',' or ']'")
		end
		pos = skipSpace(str, pos + 1)
	end
end

local function decodeObject(str, pos)
	local result = {}
	pos = skipSpace(str, pos + 1)
	if string.sub(str, pos, pos) == '}' then
		return result, pos + 1
	end
	while true do
		if string.sub(str, pos, pos) ~= '"' then
			decodeError(str, pos, "expected a string key")
		end
		local key, value
		key, pos = decodeString(str, pos)
		pos = skipSpace(str, pos)
		if string.sub(str, pos, pos) ~= ':' then
			decodeError(str, pos, "expected ':'")
		end
		value, pos = decodeValue(str, skipSpace(str, pos + 1))
		result[key] = value
		pos = skipSpace(str, pos)
		local c = string.sub(str, pos, pos)
		if c == '}' then
			return result, pos + 1
		elseif c ~= ',' then
			decodeError(str, pos, "expected ',' or '}'")
		end
		pos = skipSpace(str, pos + 1)
	end
end

decodeValue = function(str, pos)
	pos = skipSpace(str, pos)
	local c = string.sub(str, pos, pos)
	if c == '{' then
		return decodeObject(str, pos)
	elseif c == '[' then
		return decodeArray(str, pos)
	elseif c == '"' then
		return decodeString(str, pos)
	elseif string.sub(str, pos, pos + 3) == 'true' then
		return true, pos + 4
	elseif string.sub(str, pos, pos + 4) == 'false' then
		return false, pos + 5
	elseif string.sub(str, pos, pos + 3) == 'null' then
		return nil, pos + 4
	end
	local num = string.match(str, '^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
	if num and num ~= '' and tonumber(num) then
		return tonumber(num), pos + #num
	end
	decodeError(str, pos, "unexpected character '" .. c .. "'")
end

function Json.decode(str)
	if type(str) ~= 'string' then
		error("JSON error: expected a string, got " .. type(str), 0)
	end
	-- Skip a UTF-8 byte order mark if present.
	if string.sub(str, 1, 3) == '\239\187\191' then
		str = string.sub(str, 4)
	end
	local value, pos = decodeValue(str, 1)
	pos = skipSpace(str, pos)
	if pos <= #str then
		decodeError(str, pos, "trailing characters")
	end
	return value
end

return Json
