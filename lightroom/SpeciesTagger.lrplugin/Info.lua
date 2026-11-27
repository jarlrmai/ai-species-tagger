-- AI Species Tagger: Lightroom Classic plugin.
-- Runs species_tagger.py on the selected CR3s and DNGs and writes the result straight into the catalogue
-- (keywords + plugin metadata fields). No XMP sidecars are written.

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	-- example.com is reserved (RFC 2606); this is only an identifier, never contacted.
	LrToolkitIdentifier = 'com.example.ai-species-tagger',
	LrPluginName = "AI Species Tagger",
	LrPluginInfoUrl = nil,

	-- Library > Plug-in Extras
	LrLibraryMenuItems = {
		{ title = "Tag Species with AI...", file = "TagSpecies.lua", enabledWhen = "photosSelected" },
	},
	-- File > Plug-in Extras (works from Develop too)
	LrExportMenuItems = {
		{ title = "Tag Species with AI...", file = "TagSpecies.lua", enabledWhen = "photosSelected" },
	},

	LrMetadataProvider = "MetadataDefinition.lua",
	LrMetadataTagsetFactory = "Tagset.lua",
	LrPluginInfoProvider = "PluginInfoProvider.lua",

	VERSION = { major = 0, minor = 1, revision = 0, build = 1 },
}
