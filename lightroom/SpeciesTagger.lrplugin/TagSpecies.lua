-- Tag Species with AI: runs species_tagger.py on each selected CR3 and writes the result into
-- the catalogue as a keyword (Species > <common name>) plus the plugin's metadata fields.

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Json = require 'Json'
local Settings = require 'Settings'

local logger = LrLogger('SpeciesTagger')
logger:enable('logfile')   -- Documents\LrClassicLogs\SpeciesTagger.log

local PARENT_KEYWORD = 'Species'
local CHECK_KEYWORD = '_check'
local WRITE_EVERY = 10     -- save to the catalogue after this many photos, so a crash loses little

---------------------------------------------------------------- helpers

local function trim(s)
	return (string.gsub(s or '', '^%s*(.-)%s*$', '%1'))
end

-- One argument for cmd.exe and Python's argv parsing. cmd expands %VAR% even inside quotes and
-- a quote inside an argument would end it, so both are removed; a trailing backslash would
-- escape the closing quote, so it goes too.
local function quoteArg(s)
	s = string.gsub(s or '', '["%%\r\n]', '')
	s = string.gsub(s, '\\+$', '')
	return '"' .. s .. '"'
end

local function fileName(path)
	return LrPathUtils.leafName(path)
end

-- Location for the model: the photo's own IPTC location fields, else its GPS position.
local function photoLocation(photo)
	local parts = {}
	for _, key in ipairs { 'location', 'city', 'stateProvince', 'country' } do
		local v = trim(photo:getFormattedMetadata(key))
		if v ~= '' then
			parts[#parts + 1] = v
		end
	end
	if #parts > 0 then
		return table.concat(parts, ', ')
	end
	local gps = photo:getRawMetadata('gps')
	if gps and gps.latitude and gps.longitude then
		return string.format('GPS %.5f, %.5f', gps.latitude, gps.longitude)
	end
	return nil
end

local function buildCommand(prefs, photoPath, resultPath, outDir, logPath, location)
	local parts = {
		quoteArg(prefs.pythonPath), quoteArg(prefs.scriptPath), quoteArg(photoPath),
		'--no-sidecar',
		'--result-json', quoteArg(resultPath),
		'--out', quoteArg(outDir),
		'--backend', prefs.backend == 'api' and 'api' or 'claude-cli',
	}
	if location and location ~= '' then
		parts[#parts + 1] = '--location'
		parts[#parts + 1] = quoteArg(location)
	end
	if trim(prefs.model) ~= '' then
		parts[#parts + 1] = '--model'
		parts[#parts + 1] = quoteArg(trim(prefs.model))
	end
	if prefs.backend ~= 'api' and trim(prefs.claudePath) ~= '' then
		parts[#parts + 1] = '--claude-path'
		parts[#parts + 1] = quoteArg(trim(prefs.claudePath))
	end
	local cmd = table.concat(parts, ' ') .. ' >> ' .. quoteArg(logPath) .. ' 2>&1'
	if WIN_ENV then
		-- cmd /c strips the first and last quote of a line that starts with one; wrap the whole
		-- line so the quotes around the paths survive.
		cmd = '"' .. cmd .. '"'
	end
	return cmd
end

-- Runs the script for one photo. Returns the decoded result record, or nil and an error message.
local function runTagger(prefs, photoPath, workDir, location)
	local resultPath = LrPathUtils.child(workDir, 'result.json')
	local outDir = LrPathUtils.child(workDir, 'output')
	local logPath = LrPathUtils.child(workDir, 'python.log')
	if LrFileUtils.exists(resultPath) then
		LrFileUtils.delete(resultPath)
	end

	local cmd = buildCommand(prefs, photoPath, resultPath, outDir, logPath, location)
	logger:info('Running: ' .. cmd)
	local exitCode = LrTasks.execute(cmd)
	logger:info('Exit code: ' .. tostring(exitCode))

	if not LrFileUtils.exists(resultPath) then
		return nil, string.format("No result from the script (exit code %s). See %s",
			tostring(exitCode), logPath)
	end
	local ok, record = pcall(Json.decode, LrFileUtils.readFile(resultPath))
	if not ok then
		return nil, "Couldn't read the result: " .. tostring(record)
	end
	if not record.ok then
		return nil, record.error or "the script reported a failure"
	end
	if type(record.result) ~= 'table' then
		return nil, "the script returned no identification"
	end
	return record
end

---------------------------------------------------------------- keywords

-- Keyword names are case-insensitive in Lightroom, so match that way.
local function findKeyword(catalog, name, parent)
	local list = parent and parent:getChildren() or catalog:getKeywords()
	local wanted = string.lower(name)
	for _, kw in ipairs(list) do
		if string.lower(kw:getName()) == wanted then
			return kw
		end
	end
	return nil
end

-- Finds or creates a keyword. Runs its own write transaction, so call it outside one.
-- The keyword is looked up again after the transaction rather than trusting the object
-- returned inside it.
local function ensureKeyword(catalog, name, parent, synonyms, includeOnExport)
	local kw = findKeyword(catalog, name, parent)
	if kw then
		return kw
	end
	catalog:withWriteAccessDo("AI Species Tagger: add keyword", function()
		catalog:createKeyword(name, synonyms or {}, includeOnExport, parent, true)
	end, { timeout = 60 })
	kw = findKeyword(catalog, name, parent)
	if not kw then
		error("Couldn't create the keyword " .. name)
	end
	return kw
end

local function isAiKeyword(kw, name)
	local parent = kw:getParent()
	return parent ~= nil
		and string.lower(parent:getName()) == string.lower(PARENT_KEYWORD)
		and parent:getParent() == nil
		and string.lower(kw:getName()) == string.lower(name)
end

-- Keyword name for a result: common name, else scientific name. Commas would split it when
-- typed back into Lightroom, so they become spaces.
local function speciesKeywordName(r)
	local name = trim(r.common_name)
	if name == '' then
		name = trim(r.scientific_name)
	end
	name = trim(string.gsub(name, ',', ' '))
	return name ~= '' and name or nil
end

---------------------------------------------------------------- writing to the catalogue

local function confidenceBand(r, prefs)
	if not r.is_wildlife then
		return 'none'
	end
	local c = tonumber(r.confidence) or 0
	if c >= (tonumber(prefs.highThreshold) or 0.9) then
		return 'high'
	elseif c < (tonumber(prefs.checkThreshold) or 0.7) then
		return 'low'
	end
	return 'medium'
end

local function alternativesText(r)
	local out = {}
	for _, a in ipairs(r.alternatives or {}) do
		out[#out + 1] = string.format('%s (%s)', a.common_name or '?', a.scientific_name or '?')
	end
	return #out > 0 and table.concat(out, '; ') or nil
end

local function nonEmpty(s)
	if s == nil then
		return nil
	end
	s = trim(tostring(s))
	return s ~= '' and s or nil
end

-- Prepare everything that needs reads or its own transactions, then apply all items in one
-- write transaction (one Undo step per batch).
local function flush(catalog, pending, keywords, prefs, stats)
	if #pending == 0 then
		return
	end

	for _, item in ipairs(pending) do
		local r = item.record.result
		item.band = confidenceBand(r, prefs)
		item.keywordName = r.is_wildlife and speciesKeywordName(r) or nil
		if item.keywordName then
			local synonyms = {}
			local sci = trim(r.scientific_name)
			if sci ~= '' and string.lower(sci) ~= string.lower(item.keywordName) then
				synonyms[1] = sci
			end
			item.keyword = ensureKeyword(catalog, item.keywordName, keywords.parent, synonyms, true)
		end

		-- Keywords this plugin added on an earlier run, to replace.
		item.remove = {}
		local oldName = item.photo:getPropertyForPlugin(_PLUGIN, 'commonName')
		for _, kw in ipairs(item.photo:getRawMetadata('keywords') or {}) do
			if (oldName and isAiKeyword(kw, oldName) and oldName ~= item.keywordName)
				or (isAiKeyword(kw, CHECK_KEYWORD) and item.band ~= 'low') then
				item.remove[#item.remove + 1] = kw
			end
		end
	end

	local status = catalog:withWriteAccessDo("Tag species with AI", function()
		for _, item in ipairs(pending) do
			local photo, rec, r = item.photo, item.record, item.record.result
			for _, kw in ipairs(item.remove) do
				photo:removeKeyword(kw)
			end
			if item.keyword then
				photo:addKeyword(item.keyword)
			end
			if item.band == 'low' then
				photo:addKeyword(keywords.check)
			end

			local function set(id, value)
				photo:setPropertyForPlugin(_PLUGIN, id, nonEmpty(value))
			end
			set('commonName', item.keywordName)
			set('scientificName', r.is_wildlife and r.scientific_name or nil)
			set('rank', r.is_wildlife and r.rank or nil)
			set('confidence', r.is_wildlife and string.format('%.2f', tonumber(r.confidence) or 0) or nil)
			set('confidenceBand', item.band)
			set('notes', r.notes)
			set('alternatives', alternativesText(r))
			set('location', rec.location)
			set('focusSource', rec.focus_source)
			set('model', rec.model)
			set('taggedAt', rec.tagged_at)
		end
	end, { timeout = 120 })

	if status ~= 'executed' then
		-- Results are still listed in the log; nothing was written for this batch.
		for _, item in ipairs(pending) do
			stats.failed[#stats.failed + 1] = fileName(item.path) .. ": catalogue was busy, not saved"
		end
		logger:error('Write transaction status: ' .. tostring(status))
	else
		for _, item in ipairs(pending) do
			stats[item.band] = stats[item.band] + 1
		end
	end
	for i = #pending, 1, -1 do
		pending[i] = nil
	end
end

---------------------------------------------------------------- dialog

local function askOptions(context, prefs, count, skippedText)
	local f = LrView.osFactory()
	local bind = LrView.bind
	local props = LrBinding.makePropertyTable(context)
	props.location = prefs.lastLocation or ''
	props.usePhotoLocation = prefs.usePhotoLocation ~= false
	props.skipTagged = prefs.skipTagged ~= false
	props.backend = prefs.backend

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text { title = string.format("%d CR3 photo(s) to look at.%s", count, skippedText) },
		f:row {
			f:static_text { title = "Location:" },
			f:edit_field { value = bind 'location', width_in_chars = 40, immediate = true },
		},
		f:static_text { title = "Where the photos were taken, e.g. \"Costa Rica, Guanacaste\". Helps separate look-alikes." },
		f:checkbox { title = "Use each photo's own location fields or GPS instead, when it has them",
			value = bind 'usePhotoLocation' },
		f:checkbox { title = "Skip photos this plugin has already tagged", value = bind 'skipTagged' },
		f:row {
			f:static_text { title = "AI backend:" },
			f:popup_menu {
				value = bind 'backend',
				items = {
					{ title = "Claude subscription (Claude Code CLI)", value = 'claude-cli' },
					{ title = "API key (ANTHROPIC_API_KEY)", value = 'api' },
				},
			},
		},
		f:static_text {
			title = "Each photo takes about 10 to 40 seconds. Cancel from the progress bar at the top left:\n"
				.. "the photo in progress finishes, and everything done so far is kept.",
			height_in_lines = 2,
		},
	}

	local action = LrDialogs.presentModalDialog {
		title = "Tag Species with AI",
		contents = contents,
		actionVerb = "Tag",
	}
	if action ~= 'ok' then
		return nil
	end
	prefs.lastLocation = trim(props.location)
	prefs.usePhotoLocation = props.usePhotoLocation
	prefs.skipTagged = props.skipTagged
	prefs.backend = props.backend
	return props
end

---------------------------------------------------------------- main

local function summary(stats, workDir)
	local tagged = stats.high + stats.medium + stats.low
	local lines = {
		string.format("Tagged: %d  (high %d, medium %d, low %d; low ones also have Species > %s)",
			tagged, stats.high, stats.medium, stats.low, CHECK_KEYWORD),
		string.format("No wildlife found: %d", stats.none),
	}
	if stats.skippedTagged > 0 then
		lines[#lines + 1] = string.format("Skipped, already tagged: %d", stats.skippedTagged)
	end
	if stats.missing > 0 then
		lines[#lines + 1] = string.format("Skipped, file missing or offline: %d", stats.missing)
	end
	if stats.canceled then
		lines[#lines + 1] = "Canceled before the end."
	end
	if #stats.failed > 0 then
		lines[#lines + 1] = string.format("\nFailed: %d", #stats.failed)
		for i = 1, math.min(#stats.failed, 8) do
			lines[#lines + 1] = "  " .. stats.failed[i]
		end
		if #stats.failed > 8 then
			lines[#lines + 1] = "  ..."
		end
	end
	lines[#lines + 1] = "\nPython output: " .. LrPathUtils.child(workDir, 'python.log')
	return table.concat(lines, "\n")
end

local function tagSpecies(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)
	local catalog = LrApplication.activeCatalog()
	local prefs = Settings.get()

	for _, check in ipairs {
		{ prefs.pythonPath, "Python" },
		{ prefs.scriptPath, "species_tagger.py" },
	} do
		if not LrFileUtils.exists(check[1]) then
			LrDialogs.message("AI Species Tagger",
				string.format("Can't find %s at\n%s\n\nSet the path in File > Plug-in Manager.",
					check[2], tostring(check[1])), 'critical')
			return
		end
	end

	-- Real CR3 files only, each file once (virtual copies share their master's file).
	local candidates, seen = {}, {}
	local notCr3, virtual = 0, 0
	for _, photo in ipairs(catalog:getTargetPhotos()) do
		local path = photo:getRawMetadata('path')
		if photo:getRawMetadata('isVirtualCopy') then
			virtual = virtual + 1
		elseif not path or string.lower(LrPathUtils.extension(path) or '') ~= 'cr3' then
			notCr3 = notCr3 + 1
		elseif not seen[path] then
			seen[path] = true
			candidates[#candidates + 1] = { photo = photo, path = path }
		end
	end

	local skippedText = ''
	if notCr3 > 0 or virtual > 0 then
		skippedText = string.format("\nIgnoring %d non-CR3 photo(s) and %d virtual cop(ies).", notCr3, virtual)
	end
	if #candidates == 0 then
		LrDialogs.message("AI Species Tagger", "None of the selected photos is a CR3." .. skippedText, 'info')
		return
	end

	local options = askOptions(context, prefs, #candidates, skippedText)
	if not options then
		return
	end

	local stats = { high = 0, medium = 0, low = 0, none = 0, skippedTagged = 0, missing = 0,
		failed = {}, canceled = false }

	local work = {}
	for _, c in ipairs(candidates) do
		if options.skipTagged and c.photo:getPropertyForPlugin(_PLUGIN, 'taggedAt') then
			stats.skippedTagged = stats.skippedTagged + 1
		elseif not LrFileUtils.exists(c.path) then
			stats.missing = stats.missing + 1
		else
			work[#work + 1] = c
		end
	end

	local workDir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'AISpeciesTagger')
	LrFileUtils.createAllDirectories(workDir)
	local logPath = LrPathUtils.child(workDir, 'python.log')
	if LrFileUtils.exists(logPath) then
		LrFileUtils.delete(logPath)   -- keep only the latest run
	end

	local keywords = {}
	if #work > 0 then
		keywords.parent = ensureKeyword(catalog, PARENT_KEYWORD, nil, {}, true)
		keywords.check = ensureKeyword(catalog, CHECK_KEYWORD, keywords.parent, {}, false)
	end

	local progress = LrProgressScope {
		title = "Tagging species with AI",
		functionContext = context,
	}
	progress:setCancelable(true)

	local pending = {}
	for i, c in ipairs(work) do
		if progress:isCanceled() then
			stats.canceled = true
			break
		end
		progress:setPortionComplete(i - 1, #work)
		progress:setCaption(string.format("%d of %d: %s", i, #work, fileName(c.path)))

		local location = options.usePhotoLocation and photoLocation(c.photo) or nil
		if not location or location == '' then
			location = trim(options.location)
		end

		local record, err = runTagger(prefs, c.path, workDir, location)
		if record then
			local r = record.result
			logger:info(string.format('%s: %s (%s) %.2f', fileName(c.path), tostring(r.common_name),
				tostring(r.scientific_name), tonumber(r.confidence) or 0))
			pending[#pending + 1] = { photo = c.photo, path = c.path, record = record }
			if #pending >= WRITE_EVERY then
				flush(catalog, pending, keywords, prefs, stats)
			end
		else
			logger:warn(fileName(c.path) .. ': ' .. tostring(err))
			stats.failed[#stats.failed + 1] = fileName(c.path) .. ": " .. tostring(err)
		end
	end
	flush(catalog, pending, keywords, prefs, stats)
	progress:done()

	LrDialogs.message("AI Species Tagger", summary(stats, workDir), 'info')
end

LrFunctionContext.postAsyncTaskWithContext('AISpeciesTagger', tagSpecies)
