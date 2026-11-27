-- A Metadata panel preset ("AI Species") showing the plugin's fields beside the usual ones.

local P = 'com.example.ai-species-tagger.'

return {
	{
		id = 'aiSpeciesTagset',
		title = "AI Species",
		items = {
			'com.adobe.filename',
			'com.adobe.folder',
			'com.adobe.separator',
			{ 'com.adobe.label', label = "AI Species Tagger" },
			P .. 'commonName',
			P .. 'scientificName',
			P .. 'rank',
			P .. 'confidence',
			P .. 'confidenceBand',
			P .. 'notes',
			P .. 'alternatives',
			P .. 'location',
			P .. 'focusSource',
			P .. 'identifiedFrom',
			P .. 'model',
			P .. 'taggedAt',
		},
	},
}
