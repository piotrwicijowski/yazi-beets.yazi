--- @since 25.2.13
local Core = require(".core")

local M = {}
local options = {}
local lookup_cache

local configured_options = ya.sync(function(state)
	return state.options or {}
end)

local store_options = ya.sync(function(state, value)
	state.options = value
end)

local current_directory = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local begin_snapshot = ya.sync(function(state, snapshot)
	state.generation = (state.generation or 0) + 1
	snapshot.generation = state.generation
	state.snapshot = snapshot
	ui.render()
	return state.generation
end)

local finish_snapshot = ya.sync(function(state, generation, snapshot)
	if state.generation ~= generation then
		return false
	end
	state.snapshot = snapshot
	ui.render()
	return true
end)

local snapshot_for = ya.sync(function(state)
	return state.snapshot
end)

local publish_statuses = ya.sync(function(state, generation, statuses)
	if state.generation ~= generation or not state.snapshot or state.snapshot.phase ~= "streaming" then
		return false
	end
	for path, result in pairs(statuses) do
		state.snapshot.statuses[path] = result
	end
	ui.render()
	return true
end)

local publish_tag_marker = ya.sync(function(state, generation, index, marker_snapshot)
	if state.generation ~= generation or not state.snapshot or state.snapshot.phase ~= "streaming" then
		return false
	end
	state.snapshot.tag_markers[index] = marker_snapshot
	ui.render()
	return true
end)

local function library_identity()
	if options.library and options.directory then
		return string.format("%s (root: %s)", options.library, options.directory)
	end
	return "default beets configuration"
end

local function read_directory(path)
	local files, err = fs.read_dir(Url(path), { resolve = false })
	if not files then
		return nil, err
	end

	local entries = {}
	for _, file in ipairs(files) do
		local cha = file.cha or {}
		entries[#entries + 1] = {
			path = tostring(file.url),
			kind = cha.is_symlink and "symlink" or (cha.is_dir and "directory" or "file"),
		}
	end
	return entries
end

local function failure_snapshot(directory, reason)
	return { directory = directory, phase = "unavailable", reason = reason, library = library_identity() }
end

local function cache_fingerprint()
	if not options.library then
		return nil
	end

	local function fingerprint_part(path, optional)
		local cha, err = fs.cha(Url(path), false)
		if cha then
			return string.format("%s:%s", tostring(cha.mtime), tostring(cha.len))
		end
		if optional and err and err.kind == "NotFound" then
			return "absent"
		end
		return nil
	end

	local database = fingerprint_part(options.library, false)
	local wal = fingerprint_part(options.library .. "-wal", true)
	if not database or not wal then
		return nil
	end
	return database .. "/" .. wal
end

local function cached_paths(force_refresh)
	if force_refresh or not lookup_cache then
		return nil
	end
	local fingerprint = cache_fingerprint()
	if fingerprint and lookup_cache.fingerprint == fingerprint then
		return lookup_cache.paths
	end
	return nil
end

function M:reload(directory, force_refresh)
	options = configured_options()
	local pending = { directory = directory, phase = "pending", library = library_identity() }
	local generation = begin_snapshot(pending)
	local cache_enabled, cache_error = Core.cache_enabled(options)
	if cache_enabled == nil then
		finish_snapshot(generation, failure_snapshot(directory, "invalid configuration: " .. cache_error))
		return
	end
	local exclusions, exclusion_error = Core.validate_exclusions(options)
	if not exclusions then
		finish_snapshot(generation, failure_snapshot(directory, "invalid configuration: " .. exclusion_error))
		return
	end
	local markers, marker_error = Core.validate_tag_markers(options)
	local tag_marker_configuration_error
	if not markers then
		markers = {}
		tag_marker_configuration_error = "invalid configuration: " .. marker_error
	end

	local command, configuration_error = Core.lookup_command(options)
	if not command then
		finish_snapshot(generation, failure_snapshot(directory, "invalid configuration: " .. configuration_error))
		return
	end

	if options.directory and not Core.is_within_root(directory, options.directory) then
		local tag_markers = {}
		for index, marker in ipairs(markers) do
			tag_markers[index] = {
				marker = marker,
				phase = "ready",
				outside_music_directory_root = true,
			}
		end
		finish_snapshot(generation, {
			directory = directory,
			phase = "ready",
			outside_music_directory_root = true,
			tag_markers = tag_markers,
			tag_marker_configuration_error = tag_marker_configuration_error,
			library = library_identity(),
		})
		return
	end

	local root = { path = directory, kind = "directory", children = {} }
	local root_result = Core.evaluate(root, {}, exclusions).statuses[directory]
	if root_result.reason == "excluded by configuration" then
		finish_snapshot(generation, {
			directory = directory,
			phase = "ready",
			statuses = { [directory] = root_result },
			library = library_identity(),
		})
		return
	end

	local entries, read_error = read_directory(directory)
	if not entries then
		finish_snapshot(generation, failure_snapshot(directory, "directory scan failed: " .. tostring(read_error)))
		return
	end

	local statuses = {}
	local tag_markers = {}
	for _, marker in ipairs(markers) do
		tag_markers[#tag_markers + 1] = { marker = marker, phase = "pending" }
	end
	if not finish_snapshot(generation, {
		directory = directory,
		phase = "streaming",
		statuses = statuses,
		tag_markers = tag_markers,
		tag_marker_configuration_error = tag_marker_configuration_error,
		library = library_identity(),
	}) then
		return
	end

	local paths
	local collection_failure
	local collection_attempted = false
	local function resolve_paths()
		if paths or collection_attempted then
			return paths
		end
		collection_attempted = true
		paths = cache_enabled and cached_paths(force_refresh) or nil
		if paths then
			return paths
		end

		local fingerprint = cache_enabled and cache_fingerprint() or nil
		local output, command_error = Command(command.program):arg(command.args):output()
		if not output then
			collection_failure = "could not start beet: " .. tostring(command_error)
			return nil
		end
		if not output.status.success then
			collection_failure = string.format(
				"beet exited with code %s: %s", tostring(output.status.code), tostring(output.stderr or "")
			)
			return nil
		end
		if type(output.stdout) ~= "string" then
			collection_failure = "beet output could not be read"
			return nil
		end

		paths = Core.collected_paths(output.stdout)
		if fingerprint and fingerprint == cache_fingerprint() then
			lookup_cache = { fingerprint = fingerprint, paths = paths }
		end
		return paths
	end

	local candidates, collected = 0, 0
	local work = {}
	for _, entry in ipairs(entries) do
		if entry.kind ~= "directory" then
			work[#work + 1] = entry
		end
	end
	for _, entry in ipairs(entries) do
		if entry.kind == "directory" then
			work[#work + 1] = entry
		end
	end
	for _, entry in ipairs(work) do
		local tree = entry
		if entry.kind == "directory" then
			local scan_error
			tree, scan_error = Core.scan(entry.path, read_directory)
			if not tree then
				finish_snapshot(generation, failure_snapshot(directory, "directory scan failed: " .. scan_error))
				return
			end
		end
		root.children[#root.children + 1] = tree

		local candidate_count = Core.candidate_count(tree, exclusions)
		if candidate_count > 0 then
			resolve_paths()
		end
		if paths or candidate_count == 0 then
			local evaluation = Core.evaluate(tree, paths or {}, exclusions)
			for path, result in pairs(evaluation.statuses) do
				statuses[path] = result
			end
			local result = evaluation.statuses[entry.path]
			if result then
				candidates = candidates + result.candidates
				collected = collected + result.collected
			end
			if next(evaluation.statuses) and not publish_statuses(generation, evaluation.statuses) then
				return
			end
		end
	end

	statuses[directory] = Core.directory_result(candidates, collected)

	local query_results = {}
	for index, marker in ipairs(markers) do
		local query_result = query_results[marker.query]
		if not query_result then
			local marker_command = assert(Core.lookup_command(options, marker.query))
			local output, command_error = Command(marker_command.program):arg(marker_command.args):output()
			if not output then
				query_result = { reason = "could not start beet: " .. tostring(command_error) }
			elseif not output.status.success then
				query_result = { reason = string.format(
					"beet exited with code %s: %s", tostring(output.status.code), tostring(output.stderr or "")
				) }
			elseif type(output.stdout) ~= "string" then
				query_result = { reason = "beet output could not be read" }
			else
				query_result = { paths = Core.collected_paths(output.stdout) }
			end
			query_results[marker.query] = query_result
		end

		if query_result.paths then
			tag_markers[index] = {
				marker = marker,
				phase = "ready",
				statuses = Core.match(root, query_result.paths, exclusions).statuses,
			}
		else
			tag_markers[index] = { marker = marker, phase = "unavailable", reason = query_result.reason }
		end
		if not publish_tag_marker(generation, index, tag_markers[index]) then
			return
		end
	end

	finish_snapshot(generation, {
		directory = directory,
		phase = collection_failure and "unavailable" or "ready",
		reason = collection_failure,
		statuses = statuses,
		tag_markers = tag_markers,
		tag_marker_configuration_error = tag_marker_configuration_error,
		library = library_identity(),
	})
end

function M:entry()
	M:reload(current_directory(), true)
end

function M:setup(user_options)
	options = user_options or {}
	store_options(options)
	lookup_cache = nil
	ps.sub("cd", function()
		local directory = current_directory()
		ya.async(function()
			M:reload(directory)
		end)
	end)
end

function M:linemode(file)
	local snapshot = snapshot_for()
	local status = Core.status_for(snapshot, tostring(file.url))
	if file.cha and file.cha.is_symlink and (not status or status.status ~= "not applicable") then
		return ""
	end
	local markers = { Core.marker(status and status.status) }
	for _, marker_snapshot in ipairs((snapshot and snapshot.tag_markers) or {}) do
		local marker_status = Core.tag_marker_status_for(marker_snapshot, tostring(file.url))
		markers[#markers + 1] = marker_snapshot.marker.label .. Core.tag_marker_glyph(marker_status and marker_status.status)
	end
	if snapshot and snapshot.tag_marker_configuration_error then
		markers[#markers + 1] = "tags!"
	end
	return table.concat(markers, " ")
end

function M:card(file)
	local snapshot = snapshot_for()
	local result = Core.status_for(snapshot, tostring(file.url))
	if file.cha and file.cha.is_symlink and (not result or result.status ~= "not applicable") then
		return "Collection status: Not applicable\nSymlinks are excluded from collection-membership evaluation."
	end
	local card = Core.card(tostring(file.url), result, (snapshot and snapshot.library) or library_identity())
	for _, marker_snapshot in ipairs((snapshot and snapshot.tag_markers) or {}) do
		card = card .. "\n" .. Core.tag_marker_card(
			marker_snapshot.marker,
			Core.tag_marker_status_for(marker_snapshot, tostring(file.url))
		)
	end
	if snapshot and snapshot.tag_marker_configuration_error then
		card = card .. "\nTag markers: Unavailable: " .. snapshot.tag_marker_configuration_error
	end
	return card
end

function M:peek(job)
	ya.preview_widget(job, ui.Text(M:card(job.file)):area(job.area))
end

function M:seek()
end

return M
