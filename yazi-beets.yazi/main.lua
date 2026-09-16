--- @since 25.2.13
local Core = require(".core")

local M = {}
local options = {}
local lookup_cache
local STATUS_PUBLISH_INTERVAL = 0.05
local TAG_PUBLISH_INTERVAL = 0.05
local TOGGLE_PATHS_PER_COMMAND = 100
local TOGGLE_DEBUG_PREFIX = "[DEBUG-toggle-7d21] "

local configured_options = ya.sync(function(state)
	return state.options or {}
end)

local store_options = ya.sync(function(state, value)
	state.options = value
end)

local configured_cache = ya.sync(function(state)
	return state.lookup_cache
end)

local store_cache = ya.sync(function(state, value)
	state.lookup_cache = value
end)

local current_directory = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local toggle_targets = ya.sync(function()
	local targets = {}
	for _, file in pairs(cx.active.selected or {}) do
		local cha = file.cha or {}
		targets[#targets + 1] = {
			path = tostring(file.url),
			kind = cha.is_symlink and "symlink" or (cha.is_dir and "directory" or "file"),
		}
	end
	if #targets == 0 then
		local file = cx.active.current.hovered
		if file then
			local cha = file.cha or {}
			targets[1] = {
				path = tostring(file.url),
				kind = cha.is_symlink and "symlink" or (cha.is_dir and "directory" or "file"),
			}
		end
	end
	return targets
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

local mark_tag_marker_pending = ya.sync(function(state, directory, label, targets)
	local snapshot = state.snapshot
	if not snapshot or snapshot.directory ~= directory then
		return false
	end
	for index, marker_snapshot in ipairs(snapshot.tag_markers or {}) do
		if marker_snapshot.marker.label == label and marker_snapshot.phase == "ready" then
			local statuses = {}
			for path, result in pairs(marker_snapshot.statuses or {}) do
				statuses[path] = result
			end
			for _, target in ipairs(targets) do
				statuses[target.path] = { status = "pending" }
			end
			snapshot.tag_markers[index] = {
				marker = marker_snapshot.marker,
				phase = "ready",
				statuses = statuses,
			}
			ui.render()
			return true
		end
	end
	return false
end)

local replace_tag_marker = ya.sync(function(state, directory, query, statuses)
	local snapshot = state.snapshot
	if not snapshot or snapshot.directory ~= directory then
		return false
	end
	local replaced = false
	for index, marker_snapshot in ipairs(snapshot.tag_markers or {}) do
		if marker_snapshot.marker.query == query then
			snapshot.tag_markers[index] = {
				marker = marker_snapshot.marker,
				phase = "ready",
				statuses = statuses,
			}
			replaced = true
		end
	end
	if replaced then
		ui.render()
	end
	return replaced
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

local publish_tag_markers = ya.sync(function(state, generation, marker_snapshots)
	if state.generation ~= generation or not state.snapshot or state.snapshot.phase ~= "streaming" then
		return false
	end
	for index, marker_snapshot in pairs(marker_snapshots) do
		state.snapshot.tag_markers[index] = marker_snapshot
	end
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

local function cached_paths(query, force_refresh)
	if force_refresh or not lookup_cache then
		return nil
	end
	local fingerprint = cache_fingerprint()
	if fingerprint and lookup_cache.fingerprint == fingerprint then
		return lookup_cache.paths_by_query[query or false]
	end
	-- A tag toggle is known not to change collection membership, but SQLite's
	-- database/WAL fingerprint can settle after the toggle command returns.
	-- Accept one such delayed transition for the collection path set only.
	if fingerprint and query == nil and lookup_cache.collection_cache_grace then
		lookup_cache.fingerprint = fingerprint
		lookup_cache.collection_cache_grace = nil
		store_cache(lookup_cache)
		return lookup_cache.paths_by_query[false]
	end
	return nil
end

local function cache_paths(query, paths, fingerprint)
	if not fingerprint or fingerprint ~= cache_fingerprint() then
		return
	end
	if not lookup_cache or lookup_cache.fingerprint ~= fingerprint then
		lookup_cache = { fingerprint = fingerprint, paths_by_query = {} }
	end
	lookup_cache.paths_by_query[query or false] = paths
	store_cache(lookup_cache)
end

function M:reload(directory, force_refresh)
	options = configured_options()
	lookup_cache = configured_cache()
	if force_refresh then
		lookup_cache = nil
		store_cache(nil)
	end
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
	local collection_cache_checked = false
	if cache_enabled and not force_refresh then
		collection_cache_checked = true
		paths = cached_paths(nil, false)
	end
	local function resolve_paths()
		if paths or collection_attempted then
			return paths
		end
		collection_attempted = true
		if cache_enabled and not collection_cache_checked then
			collection_cache_checked = true
			paths = cached_paths(nil, force_refresh)
		end
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
		if cache_enabled then
			cache_paths(nil, paths, fingerprint)
		end
		return paths
	end

	local pending_statuses = {}
	local last_status_publish = ya.time()
	local function publish_pending_statuses(force)
		if not next(pending_statuses) then
			return true
		end
		if not force and ya.time() - last_status_publish < STATUS_PUBLISH_INTERVAL then
			return true
		end
		local batch = pending_statuses
		pending_statuses = {}
		if not publish_statuses(generation, batch) then
			return false
		end
		last_status_publish = ya.time()
		return true
	end

	local candidates, collected = 0, 0
	local work = {}
	for _, entry in ipairs(entries) do
		if entry.kind ~= "directory" then
			work[#work + 1] = entry
		end
	end
	local direct_entry_count = #work
	for _, entry in ipairs(entries) do
		if entry.kind == "directory" then
			work[#work + 1] = entry
		end
	end
	for work_index, entry in ipairs(work) do
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

		local evaluation
		if paths then
			evaluation = Core.evaluate(tree, paths, exclusions)
		else
			local candidate_count = Core.candidate_count(tree, exclusions)
			if candidate_count > 0 then
				resolve_paths()
			end
			if paths or candidate_count == 0 then
				evaluation = Core.evaluate(tree, paths or {}, exclusions)
			end
		end
		if evaluation then
			for path, result in pairs(evaluation.statuses) do
				statuses[path] = result
				pending_statuses[path] = result
			end
			local result = evaluation.statuses[entry.path]
			if result then
				candidates = candidates + result.candidates
				collected = collected + result.collected
			end
			if not publish_pending_statuses(work_index == direct_entry_count) then
				return
			end
		end
	end

	if not publish_pending_statuses(true) then
		return
	end
	statuses[directory] = Core.directory_result(candidates, collected)

	local query_results = {}
	local pending_tag_markers = {}
	local last_tag_publish = ya.time()
	local function publish_pending_tag_markers(force)
		if not next(pending_tag_markers) then
			return true
		end
		if not force and ya.time() - last_tag_publish < TAG_PUBLISH_INTERVAL then
			return true
		end
		local batch = pending_tag_markers
		pending_tag_markers = {}
		if not publish_tag_markers(generation, batch) then
			return false
		end
		last_tag_publish = ya.time()
		return true
	end

	for index, marker in ipairs(markers) do
		local query_result = query_results[marker.query]
		if not query_result then
			query_result = { paths = cache_enabled and cached_paths(marker.query, force_refresh) or nil }
			if not query_result.paths then
				local marker_command = assert(Core.lookup_command(options, marker.query))
				local fingerprint = cache_enabled and cache_fingerprint() or nil
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
					if cache_enabled then
						cache_paths(marker.query, query_result.paths, fingerprint)
					end
				end
			end
			query_results[marker.query] = query_result
		end

		if not query_result.paths then
			tag_markers[index] = { marker = marker, phase = "unavailable", reason = query_result.reason }
			pending_tag_markers[index] = tag_markers[index]
			if not publish_pending_tag_markers(true) then
				return
			end
		end
	end

	local matching_path_sets, matching_indexes = {}, {}
	for _, marker in ipairs(markers) do
		local query_result = query_results[marker.query]
		if query_result.paths and not matching_indexes[marker.query] then
			matching_indexes[marker.query] = #matching_path_sets + 1
			matching_path_sets[#matching_path_sets + 1] = query_result.paths
		end
	end
	local matching_evaluations = Core.match_all(root, matching_path_sets, exclusions)
	for index, marker in ipairs(markers) do
		local query_result = query_results[marker.query]
		if query_result.paths then
			tag_markers[index] = {
				marker = marker,
				phase = "ready",
				statuses = matching_evaluations[matching_indexes[marker.query]].statuses,
			}
			pending_tag_markers[index] = tag_markers[index]
		end
	end
	if not publish_pending_tag_markers(true) then
		return
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

local function debug_toggle(message)
	if ya.dbg then
		ya.dbg(TOGGLE_DEBUG_PREFIX .. message)
	end
end

local function command_description(command)
	return command.program .. " " .. table.concat(command.args, " ")
end

local function report_toggle_error(reason)
	debug_toggle("failed: " .. reason)
	if ya.err then
		ya.err("yazi-beets: " .. reason)
	end
end

local function run_toggle_command(stage, command)
	debug_toggle(stage .. " start: " .. command_description(command))
	local ok, output, command_error = pcall(function()
		return Command(command.program):arg(command.args):output()
	end)
	if not ok then
		return nil, "Yazi Command exception: " .. tostring(output)
	end
	if not output then
		debug_toggle(stage .. " finished without output: " .. tostring(command_error))
		return nil, command_error
	end
	local status = output.status or {}
	debug_toggle(string.format(
		"%s finished: success=%s code=%s stdout_bytes=%s stderr=%s",
		stage,
		tostring(status.success),
		tostring(status.code),
		type(output.stdout) == "string" and #output.stdout or tostring(type(output.stdout)),
		tostring(output.stderr or "")
	))
	return output
end

function M:toggle_marker(directory, label, targets, action)
	targets = targets or {}
	action = action or "toggle"
	if action ~= "toggle" and action ~= "set" and action ~= "clear" then
		return nil, "unknown marker action " .. tostring(action)
	end
	debug_toggle(string.format(
		"requested action=%q label=%q directory=%q targets=%d", action, tostring(label), directory, #targets
	))
	options = configured_options()
	lookup_cache = configured_cache()
	local markers, marker_error = Core.validate_tag_markers(options)
	if not markers then
		return nil, "invalid configuration: " .. marker_error
	end
	local marker
	for _, candidate in ipairs(markers) do
		if candidate.label == label then
			marker = candidate
			break
		end
	end
	if not marker then
		return nil, "unknown tag marker " .. tostring(label)
	end
	debug_toggle(string.format("marker label=%q field=%q query=%q", marker.label, marker.field, marker.query))

	local exclusions, exclusion_error = Core.validate_exclusions(options)
	if not exclusions then
		return nil, "invalid configuration: " .. exclusion_error
	end
	local lookup_command, configuration_error = Core.lookup_command(options, marker.query)
	if not lookup_command then
		return nil, "invalid configuration: " .. configuration_error
	end
	if options.directory and not Core.is_within_root(directory, options.directory) then
		return nil, "directory is outside the configured music directory root"
	end

	if #targets == 0 then
		return nil, "no hovered or selected item"
	end
	local tree = { path = directory, kind = "directory", children = {} }
	for _, target in ipairs(targets) do
		local target_tree = target
		if target.kind == "directory" then
			local scan_error
			target_tree, scan_error = Core.scan(target.path, read_directory)
			if not target_tree then
				return nil, "directory scan failed: " .. scan_error
			end
		end
		tree.children[#tree.children + 1] = target_tree
	end
	local paths = Core.candidate_paths(tree, exclusions)
	debug_toggle("candidate files=" .. #paths)
	if #paths == 0 then
		return nil, "directory contains no candidate files"
	end

	local cache_fingerprint_before = options.cache == true and cache_fingerprint() or nil
	local enabled
	if action == "toggle" then
		local output, command_error = run_toggle_command("marker lookup", lookup_command)
		if not output then
			return nil, "could not start beet: " .. tostring(command_error)
		end
		if not output.status.success then
			return nil, string.format("beet exited with code %s: %s", tostring(output.status.code), tostring(output.stderr or ""))
		end
		if type(output.stdout) ~= "string" then
			return nil, "beet output could not be read"
		end
		local status = Core.match(tree, Core.collected_paths(output.stdout), exclusions).statuses[directory]
		enabled = status.status ~= "all"
		debug_toggle(string.format(
			"marker status=%s matching=%d/%d; action=%s",
			status.status,
			status.matching or 0,
			status.candidates or 0,
			enabled and "set true" or "remove field"
		))
	else
		enabled = action == "set"
		debug_toggle("unconditional action=" .. (enabled and "set true" or "remove field"))
	end
	local output, command_error
	for first = 1, #paths, TOGGLE_PATHS_PER_COMMAND do
		local batch = {}
		for index = first, math.min(first + TOGGLE_PATHS_PER_COMMAND - 1, #paths) do
			batch[#batch + 1] = paths[index]
		end
		local mutation_command = assert(Core.toggle_command(options, batch, marker.field, enabled))
		output, command_error = run_toggle_command(
			string.format("mutation batch=%d-%d", first, first + #batch - 1),
			mutation_command
		)
		if not output then
			return nil, "could not start beet: " .. tostring(command_error)
		end
		if not output.status.success then
			return nil, string.format("beet exited with code %s: %s", tostring(output.status.code), tostring(output.stderr or ""))
		end
	end

	local active_tree, active_scan_error = Core.scan(directory, read_directory)
	if not active_tree then
		return nil, "directory scan failed: " .. active_scan_error
	end
	local refreshed_output, refresh_error = run_toggle_command("marker refresh", lookup_command)
	if not refreshed_output then
		return nil, "could not start beet: " .. tostring(refresh_error)
	end
	if not refreshed_output.status.success then
		return nil, string.format(
			"beet exited with code %s: %s", tostring(refreshed_output.status.code), tostring(refreshed_output.stderr or "")
		)
	end
	if type(refreshed_output.stdout) ~= "string" then
		return nil, "beet output could not be read"
	end
	local refreshed_paths = Core.collected_paths(refreshed_output.stdout)
	local refreshed_statuses = Core.match(active_tree, refreshed_paths, exclusions).statuses
	if options.cache == true and lookup_cache and cache_fingerprint_before
		and lookup_cache.fingerprint == cache_fingerprint_before then
		local cache_fingerprint_after = cache_fingerprint()
		if cache_fingerprint_after then
			lookup_cache.fingerprint = cache_fingerprint_after
			lookup_cache.paths_by_query[marker.query] = refreshed_paths
			lookup_cache.collection_cache_grace = true
			store_cache(lookup_cache)
		end
	end
	if not replace_tag_marker(directory, marker.query, refreshed_statuses) then
		return nil, "active directory changed before tag marker refresh"
	end
	debug_toggle("mutation succeeded; refreshed marker snapshot without collection reload")
	return true
end

function M.entry(self_or_job, maybe_job)
	-- Yazi passes (self, job) in supported releases.  Accept a direct job as
	-- well: older runners and test harnesses may call a functional entry with
	-- only its job argument.
	local job = maybe_job or self_or_job
	local args = job and job.args
	local action, label
	local conflict = false
	local function select_action(name, candidate_label)
		if candidate_label == nil then
			return
		end
		if action then
			conflict = true
			return
		end
		action, label = name, candidate_label
	end
	select_action("toggle", args and args["toggle-marker"])
	select_action("set", args and args["set-marker"])
	select_action("clear", args and args["clear-marker"])

	local positional = args and args[1]
	if type(positional) == "string" then
		local action_name, positional_label = positional:match("^([^=]+)=(.*)$")
		local positional_actions = {
			["toggle-marker"] = "toggle",
			["set-marker"] = "set",
			["clear-marker"] = "clear",
		}
		select_action(positional_actions[action_name], positional_label)
	end
	if conflict then
		report_toggle_error("pass exactly one marker action")
		return
	end
	debug_toggle(string.format(
		"entry first=%s second=%s action=%s label=%s positional=%s",
		tostring(self_or_job),
		tostring(maybe_job),
		tostring(action),
		tostring(label),
		tostring(args and args[1])
	))
	if action then
		local directory = current_directory()
		local targets = toggle_targets()
		debug_toggle("marker pending=" .. tostring(mark_tag_marker_pending(directory, label, targets)))
		local ok, reason = M:toggle_marker(directory, label, targets, action)
		if not ok then
			M:reload(directory, true)
			report_toggle_error(reason)
		end
		return
	end
	M:reload(current_directory(), true)
end

function M:setup(user_options)
	options = user_options or {}
	store_options(options)
	lookup_cache = nil
	store_cache(nil)
	ps.sub("cd", function()
		local directory = current_directory()
		ya.async(function()
			M:reload(directory)
		end)
	end)
end

function M:linemode(file)
	local snapshot = snapshot_for()
	if snapshot and snapshot.outside_music_directory_root then
		return ""
	end
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
