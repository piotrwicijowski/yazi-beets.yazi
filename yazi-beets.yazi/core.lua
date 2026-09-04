local Core = {}

function Core.lookup_command(options)
	options = options or {}

	local library = options.library
	local music_directory = options.directory
	if library == nil and music_directory == nil then
		return {
			program = "beet",
			args = { "list", "-p" },
		}, nil
	end

	if type(library) ~= "string" or library == "" or type(music_directory) ~= "string" or music_directory == "" then
		return nil, "Set both non-empty library and directory paths, or neither."
	end

	return {
		program = "beet",
		args = { "-l", library, "-d", music_directory, "list", "-p" },
	}, nil
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
	return snapshot.statuses and snapshot.statuses[path]
end

function Core.card(path, result, library)
	result = result or { status = "pending collection status" }
	local status = result.status
	local explanation = EXPLANATIONS[status] or EXPLANATIONS.unavailable
	if status == "not applicable" and result.reason == "excluded by configuration" then
		explanation = "This path is excluded from collection-membership evaluation by configuration."
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

function Core.candidate_count(tree, exclusions)
	exclusions = exclusions or { ignore_extensions = {}, ignore_subdirectories = {} }

	local function count(node, inherited_exclusion)
		if node.kind == "symlink" then
			return 0
		end
		if inherited_exclusion or (node.kind == "directory" and is_excluded_directory(node, exclusions)) then
			return 0
		end
		if node.kind == "file" then
			return is_excluded_file(node, exclusions) and 0 or 1
		end

		local candidates = 0
		for _, child in ipairs(node.children or {}) do
			candidates = candidates + count(child, false)
		end
		return candidates
	end

	return count(tree, false)
end

function Core.evaluate(tree, collected_paths, exclusions)
	local statuses = {}
	collected_paths = collected_paths or {}
	exclusions = exclusions or { ignore_extensions = {}, ignore_subdirectories = {} }

	local function excluded_result(node)
		local result = {
			status = "not applicable",
			reason = "excluded by configuration",
			candidates = 0,
			collected = 0,
		}
		statuses[node.path] = result
		for _, child in ipairs(node.children or {}) do
			excluded_result(child)
		end
		return result
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
			local collected = collected_paths[node.path] == true
			local result = {
				status = collected and "collected" or "uncollected",
				candidates = 1,
				collected = collected and 1 or 0,
			}
			statuses[node.path] = result
			return result
		end

		local candidates, collected = 0, 0
		for _, child in ipairs(node.children or {}) do
			local result = visit(child, false)
			if result then
				candidates = candidates + result.candidates
				collected = collected + result.collected
			end
		end

		local status = "mixed"
		if candidates == 0 then
			status = "not applicable"
		elseif collected == candidates then
			status = "collected"
		elseif collected == 0 then
			status = "uncollected"
		end
		local result = {
			status = status,
			candidates = candidates,
			collected = collected,
			reason = status == "not applicable" and "no candidate descendants" or nil,
		}
		statuses[node.path] = result
		return result
	end

	visit(tree, false)
	return { statuses = statuses }
end

return Core
