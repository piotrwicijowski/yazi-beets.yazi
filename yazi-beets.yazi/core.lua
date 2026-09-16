local Core = {}

function Core.lookup_command(options, query)
	options = options or {}

	local library = options.library
	local music_directory = options.directory
	local args
	if library == nil and music_directory == nil then
		args = { "list", "-p" }
	elseif type(library) ~= "string" or library == "" or type(music_directory) ~= "string" or music_directory == "" then
		return nil, "Set both non-empty library and directory paths, or neither."
	else
		args = { "-l", library, "-d", music_directory, "list", "-p" }
	end

	if query ~= nil then
		args[#args + 1] = query
	end
	return { program = "beet", args = args }, nil
end

function Core.is_within_root(path, root)
	if type(path) ~= "string" or type(root) ~= "string" then
		return false
	end

	local function normalize(value)
		local absolute = value:sub(1, 1) == "/"
		local parts = {}
		for part in value:gmatch("[^/]+") do
			if part == ".." then
				if #parts > 0 then
					table.remove(parts)
				end
			elseif part ~= "." then
				parts[#parts + 1] = part
			end
		end
		local normalized = table.concat(parts, "/")
		if absolute then
			return "/" .. normalized
		end
		return normalized
	end

	path = normalize(path)
	root = normalize(root)
	return path == root or root == "/" or path:sub(1, #root + 1) == root .. "/"
end

function Core.cache_enabled(options)
	if type(options) ~= "table" then
		return nil, "setup options must be a table"
	end
	if options.cache ~= nil and type(options.cache) ~= "boolean" then
		return nil, "cache must be a boolean"
	end
	return options.cache == true
end

function Core.validate_tag_markers(options)
	if type(options) ~= "table" then
		return nil, "setup options must be a table"
	end
	local markers = options.tag_markers
	if markers == nil then
		return {}
	end
	if type(markers) ~= "table" then
		return nil, "tag_markers must be a dense array"
	end

	local max_index = 0
	for index in pairs(markers) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
			return nil, "tag_markers must be a dense array"
		end
		max_index = math.max(max_index, index)
	end

	local normalized, labels = {}, {}
	for index = 1, max_index do
		local marker = markers[index]
		if type(marker) ~= "table" then
			return nil, string.format("tag_markers[%d] must be a table", index)
		end
		for _, field in ipairs({ "label", "query" }) do
			local value = marker[field]
			if type(value) ~= "string" or value == "" or value:match("^%s") or value:match("%s$") then
				return nil, string.format("tag_markers[%d].%s must be a nonblank, unpadded string", index, field)
			end
		end
		if labels[marker.label] then
			return nil, string.format("tag_markers[%d].label duplicates %q", index, marker.label)
		end
		labels[marker.label] = true
		normalized[#normalized + 1] = { label = marker.label, query = marker.query }
	end
	return normalized
end

function Core.validate_exclusions(options)
	if type(options) ~= "table" then
		return nil, "setup options must be a table"
	end

	local function validate_list(field, normalizer)
		local values = options[field]
		if values == nil then
			return {}
		end
		if type(values) ~= "table" then
			return nil, field .. " must be an array"
		end

		local max_index = 0
		for index in pairs(values) do
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
				return nil, field .. " must be a dense array"
			end
			max_index = math.max(max_index, index)
		end

		local normalized = {}
		for index = 1, max_index do
			local value = values[index]
			if type(value) ~= "string" then
				return nil, string.format("%s[%d] must be a string", field, index)
			end
			if value == "" or value:match("^%s") or value:match("%s$") then
				return nil, string.format("%s[%d] must be nonblank and unpadded", field, index)
			end
			local normalized_value, err = normalizer(value)
			if not normalized_value then
				return nil, string.format("%s[%d] %s", field, index, err)
			end
			normalized[normalized_value] = true
		end
		return normalized
	end

	local extensions, extension_error = validate_list("ignore_extensions", function(value)
		if value:sub(1, 1) == "." then
			return nil, "must be a bare extension"
		end
		return value:lower()
	end)
	if not extensions then
		return nil, extension_error
	end

	local subdirectories, subdirectory_error = validate_list("ignore_subdirectories", function(value)
		return value
	end)
	if not subdirectories then
		return nil, subdirectory_error
	end

	return {
		ignore_extensions = extensions,
		ignore_subdirectories = subdirectories,
	}
end

local MARKERS = {
	collected = "●",
	mixed = "◐",
	uncollected = "○",
	unavailable = "!",
	["pending collection status"] = "…",
	["not applicable"] = "—",
}

local EXPLANATIONS = {
	collected = "This path corresponds to a beets item.",
	mixed = "Some candidate descendants correspond to beets items and some do not.",
	uncollected = "This path does not correspond to a beets item in the completed lookup.",
	unavailable = "Collection membership could not be evaluated.",
	["pending collection status"] = "Collection membership is still being evaluated.",
	["not applicable"] = "This directory has no candidate descendants.",
}

local TITLES = {
	collected = "Collected",
	mixed = "Mixed",
	uncollected = "Uncollected",
	unavailable = "Unavailable",
	["pending collection status"] = "Pending collection status",
	["not applicable"] = "Not applicable",
}

function Core.marker(status)
	return MARKERS[status] or ""
end

local TAG_MARKERS = {
	all = "●",
	some = "◐",
	none = "○",
	unavailable = "!",
	pending = "…",
	["not applicable"] = "—",
}

local TAG_TITLES = {
	all = "All",
	some = "Some",
	none = "None",
	unavailable = "Unavailable",
	pending = "Pending",
	["not applicable"] = "Not applicable",
}

function Core.tag_marker_glyph(status)
	return TAG_MARKERS[status] or ""
end

function Core.tag_marker_card(marker, result)
	result = result or { status = "pending" }
	local line = string.format("Tag marker %s: %s", marker.label, TAG_TITLES[result.status] or "Unavailable")
	if result.candidates ~= nil then
		line = line .. string.format(" (%d/%d matching)", result.matching or 0, result.candidates)
	end
	if result.status == "unavailable" then
		line = line .. ": " .. (result.reason or "unknown failure")
	end
	return line
end

function Core.collected_paths(output)
	local paths = {}
	for path in output:gmatch("[^\r\n]+") do
		paths[path] = true
	end
	return paths
end

function Core.status_for(snapshot, path)
	if not snapshot or snapshot.phase == "pending" then
		return { status = "pending collection status" }
	end
	if snapshot.phase == "unavailable" then
		return { status = "unavailable", reason = snapshot.reason }
	end
	if snapshot.outside_music_directory_root then
		return { status = "not applicable", reason = "outside configured music directory root" }
	end
	local result = snapshot.statuses and snapshot.statuses[path]
	if result then
		return result
	end
	if snapshot.phase == "streaming" then
		return { status = "pending collection status" }
	end
	return nil
end

function Core.tag_marker_status_for(snapshot, path)
	if not snapshot or snapshot.phase == "pending" or snapshot.phase == "streaming" then
		return { status = "pending" }
	end
	if snapshot.phase == "unavailable" then
		return { status = "unavailable", reason = snapshot.reason }
	end
	if snapshot.outside_music_directory_root then
		return { status = "not applicable", reason = "outside configured music directory root" }
	end
	local result = snapshot.statuses and snapshot.statuses[path]
	if result then
		return result
	end
	return nil
end

function Core.card(path, result, library)
	result = result or { status = "pending collection status" }
	local status = result.status
	local explanation = EXPLANATIONS[status] or EXPLANATIONS.unavailable
	if status == "not applicable" and result.reason == "excluded by configuration" then
		explanation = "This path is excluded from collection-membership evaluation by configuration."
	elseif status == "not applicable" and result.reason == "outside configured music directory root" then
		explanation = "This path is outside the configured music directory root, so collection membership was not evaluated."
	end
	local lines = {
		"Collection status: " .. (TITLES[status] or "Unavailable"),
		explanation,
		"Path: " .. path,
		"Library: " .. library,
	}
	if result.candidates ~= nil then
		lines[#lines + 1] = string.format("Candidates: %d (%d collected)", result.candidates, result.collected or 0)
	end
	if status == "unavailable" then
		lines[#lines + 1] = "Failure: " .. (result.reason or "unknown failure")
		lines[#lines + 1] = "Correct configuration or run the refresh command."
	end
	return table.concat(lines, "\n")
end

function Core.scan(root_path, read_directory)
	local function scan_directory(path)
		local entries, err = read_directory(path)
		if not entries then
			return nil, tostring(err or "could not read directory")
		end

		local children = {}
		for _, entry in ipairs(entries) do
			if entry.kind == "directory" then
				local child, child_err = scan_directory(entry.path)
				if not child then
					return nil, child_err
				end
				children[#children + 1] = child
			else
				children[#children + 1] = entry
			end
		end
		return { path = path, kind = "directory", children = children }
	end

	return scan_directory(root_path)
end

local function basename(path)
	local trimmed = path:gsub("/+$", "")
	return trimmed:match("([^/]+)$")
end

local function is_excluded_file(node, exclusions)
	local name = basename(node.path)
	local extension = name and name:match("%.([^.]*)$")
	return extension and exclusions.ignore_extensions[extension:lower()]
end

local function is_excluded_directory(node, exclusions)
	local name = basename(node.path)
	return name and exclusions.ignore_subdirectories[name]
end

function Core.match_result(candidates, matching)
	local status = "some"
	if candidates == 0 then
		status = "not applicable"
	elseif matching == candidates then
		status = "all"
	elseif matching == 0 then
		status = "none"
	end
	return {
		status = status,
		candidates = candidates,
		matching = matching,
		reason = status == "not applicable" and "no candidate descendants" or nil,
	}
end

function Core.match_all(tree, matching_path_sets, exclusions)
	matching_path_sets = matching_path_sets or {}
	exclusions = exclusions or { ignore_extensions = {}, ignore_subdirectories = {} }

	local evaluations = {}
	for index, matching_paths in ipairs(matching_path_sets) do
		evaluations[index] = { statuses = {}, matching_paths = matching_paths or {} }
	end
	if #evaluations == 0 then
		return evaluations
	end

	local function excluded_result(node)
		local results = {}
		for index, evaluation in ipairs(evaluations) do
			local result = {
				status = "not applicable",
				reason = "excluded by configuration",
				candidates = 0,
				matching = 0,
			}
			evaluation.statuses[node.path] = result
			results[index] = result
		end
		for _, child in ipairs(node.children or {}) do
			excluded_result(child)
		end
		return results
	end

	local function visit(node, inherited_exclusion)
		if node.kind == "symlink" then
			return nil
		end
		if inherited_exclusion or (node.kind == "directory" and is_excluded_directory(node, exclusions)) then
			return excluded_result(node)
		end

		if node.kind == "file" then
			if is_excluded_file(node, exclusions) then
				return excluded_result(node)
			end
			local results = {}
			for index, evaluation in ipairs(evaluations) do
				local matches = evaluation.matching_paths[node.path] == true
				local result = {
					status = matches and "all" or "none",
					candidates = 1,
					matching = matches and 1 or 0,
				}
				evaluation.statuses[node.path] = result
				results[index] = result
			end
			return results
		end

		local candidates, matching = {}, {}
		for index in ipairs(evaluations) do
			candidates[index] = 0
			matching[index] = 0
		end
		for _, child in ipairs(node.children or {}) do
			local results = visit(child, false)
			if results then
				for index, result in ipairs(results) do
					candidates[index] = candidates[index] + result.candidates
					matching[index] = matching[index] + result.matching
				end
			end
		end

		local results = {}
		for index, evaluation in ipairs(evaluations) do
			local result = Core.match_result(candidates[index], matching[index])
			evaluation.statuses[node.path] = result
			results[index] = result
		end
		return results
	end

	visit(tree, false)
	for _, evaluation in ipairs(evaluations) do
		evaluation.matching_paths = nil
	end
	return evaluations
end

function Core.match(tree, matching_paths, exclusions)
	return Core.match_all(tree, { matching_paths or {} }, exclusions)[1] or { statuses = {} }
end

function Core.candidate_count(tree, exclusions)
	local result = Core.match(tree, {}, exclusions).statuses[tree.path]
	return result and result.candidates or 0
end

function Core.directory_result(candidates, collected)
	local result = Core.match_result(candidates, collected)
	local statuses = {
		all = "collected",
		some = "mixed",
		none = "uncollected",
		["not applicable"] = "not applicable",
	}
	return {
		status = statuses[result.status],
		candidates = result.candidates,
		collected = result.matching,
		reason = result.reason,
	}
end

function Core.evaluate(tree, collected_paths, exclusions)
	local matching = Core.match(tree, collected_paths, exclusions)
	local statuses = {}
	for path, result in pairs(matching.statuses) do
		statuses[path] = Core.directory_result(result.candidates, result.matching)
		if result.reason == "excluded by configuration" then
			statuses[path].reason = result.reason
		end
	end
	return { statuses = statuses }
end

return Core
