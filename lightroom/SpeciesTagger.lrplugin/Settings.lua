-- Plugin preferences with defaults. The plugin lives in <repo>/lightroom/SpeciesTagger.lrplugin,
-- so by default the Python script and venv are found two folders up.

local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'

local Settings = {}

local function repoRoot()
	return LrPathUtils.parent(LrPathUtils.parent(_PLUGIN.path))
end

function Settings.defaults()
	local root = repoRoot()
	return {
		pythonPath = LrPathUtils.child(LrPathUtils.child(LrPathUtils.child(root, '.venv'), 'Scripts'), 'python.exe'),
		scriptPath = LrPathUtils.child(root, 'species_tagger.py'),
		backend = 'claude-cli',     -- 'claude-cli' (Claude subscription) or 'api' (ANTHROPIC_API_KEY)
		model = '',                 -- blank: the script's default for the backend
		claudePath = '',            -- blank: claude on PATH, then the VS Code extension's copy
		checkThreshold = 0.7,       -- below this confidence the photo also gets Species > _check
		highThreshold = 0.9,        -- at or above this the confidence band is "high"
		skipTagged = true,
		lastLocation = '',
	}
end

-- The plugin's prefs, with any missing value filled from the defaults.
function Settings.get()
	local prefs = LrPrefs.prefsForPlugin()
	for k, v in pairs(Settings.defaults()) do
		if prefs[k] == nil then
			prefs[k] = v
		end
	end
	return prefs
end

function Settings.resetPaths()
	local prefs = LrPrefs.prefsForPlugin()
	local d = Settings.defaults()
	prefs.pythonPath = d.pythonPath
	prefs.scriptPath = d.scriptPath
end

return Settings
