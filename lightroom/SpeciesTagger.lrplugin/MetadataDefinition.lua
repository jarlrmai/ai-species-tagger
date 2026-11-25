-- Custom metadata fields stored in the catalogue for each tagged photo.
-- Bump schemaVersion whenever a field is added, removed or changed, or Lightroom ignores it.

return {
	schemaVersion = 1,

	metadataFieldsForPhotos = {
		{ id = 'commonName', title = "Species", dataType = 'string',
		  searchable = true, browsable = true, readOnly = true },
		{ id = 'scientificName', title = "Scientific name", dataType = 'string',
		  searchable = true, browsable = true, readOnly = true },
		{ id = 'rank', title = "Rank", dataType = 'string',
		  searchable = true, browsable = true, readOnly = true },
		{ id = 'confidence', title = "Confidence", dataType = 'string',
		  searchable = true, readOnly = true },
		-- An enum so smart collections can pick "Confidence band is Low".
		{ id = 'confidenceBand', title = "Confidence band", dataType = 'enum',
		  searchable = true, browsable = true, readOnly = true,
		  values = {
			  { value = nil, title = "Not tagged" },
			  { value = 'high', title = "High" },
			  { value = 'medium', title = "Medium" },
			  { value = 'low', title = "Low" },
			  { value = 'none', title = "No wildlife found" },
		  } },
		{ id = 'notes', title = "AI notes", dataType = 'string', searchable = true, readOnly = true },
		{ id = 'alternatives', title = "Alternatives", dataType = 'string', searchable = true, readOnly = true },
		{ id = 'location', title = "Location used", dataType = 'string', searchable = true, readOnly = true },
		{ id = 'focusSource', title = "Crop centred on", dataType = 'string', readOnly = true },
		{ id = 'model', title = "Model", dataType = 'string', searchable = true, readOnly = true },
		{ id = 'taggedAt', title = "Tagged at", dataType = 'string', searchable = true, readOnly = true },
	},
}
