-- Settings section in File > Plug-in Manager.

local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local Settings = require 'Settings'

local function browse(prefs, key, title)
	local picked = LrDialogs.runOpenPanel {
		title = title,
		canChooseFiles = true,
		canChooseDirectories = false,
		allowsMultipleSelection = false,
	}
	if picked and picked[1] then
		prefs[key] = picked[1]
	end
end

local function sectionsForTopOfDialog(f, propertyTable)
	local prefs = Settings.get()
	local bind = LrView.bind
	local share = LrView.share

	local function pathRow(label, key, title)
		return f:row {
			f:static_text { title = label, alignment = 'right', width = share 'labelWidth' },
			f:edit_field { value = bind(key), width_in_chars = 50, immediate = true },
			f:push_button { title = "Browse...", action = function() browse(prefs, key, title) end },
		}
	end

	return {
		{
			title = "AI Species Tagger",
			bind_to_object = prefs,

			f:static_text {
				title = "Runs species_tagger.py on the selected CR3s and writes keywords and fields into the catalogue.\n"
					.. "No XMP sidecars are written. Log: Documents\\LrClassicLogs\\SpeciesTagger.log "
					.. "and the Python output in the plugin's temp folder (see the end-of-run message).",
				height_in_lines = 3,
				width_in_chars = 80,
			},

			pathRow("Python:", 'pythonPath', "Choose python.exe (normally the project's .venv\\Scripts\\python.exe)"),
			pathRow("Script:", 'scriptPath', "Choose species_tagger.py"),

			f:row {
				f:static_text { title = "AI backend:", alignment = 'right', width = share 'labelWidth' },
				f:popup_menu {
					value = bind 'backend',
					items = Settings.backendItems(),
				},
			},
			pathRow("Claude CLI:", 'claudePath', "Choose claude.exe (leave blank to find it automatically)"),
			f:row {
				f:static_text { title = "Model:", alignment = 'right', width = share 'labelWidth' },
				f:edit_field { value = bind 'model', width_in_chars = 25, immediate = true },
				f:static_text { title = "blank = the script's default" },
			},

			f:row {
				f:static_text { title = "Flag below:", alignment = 'right', width = share 'labelWidth' },
				f:edit_field { value = bind 'checkThreshold', min = 0, max = 1, precision = 2, width_in_chars = 5 },
				f:static_text { title = "confidence: also add the keyword Species > _check and band \"Low\"" },
			},
			f:row {
				f:static_text { title = "High from:", alignment = 'right', width = share 'labelWidth' },
				f:edit_field { value = bind 'highThreshold', min = 0, max = 1, precision = 2, width_in_chars = 5 },
				f:static_text { title = "confidence: band \"High\" (between the two is \"Medium\")" },
			},

			f:row {
				f:static_text { title = "", width = share 'labelWidth' },
				f:push_button { title = "Reset Python and script paths", action = function() Settings.resetPaths() end },
				f:static_text { title = "to the copies next to this plugin's folder" },
			},
		},
	}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
}
