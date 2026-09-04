local Core = {}

function Core.lookup_command(options, directory)
	options = options or {}
	if type(directory) ~= "string" or directory == "" then
		return nil, "The active directory is unavailable."
	end

	local library = options.library
	local music_directory = options.directory
	if library == nil and music_directory == nil then
		return {
			program = "beet",
			args = { "list", "-p", "path:" .. directory },
		}, nil
	end

	if type(library) ~= "string" or library == "" or type(music_directory) ~= "string" or music_directory == "" then
		return nil, "Set both non-empty library and directory paths, or neither."
	end

	return {
		program = "beet",
		args = { "-l", library, "-d", music_directory, "list", "-p", "path:" .. directory },
	}, nil
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
	local lines = {
		"Collection status: " .. (TITLES[status] or "Unavailable"),
		EXPLANATIONS[status] or EXPLANATIONS.unavailable,
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

function Core.evaluate(tree, collected_paths)
	local statuses = {}
	collected_paths = collected_paths or {}

	local function visit(node)
		if node.kind == "symlink" then
			return nil
		end

		if node.kind == "file" then
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
			local result = visit(child)
			if result then
				candidates = candidates + result.candidates
				collected = collected + result.collected
			end
		end

		local status
		if candidates == 0 then
			status = "not applicable"
		elseif collected == candidates then
			status = "collected"
		elseif collected == 0 then
			status = "uncollected"
		else
			status = "mixed"
		end
		local result = { status = status, candidates = candidates, collected = collected }
		statuses[node.path] = result
		return result
	end

	visit(tree)
	return { statuses = statuses }
end

return Core
