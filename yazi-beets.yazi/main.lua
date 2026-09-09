--- @since 25.2.13
local Core = require(".core")

local M = {}
local options = {}
local lookup_cache

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

	local command, configuration_error = Core.lookup_command(options)
	if not command then
		finish_snapshot(generation, failure_snapshot(directory, "invalid configuration: " .. configuration_error))
		return
	end

	if options.directory and not Core.is_within_root(directory, options.directory) then
		finish_snapshot(generation, {
			directory = directory,
			phase = "ready",
			outside_music_directory_root = true,
			library = library_identity(),
		})
		return
	end

	local tree, scan_error = Core.scan(directory, read_directory)
	if not tree then
		finish_snapshot(generation, failure_snapshot(directory, "directory scan failed: " .. scan_error))
		return
	end

	if Core.candidate_count(tree, exclusions) == 0 then
		local evaluation = Core.evaluate(tree, {}, exclusions)
		finish_snapshot(generation, {
			directory = directory,
			phase = "ready",
			statuses = evaluation.statuses,
			library = library_identity(),
		})
		return
	end

	local paths = cache_enabled and cached_paths(force_refresh) or nil
	if paths then
		local evaluation = Core.evaluate(tree, paths, exclusions)
		finish_snapshot(generation, {
			directory = directory,
			phase = "ready",
			statuses = evaluation.statuses,
			library = library_identity(),
		})
		return
	end

	local fingerprint = cache_enabled and cache_fingerprint() or nil
	local output, command_error = Command(command.program):arg(command.args):output()
	if not output then
		finish_snapshot(generation, failure_snapshot(directory, "could not start beet: " .. tostring(command_error)))
		return
	end
	if not output.status.success then
		finish_snapshot(generation, failure_snapshot(directory, string.format(
			"beet exited with code %s: %s", tostring(output.status.code), tostring(output.stderr or "")
		)))
		return
	end
	if type(output.stdout) ~= "string" then
		finish_snapshot(generation, failure_snapshot(directory, "beet output could not be read"))
		return
	end

	paths = Core.collected_paths(output.stdout)
	if fingerprint and fingerprint == cache_fingerprint() then
		lookup_cache = { fingerprint = fingerprint, paths = paths }
	end
	local evaluation = Core.evaluate(tree, paths, exclusions)
	finish_snapshot(generation, {
		directory = directory,
		phase = "ready",
		statuses = evaluation.statuses,
		library = library_identity(),
	})
end

function M:entry()
	M:reload(current_directory(), true)
end

function M:setup(user_options)
	options = user_options or {}
	lookup_cache = nil
	ps.sub("cd", function()
		local directory = current_directory()
		ya.async(function()
			M:reload(directory)
		end)
	end)
end

function M:linemode(file)
	local status = Core.status_for(snapshot_for(), tostring(file.url))
	if file.cha and file.cha.is_symlink and (not status or status.status ~= "not applicable") then
		return ""
	end
	return Core.marker(status and status.status)
end

function M:card(file)
	local snapshot = snapshot_for()
	local result = Core.status_for(snapshot, tostring(file.url))
	if file.cha and file.cha.is_symlink and (not result or result.status ~= "not applicable") then
		return "Collection status: Not applicable\nSymlinks are excluded from collection-membership evaluation."
	end
	return Core.card(tostring(file.url), result, (snapshot and snapshot.library) or library_identity())
end

function M:peek(job)
	ya.preview_widget(job, ui.Text(M:card(job.file)):area(job.area))
end

function M:seek()
end

return M
