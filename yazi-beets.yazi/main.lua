--- @since 25.2.13
local Core = require(".core")

local M = {}
local options = {}

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

function M:reload(directory)
	local pending = { directory = directory, phase = "pending", library = library_identity() }
	local generation = begin_snapshot(pending)
	local command, configuration_error = Core.lookup_command(options, directory)
	if not command then
		finish_snapshot(generation, failure_snapshot(directory, "invalid configuration: " .. configuration_error))
		return
	end

	local tree, scan_error = Core.scan(directory, read_directory)
	if not tree then
		finish_snapshot(generation, failure_snapshot(directory, "directory scan failed: " .. scan_error))
		return
	end

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

	local evaluation = Core.evaluate(tree, Core.collected_paths(output.stdout))
	finish_snapshot(generation, {
		directory = directory,
		phase = "ready",
		statuses = evaluation.statuses,
		library = library_identity(),
	})
end

function M:entry()
	local directory = current_directory()
	ya.async(function()
		M:reload(directory)
	end)
end

function M:setup(user_options)
	options = user_options or {}
	ps.sub("cd", function()
		M:entry()
	end)
end

function M:linemode(file)
	if file.cha and file.cha.is_symlink then
		return ""
	end
	local status = Core.status_for(snapshot_for(), tostring(file.url))
	return Core.marker(status and status.status)
end

function M:card(file)
	if file.cha and file.cha.is_symlink then
		return "Collection status: Not applicable\nSymlinks are excluded from collection-membership evaluation."
	end
	local snapshot = snapshot_for()
	local result = Core.status_for(snapshot, tostring(file.url))
	return Core.card(tostring(file.url), result, (snapshot and snapshot.library) or library_identity())
end

function M:peek(job)
	ya.preview_widget(job, ui.Text(M:card(job.file)):area(job.area))
end

function M:seek()
end

return M
