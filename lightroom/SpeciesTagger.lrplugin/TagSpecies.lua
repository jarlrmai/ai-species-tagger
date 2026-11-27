-- Tag Species with AI: runs species_tagger.py on each selected CR3 or DNG and writes the result into
-- the catalogue as a keyword (Species > <common name>) plus the plugin's metadata fields.

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
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
logger:enable('logfile')   -- %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\SpeciesTagger.log

local PARENT_KEYWORD = 'Species'
local CHECK_KEYWORD = '_check'
-- File types species_tagger.py reads (its READERS).
local SUPPORTED = { cr3 = true, dng = true }
local WRITE_EVERY = 10     -- save to the catalogue after this many photos, so a crash loses little
local KEEP_RUNS = 5        -- run folders kept in %TEMP%\AISpeciesTagger for looking back at logs
local RUN_GUARD_HOURS = 3  -- a run marker older than this is assumed stale (Lightroom quit mid-run)

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
		-- -u: unbuffered, so the log (and the live console) shows each line as it happens
		quoteArg(prefs.pythonPath), '-u', quoteArg(prefs.scriptPath), quoteArg(photoPath),
		'--no-sidecar',
		'--result-json', quoteArg(resultPath),
		'--out', quoteArg(outDir),
		'--backend', Settings.BACKENDS[prefs.backend] and prefs.backend or 'claude-cli',
	}
	if location and location ~= '' then
		parts[#parts + 1] = '--location'
		parts[#parts + 1] = quoteArg(location)
	end
	if trim(prefs.model) ~= '' then
		parts[#parts + 1] = '--model'
		parts[#parts + 1] = quoteArg(trim(prefs.model))
	end
	if prefs.backend == 'claude-cli' and trim(prefs.claudePath) ~= '' then
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

local function fileSize(path)
	local f = io.open(path, 'rb')
	if not f then
		return 0
	end
	local size = f:seek('end')
	f:close()
	return size or 0
end

-- How far one photo has got (0..1) and what it's doing, from what the script has written to the
-- log since `offset`. The AI call gives no progress of its own, so while waiting for it the bar
-- creeps towards 95%: about two-thirds of the way there after 20 seconds.
local function photoStage(logPath, offset, elapsed)
	local text = ''
	local f = io.open(logPath, 'rb')
	if f then
		f:seek('set', offset)
		text = f:read('*a') or ''
		f:close()
	end
	if not string.find(text, '   crop ', 1, true) then
		return 0.05, 'Reading the raw file'
	end
	return 0.2 + 0.75 * (1 - math.exp(-elapsed / 20)), 'Asking the AI'
end

-- The console closes when it reads this line, which endConsole appends when the run ends.
local CONSOLE_END = '### AI Species Tagger: run finished ###'

-- console.ps1: follow the log, colour failures and the model's thoughts, and close 10 seconds
-- after the end marker. A script file avoids quoting a long command through cmd /c.
local CONSOLE_SCRIPT = [[
$Host.UI.RawUI.WindowTitle = 'AI Species Tagger'
Get-Content -LiteralPath '%s' -Wait -Encoding UTF8 | ForEach-Object {
    if ($_ -eq '%s') {
        Write-Host ''
        Write-Host 'Run finished. This window closes in 10 seconds.' -ForegroundColor Green
        Start-Sleep -Seconds 10
        exit
    }
    if ($_ -match 'FAILED|Traceback|Error') { Write-Host $_ -ForegroundColor Red }
    elseif ($_ -match '^   \| ') { Write-Host $_ -ForegroundColor DarkCyan }
    elseif ($_ -match '^== ') { Write-Host $_ -ForegroundColor Yellow }
    else { Write-Host $_ }
}
]]

-- Opens a PowerShell window that follows this run's log as it's written.
local function openConsole(workDir, logPath)
	local f = io.open(logPath, 'ab')   -- Get-Content -Wait needs the file to exist
	if f then
		f:close()
	end
	local scriptPath = LrPathUtils.child(workDir, 'console.ps1')
	local quoted = string.gsub(logPath, "'", "''")
	local s = io.open(scriptPath, 'wb')
	if not s then
		logger:warn("Couldn't write " .. scriptPath)
		return
	end
	-- UTF-8 with a BOM, so Windows PowerShell 5.1 reads a non-ASCII path correctly.
	s:write('\239\187\191' .. string.format(CONSOLE_SCRIPT, quoted, CONSOLE_END))
	s:close()
	local cmd = 'start "AI Species Tagger" powershell.exe -NoProfile -ExecutionPolicy Bypass -File '
		.. quoteArg(scriptPath)
	logger:info('Console: ' .. cmd)
	-- Wrapped in quotes for the same cmd /c reason as in buildCommand.
	LrTasks.execute('"' .. cmd .. '"')
end

-- Adds a line of the plugin's own to the run's log (and so to the console).
local function appendLog(logPath, text)
	local f = io.open(logPath, 'ab')
	if f then
		f:write(text)
		f:close()
	end
end

-- Sorts `work` by capture time and, when `enabled`, numbers its bursts in c.burst: consecutive
-- frames from the same camera body at most burstGap seconds apart, and within burstMaxSpan
-- seconds of the burst's first frame (so a long sequence is re-checked now and then, e.g. in
-- case a different bird turns up). Photos with no capture time get no burst.
local function markBursts(work, prefs, enabled)
	for _, c in ipairs(work) do
		local t = c.photo:getRawMetadata('dateTimeOriginal')
		c.time = type(t) == 'number' and t or nil
		c.camera = (c.photo:getFormattedMetadata('cameraSerialNumber') or '') .. '|'
			.. (c.photo:getFormattedMetadata('cameraModel') or '')
	end
	table.sort(work, function(a, b)
		if a.time and b.time then
			if a.time ~= b.time then
				return a.time < b.time
			end
		elseif a.time or b.time then
			return a.time ~= nil   -- photos with a time first
		end
		return a.path < b.path
	end)
	if not enabled then
		return
	end
	local gap = tonumber(prefs.burstGap) or 2
	local span = tonumber(prefs.burstMaxSpan) or 10
	local id, first, prev = 0, nil, nil
	for _, c in ipairs(work) do
		if c.time then
			local same = prev and prev.time and c.camera == prev.camera
				and c.time - prev.time <= gap and c.time - first.time <= span
			if not same then
				id = id + 1
				first = c
			end
			c.burst = id
		end
		prev = c
	end
end

-- Tells the console the run is over, so it closes.
local function endConsole(logPath)
	local f = io.open(logPath, 'ab')
	if f then
		f:write('\r\n' .. CONSOLE_END .. '\r\n')
		f:close()
	end
end

-- Deletes a file, or a folder and everything in it, file by file. Anything in use (e.g. a log
-- open in a console) is left for a later run to remove.
local function deleteTree(path)
	if LrFileUtils.exists(path) == 'directory' then
		local entries = {}
		for entry in LrFileUtils.directoryEntries(path) do
			entries[#entries + 1] = entry
		end
		for _, entry in ipairs(entries) do
			deleteTree(entry)
		end
	end
	if LrFileUtils.exists(path) then
		LrTasks.pcall(LrFileUtils.delete, path)
	end
end

-- What species_tagger.py writes for one photo into the run's output folder.
local function outputFiles(workDir, photoPath)
	local outDir = LrPathUtils.child(workDir, 'output')
	local stem = LrPathUtils.removeExtension(LrPathUtils.leafName(photoPath))
	local files = {}
	for _, suffix in ipairs { '_crop.jpg', '_af.jpg', '_frame.jpg', '.json' } do
		files[#files + 1] = LrPathUtils.child(outDir, stem .. suffix)
	end
	return files
end

-- A fresh folder for this run under %TEMP%\AISpeciesTagger (run-YYYYMMDD-HHMMSS), so runs never
-- share a log or result file, and a console left open on an old log can't block a new run.
-- Older run folders beyond the latest few are removed; one still open in a console is skipped.
local function newWorkDir()
	local base = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'AISpeciesTagger')
	LrFileUtils.createAllDirectories(base)
	-- Left at the top level by versions before run folders.
	for _, name in ipairs { 'output', 'python.log', 'result.json' } do
		deleteTree(LrPathUtils.child(base, name))
	end
	local old = {}
	for entry in LrFileUtils.directoryEntries(base) do
		if string.find(LrPathUtils.leafName(entry), '^run%-') then
			old[#old + 1] = entry
		end
	end
	table.sort(old)
	for i = 1, #old - (KEEP_RUNS - 1) do   -- room for the new one
		deleteTree(old[i])
	end
	local stamp = LrDate.timeToUserFormat(LrDate.currentTime(), '%Y%m%d-%H%M%S')
	local dir = LrFileUtils.chooseUniqueFileName(LrPathUtils.child(base, 'run-' .. stamp))
	LrFileUtils.createAllDirectories(dir)
	return dir
end

-- Runs the script for one photo, calling onTick(fraction, stage) about twice a second while it
-- runs. Returns the decoded result record, or nil and an error message.
local function runTagger(prefs, photoPath, workDir, location, onTick)
	local resultPath = LrPathUtils.child(workDir, 'result.json')
	local outDir = LrPathUtils.child(workDir, 'output')
	local logPath = LrPathUtils.child(workDir, 'python.log')
	if LrFileUtils.exists(resultPath) then
		LrFileUtils.delete(resultPath)
	end

	local cmd = buildCommand(prefs, photoPath, resultPath, outDir, logPath, location)
	logger:info('Running: ' .. cmd)
	-- Run the script in its own task so this one can update the progress bar meanwhile.
	local offset = fileSize(logPath)
	local finished, exitCode = false, nil
	LrTasks.startAsyncTask(function()
		-- LrTasks.pcall, not pcall: execute yields while the script runs, and plain pcall
		-- can't be yielded across ("Yielding is not allowed within a C or metamethod call").
		local ok, code = LrTasks.pcall(LrTasks.execute, cmd)
		exitCode = ok and code or ('failed to start: ' .. tostring(code))
		finished = true
	end, 'AISpeciesTagger script')
	local started = LrDate.currentTime()
	while not finished do
		onTick(photoStage(logPath, offset, LrDate.currentTime() - started))
		LrTasks.sleep(0.5)
	end
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
			set('identifiedFrom', rec.identified_from)   -- nil clears an earlier reused ID
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
			-- The result is in the catalogue now; its crop and previews are only worth keeping
			-- for a Low-confidence ID someone may want to check.
			if item.band ~= 'low' then
				for _, file in ipairs(item.files or {}) do
					deleteTree(file)
				end
			end
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
	props.reuseBursts = prefs.reuseBursts ~= false
	props.backend = prefs.backend
	props.showConsole = prefs.showConsole == true

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text { title = string.format("%d CR3/DNG photo(s) to look at.%s", count, skippedText) },
		f:row {
			f:static_text { title = "Location:" },
			f:edit_field { value = bind 'location', width_in_chars = 40, immediate = true },
		},
		f:static_text { title = "Where the photos were taken, e.g. \"Costa Rica, Guanacaste\". Helps separate look-alikes." },
		f:checkbox { title = "Use each photo's own location fields or GPS instead, when it has them",
			value = bind 'usePhotoLocation' },
		f:checkbox { title = "Skip photos this plugin has already tagged", value = bind 'skipTagged' },
		f:checkbox {
			title = string.format("Bursts: reuse the first High-confidence ID (%.2f+) for frames taken "
				.. "up to %g s apart", tonumber(prefs.highThreshold) or 0.9, tonumber(prefs.burstGap) or 2),
			value = bind 'reuseBursts',
		},
		f:row {
			f:static_text { title = "AI backend:" },
			f:popup_menu {
				value = bind 'backend',
				items = Settings.backendItems(),
			},
		},
		f:checkbox { title = "Show live console (the script's output, step by step)",
			value = bind 'showConsole' },
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
	prefs.reuseBursts = props.reuseBursts
	prefs.backend = props.backend
	prefs.showConsole = props.showConsole
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
	if stats.reused > 0 then
		lines[#lines + 1] = string.format("Reused from the same burst: %d (no AI call; see \"Identified from\")",
			stats.reused)
	end
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

	-- Real CR3/DNG files only, each file once (virtual copies share their master's file).
	local candidates, seen = {}, {}
	local notSupported, virtual = 0, 0
	for _, photo in ipairs(catalog:getTargetPhotos()) do
		local path = photo:getRawMetadata('path')
		if photo:getRawMetadata('isVirtualCopy') then
			virtual = virtual + 1
		elseif not path or not SUPPORTED[string.lower(LrPathUtils.extension(path) or '')] then
			notSupported = notSupported + 1
		elseif not seen[path] then
			seen[path] = true
			candidates[#candidates + 1] = { photo = photo, path = path }
		end
	end

	local skippedText = ''
	if notSupported > 0 or virtual > 0 then
		skippedText = string.format("\nIgnoring %d photo(s) that aren't CR3 or DNG and %d virtual cop(ies).",
			notSupported, virtual)
	end
	if #candidates == 0 then
		LrDialogs.message("AI Species Tagger", "None of the selected photos is a CR3 or DNG." .. skippedText, 'info')
		return
	end

	-- Two runs at once would tag the same photos twice and share the AI quota. The marker is in
	-- prefs (each menu click loads this file afresh), with a time limit in case Lightroom quit
	-- mid-run and never cleared it.
	local now = LrDate.currentTime()
	if prefs.runStartedAt and now - prefs.runStartedAt < RUN_GUARD_HOURS * 3600 then
		local started = LrDate.timeToUserFormat(prefs.runStartedAt, '%H:%M')
		local answer = LrDialogs.confirm("Another species tagging run is still in progress",
			"It started at " .. started .. ". Wait for its end-of-run message, or cancel it from the "
				.. "progress bar at the top left.\n\nIf it isn't running any more (for example Lightroom "
				.. "quit during a run), choose Start anyway.",
			"Start anyway", "Cancel")
		if answer ~= 'ok' then
			return
		end
	end

	local options = askOptions(context, prefs, #candidates, skippedText)
	if not options then
		return
	end

	local runId = LrDate.currentTime()
	prefs.runStartedAt = runId
	context:addCleanupHandler(function()
		if prefs.runStartedAt == runId then   -- not if a later run took over the marker
			prefs.runStartedAt = nil
		end
	end)

	local stats = { high = 0, medium = 0, low = 0, none = 0, skippedTagged = 0, missing = 0,
		reused = 0, failed = {}, canceled = false }

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

	local workDir = newWorkDir()
	local logPath = LrPathUtils.child(workDir, 'python.log')

	local keywords = {}
	if #work > 0 then
		keywords.parent = ensureKeyword(catalog, PARENT_KEYWORD, nil, {}, true)
		keywords.check = ensureKeyword(catalog, CHECK_KEYWORD, keywords.parent, {}, false)
	end

	if options.showConsole and #work > 0 then
		openConsole(workDir, logPath)
		-- Runs on every exit from here, including a Lua error, so the console always closes.
		context:addCleanupHandler(function()
			endConsole(logPath)
		end)
	end

	markBursts(work, prefs, options.reuseBursts)
	local confident = {}   -- burst number -> { record = ..., name = ... } of its first High ID

	-- One progress scope per photo: Lightroom's activity area shows a scope's title but not its
	-- caption, so the title is where "3 of 20: name" has to go. The bar shows the whole run.
	local pending = {}
	for i, c in ipairs(work) do
		local source = confident[c.burst]
		if source then
			-- Same burst as a confidently identified frame: reuse its ID, no AI call.
			local record = {}
			for k, v in pairs(source.record) do
				record[k] = v
			end
			record.identified_from = source.name .. ' (same burst)'
			pending[#pending + 1] = { photo = c.photo, path = c.path, record = record }
			stats.reused = stats.reused + 1
			local line = string.format('%s: %s, reused from %s (same burst)', fileName(c.path),
				tostring(record.result.common_name), source.name)
			logger:info(line)
			appendLog(logPath, '\r\n== ' .. line .. '\r\n')
		else
			local progress = LrProgressScope {
				title = string.format("Species %d of %d: %s", i, #work, fileName(c.path)),
				functionContext = context,
			}
			progress:setCancelable(true)
			progress:setPortionComplete(i - 1, #work)

			local location = options.usePhotoLocation and photoLocation(c.photo) or nil
			if not location or location == '' then
				location = trim(options.location)
			end

			local record, err = runTagger(prefs, c.path, workDir, location, function(fraction, stage)
				progress:setPortionComplete(i - 1 + fraction, #work)
				progress:setCaption(stage)
				if progress:isCanceled() then
					stats.canceled = true   -- the photo in progress still finishes and is kept
				end
			end)
			if progress:isCanceled() then
				stats.canceled = true
			end
			progress:done()
			if record then
				local r = record.result
				logger:info(string.format('%s: %s (%s) %.2f', fileName(c.path), tostring(r.common_name),
					tostring(r.scientific_name), tonumber(r.confidence) or 0))
				pending[#pending + 1] = { photo = c.photo, path = c.path, record = record,
					files = outputFiles(workDir, c.path) }
				-- Only a High-confidence wildlife ID is reused. Anything less (or a failure) and
				-- the next frame of the burst is asked instead.
				if c.burst and confidenceBand(r, prefs) == 'high' then
					confident[c.burst] = { record = record, name = fileName(c.path) }
				end
			else
				logger:warn(fileName(c.path) .. ': ' .. tostring(err))
				stats.failed[#stats.failed + 1] = fileName(c.path) .. ": " .. tostring(err)
			end
		end
		if #pending >= WRITE_EVERY then
			flush(catalog, pending, keywords, prefs, stats)
		end
		if stats.canceled then
			break
		end
	end
	flush(catalog, pending, keywords, prefs, stats)

	if options.showConsole and #work > 0 then
		endConsole(logPath)   -- now, not after the dialog below is dismissed
	end
	LrDialogs.message("AI Species Tagger", summary(stats, workDir), 'info')
end

LrFunctionContext.postAsyncTaskWithContext('AISpeciesTagger', tagSpecies)
