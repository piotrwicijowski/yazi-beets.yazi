local root = (... and (...):match("^(.*)/[^/]+$")) or "."
package.path = root .. "/yazi-beets.yazi/?.lua;" .. package.path

local plugin_state = {}
local commands = {}
local renders = 0
local render_history = {}
local debug_messages = {}
local clock = 0
local directory_reads = 0
local subscriptions = {}
local on_command_output
local outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "database unavailable" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
local library_metadata = {
	["/data/library.db"] = { mtime = 100, len = 4096 },
}
local listing = {
	["/music"] = {
		{ url = "/music/album", cha = { is_dir = true } },
		{ url = "/music/loose.mp3", cha = {} },
	},
	["/music/album"] = {
		{ url = "/music/album/song.flac", cha = {} },
		{ url = "/music/album/link.flac", cha = { is_symlink = true } },
	},
}

_G.ya = {
	sync = function(callback)
		return function(...)
			return callback(plugin_state, ...)
		end
	end,
	async = function(callback)
		return callback()
	end,
	time = function()
		clock = clock + 0.001
		return clock
	end,
	dbg = function(message)
		debug_messages[#debug_messages + 1] = message
	end,
}
_G.ui = {
	render = function()
		renders = renders + 1
		local snapshot = plugin_state.snapshot or {}
		local statuses = snapshot.statuses or {}
		local marker_phases, marker_statuses = {}, {}
		for index, marker_snapshot in ipairs(snapshot.tag_markers or {}) do
			marker_phases[index] = marker_snapshot.phase
			local marker_results = marker_snapshot.statuses or {}
			marker_statuses[index] = {
				album = marker_results["/music/album"] and marker_results["/music/album"].status,
				loose = marker_results["/music/loose.mp3"] and marker_results["/music/loose.mp3"].status,
			}
		end
		render_history[#render_history + 1] = {
			phase = snapshot.phase,
			album = statuses["/music/album"] and statuses["/music/album"].status,
			loose = statuses["/music/loose.mp3"] and statuses["/music/loose.mp3"].status,
			marker_phases = marker_phases,
			marker_statuses = marker_statuses,
		}
	end,
}
_G.cx = nil
_G.ps = { sub = function(event, callback) subscriptions[event] = callback end }
_G.Url = function(path) return path end
_G.fs = {
	read_dir = function(path)
		directory_reads = directory_reads + 1
		return listing[tostring(path)]
	end,
	cha = function(path)
		local metadata = library_metadata[tostring(path)]
		if metadata then
			return metadata
		end
		return nil, { kind = "NotFound" }
	end,
}
_G.Command = function(program)
	local command = { program = program, args = {} }
	function command:arg(args)
		for _, argument in ipairs(args) do
			self.args[#self.args + 1] = argument
		end
		return self
	end
	function command:output()
		local output = table.remove(outputs, 1)
		if on_command_output then
			on_command_output(self, output)
		end
		return output
	end
	commands[#commands + 1] = command
	return command
end

local lua_require = require
local requested_modules = {}
require = function(name)
	requested_modules[#requested_modules + 1] = name
	if name == ".core" then
		return lua_require("core")
	end
	return lua_require(name)
end

local Plugin = require("main")
local Core = require("core")
assert(requested_modules[2] == ".core", "the core module must be required relative to the plugin")

local function file(path, properties)
	return { url = path, cha = properties or {} }
end

Plugin:setup({})
assert(type(subscriptions.cd) == "function", "setup must subscribe to directory changes")
assert(#commands == 0, "setup must not read a directory before Yazi creates cx")

_G.cx = { active = { current = { cwd = "/music" } } }
subscriptions.cd()
assert(#commands == 1, "entering a directory starts one lookup")
assert(commands[1].program == "beet")
assert(table.concat(commands[1].args, " ") == "list -p")
assert(Plugin:linemode(file("/music/album/song.flac")) == "●")
assert(Plugin:linemode(file("/music/loose.mp3")) == "○")
assert(Plugin:linemode(file("/music/album")) == "●")
assert(Plugin:linemode(file("/music")) == "◐")
assert(Plugin:linemode(file("/music/album/link.flac", { is_symlink = true })) == "")
assert(Plugin:card(file("/music/album")):find("Candidates: 1 %(1 collected%)"))
assert(renders >= 2, "pending and ready snapshots redraw the UI")
local saw_partial_update = false
for _, snapshot in ipairs(render_history) do
	if snapshot.phase == "streaming" and snapshot.loose == "uncollected" and snapshot.album == nil then
		saw_partial_update = true
	end
end
assert(saw_partial_update, "direct files publish before current-directory subtrees finish")

subscriptions.cd()
assert(#commands == 2, "re-entering a directory starts one fresh lookup")
assert(Plugin:linemode(file("/music/loose.mp3")) == "!", "a failed lookup is unavailable, not uncollected")

_G.ya.async = function()
	error("ya.async() can only be used in sync context")
end
Plugin:entry()
assert(#commands == 3, "the async functional entry point refreshes without ya.async")

Plugin:setup({ library = "/data/library.db" })
local reads_before_invalid_override = directory_reads
Plugin:entry()
assert(#commands == 3, "invalid configuration never invokes beet")
assert(directory_reads == reads_before_invalid_override, "invalid configuration never scans directories")
assert(Plugin:linemode(file("/music/loose.mp3")) == "!")
assert(Plugin:card(file("/music/loose.mp3")):find("Correct configuration"))

Plugin:setup({
	ignore_extensions = { "mp3" },
	ignore_subdirectories = { "album" },
})
local reads_before_excluded_tree = directory_reads
Plugin:entry()
assert(#commands == 3, "a zero-candidate tree must not invoke beet")
assert(directory_reads == reads_before_excluded_tree + 2, "valid exclusions still scan the tree")
assert(Plugin:linemode(file("/music/loose.mp3")) == "—")
assert(Plugin:linemode(file("/music/album")) == "—")
assert(Plugin:linemode(file("/music/album/link.flac", { is_symlink = true })) == "—")
assert(Plugin:card(file("/music/loose.mp3")):find("excluded from collection%-membership evaluation"))

Plugin:setup({ ignore_extensions = { ".mp3" } })
local reads_before_invalid_exclusions = directory_reads
Plugin:entry()
assert(#commands == 3, "invalid exclusion configuration must not invoke beet")
assert(directory_reads == reads_before_invalid_exclusions, "invalid exclusions never scan directories")
assert(Plugin:linemode(file("/music/loose.mp3")) == "!")
assert(Plugin:card(file("/music/loose.mp3")):find("ignore_extensions%[1%]"))

Plugin:setup({ library = "/data/library.db", directory = "/music" })
_G.cx = { active = { current = { cwd = "/downloads" } } }
local reads_before_outside_root = directory_reads
Plugin:entry()
assert(#commands == 3, "a directory outside the configured root must not invoke beet")
assert(directory_reads == reads_before_outside_root, "a directory outside the configured root must not be scanned")
assert(Plugin:linemode(file("/downloads/loose.mp3")) == "—")
assert(Plugin:card(file("/downloads/loose.mp3")):find("outside the configured music directory root"))

_G.ya.async = function(callback)
	return callback()
end
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
Plugin:setup({ cache = true, library = "/data/library.db", directory = "/music" })
_G.cx = { active = { current = { cwd = "/music" } } }
Plugin:entry()
assert(#commands == 4, "an explicit refresh seeds the opt-in cache with one fresh lookup")
local reads_before_cache_hit = directory_reads
local candidate_count_calls = 0
local original_candidate_count = Core.candidate_count
Core.candidate_count = function(...)
	candidate_count_calls = candidate_count_calls + 1
	return original_candidate_count(...)
end
subscriptions.cd()
Core.candidate_count = original_candidate_count
assert(#commands == 4, "an unchanged database reuses the opt-in cached lookup")
assert(candidate_count_calls == 0, "a collection-cache hit evaluates each subtree only once")
assert(directory_reads == reads_before_cache_hit + 2, "a cache hit still rescans the active directory")
library_metadata["/data/library.db"].mtime = 101
subscriptions.cd()
assert(#commands == 5, "a database modification invalidates the cached lookup")
library_metadata["/data/library.db-wal"] = { mtime = 102, len = 128 }
subscriptions.cd()
assert(#commands == 6, "creating a SQLite WAL sidecar invalidates the cached lookup")

-- Functional plugin invocations use a separate Lua context.  Configuration
-- established during setup must remain available when that context refreshes.
Plugin:setup({
	ignore_extensions = { "mp3" },
	ignore_subdirectories = { "album" },
})
Plugin:entry()
assert(Plugin:linemode(file("/music/loose.mp3")) == "—", "setup context applies exclusions")

outputs = { { status = { success = true }, stdout = "/music/album/song.flac\n" } }
package.loaded.main = nil
package.loaded.core = nil
local RefreshPlugin = require("main")
RefreshPlugin:entry()
assert(
	RefreshPlugin:linemode(file("/music/loose.mp3")) == "—",
	"a functional refresh preserves configured exclusions"
)

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
Plugin:setup({
	tag_markers = {
		{ label = "S", field = "onsync" },
		{ label = "P", field = "portable" },
		{ label = "Q", field = "onsync" },
	},
})
_G.cx = { active = { current = { cwd = "/music" } } }
local commands_before_markers = #commands
Plugin:entry()
assert(#commands == commands_before_markers + 3, "collection plus one lookup per distinct tag query")
assert(table.concat(commands[commands_before_markers + 2].args, "|") == "list|-p|onsync:true", "tag query is one command argument")
assert(table.concat(commands[commands_before_markers + 3].args, "|") == "list|-p|portable:true")
assert(Plugin:linemode(file("/music/album/song.flac")) == "● S● P○ Q●")
assert(Plugin:linemode(file("/music/loose.mp3")) == "○ S○ P● Q○")
assert(Plugin:linemode(file("/music/album")) == "● S● P○ Q●")
assert(Plugin:linemode(file("/music")) == "◐ S◐ P◐ Q◐")
local marker_card = Plugin:card(file("/music"))
assert(marker_card:find("Tag marker S: Some %(1/2 matching%)"))
assert(marker_card:find("Tag marker P: Some %(1/2 matching%)"))
assert(marker_card:find("Tag marker Q: Some %(1/2 matching%)"))

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "invalid query" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
Plugin:setup({
	tag_markers = {
		{ label = "S", field = "broken" },
		{ label = "P", field = "portable" },
	},
})
local commands_before_failed_marker = #commands
Plugin:entry()
assert(#commands == commands_before_failed_marker + 3, "a failed marker query must not prevent another query")
assert(Plugin:linemode(file("/music/album/song.flac")) == "● S! P●")
assert(Plugin:card(file("/music/album/song.flac")):find("Tag marker S: Unavailable: beet exited with code 1: invalid query"))
local saw_pending_markers, saw_isolated_failure = false, false
for _, snapshot in ipairs(render_history) do
	if snapshot.phase == "streaming" and snapshot.marker_phases[1] == "pending" and snapshot.marker_phases[2] == "pending" then
		saw_pending_markers = true
	end
	if snapshot.phase == "streaming" and snapshot.marker_phases[1] == "unavailable" and snapshot.marker_phases[2] == "pending" then
		saw_isolated_failure = true
	end
end
assert(saw_pending_markers, "tag markers render as pending before their queries finish")
assert(saw_isolated_failure, "a failed marker publishes without changing another marker")

outputs = {
	{ status = { success = false, code = 1 }, stdout = "", stderr = "database unavailable" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
Plugin:setup({ tag_markers = { { label = "S", field = "onsync" } } })
local commands_before_failed_collection = #commands
Plugin:entry()
assert(#commands == commands_before_failed_collection + 2, "a failed collection lookup must not prevent tag queries")
assert(Plugin:linemode(file("/music/album/song.flac")) == "! S●")
assert(Plugin:card(file("/music/album/song.flac")):find("Collection status: Unavailable"))
assert(Plugin:card(file("/music/album/song.flac")):find("Tag marker S: All %(1/1 matching%)"))

Plugin:setup({
	library = "/data/library.db",
	directory = "/music",
	tag_markers = {
		{ label = "S", field = "onsync" },
		{ label = "P", field = "portable" },
	},
})
_G.cx = { active = { current = { cwd = "/downloads" } } }
local commands_before_outside_root_markers = #commands
Plugin:entry()
assert(#commands == commands_before_outside_root_markers, "outside-root tag markers must not invoke beet")
assert(Plugin:linemode(file("/downloads/loose.mp3")) == "— S— P—")
assert(Plugin:card(file("/downloads/loose.mp3")):find("outside the configured music directory root"))

outputs = { { status = { success = true }, stdout = "/music/album/song.flac\n" } }
Plugin:setup({ tag_markers = "onsync:true" })
_G.cx = { active = { current = { cwd = "/music" } } }
local commands_before_invalid_markers = #commands
Plugin:entry()
assert(#commands == commands_before_invalid_markers + 1, "invalid tag-marker configuration runs collection only")
assert(Plugin:linemode(file("/music/album/song.flac")) == "● tags!")
assert(Plugin:card(file("/music/album/song.flac")):find("Tag markers: Unavailable: invalid configuration: tag_markers must be a dense array"))

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
Plugin:setup({
	cache = true,
	library = "/data/library.db",
	directory = "/music",
	tag_markers = {
		{ label = "S", field = "onsync" },
		{ label = "P", field = "portable" },
	},
})
_G.cx = { active = { current = { cwd = "/music" } } }
local commands_before_tag_cache = #commands
Plugin:entry()
assert(#commands == commands_before_tag_cache + 3, "an initial cached configuration looks up collection and each tag query")
local reads_before_tag_cache_hit = directory_reads
subscriptions.cd()
assert(#commands == commands_before_tag_cache + 3, "an unchanged library reuses every successful tag-query lookup")
assert(directory_reads == reads_before_tag_cache_hit + 2, "a tag-query cache hit still rescans the active directory")

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "temporary query failure" },
}
Plugin:setup({
	cache = true,
	library = "/data/library.db",
	directory = "/music",
	tag_markers = {
		{ label = "S", field = "onsync" },
		{ label = "P", field = "portable" },
	},
})
local commands_before_failed_cached_marker = #commands
Plugin:entry()
assert(#commands == commands_before_failed_cached_marker + 3, "an initial marker failure still runs every lookup")
outputs = { { status = { success = true }, stdout = "/music/loose.mp3\n" } }
subscriptions.cd()
assert(#commands == commands_before_failed_cached_marker + 4, "a failed tag query is retried while successful lookups use the cache")
assert(Plugin:linemode(file("/music/loose.mp3")) == "○ S○ P●")

outputs = {
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
local commands_before_forced_tag_refresh = #commands
Plugin:entry()
assert(#commands == commands_before_forced_tag_refresh + 3, "a functional refresh bypasses cached collection and tag-query lookups")

library_metadata["/data/library.db"].mtime = 102
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
local commands_before_tag_cache_invalidation = #commands
subscriptions.cd()
assert(#commands == commands_before_tag_cache_invalidation + 3, "a library change invalidates cached collection and tag-query lookups")

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
Plugin:setup({
	cache = true,
	library = "/data/library.db",
	directory = "/music",
	tag_markers = { { label = "Synced", field = "onsync" } },
})
local commands_before_tag_cache_reconfiguration = #commands
subscriptions.cd()
assert(#commands == commands_before_tag_cache_reconfiguration + 2, "a configuration change clears cached collection and tag-query lookups")

outputs = {
	{ status = { success = false, code = 1 }, stdout = "", stderr = "temporary collection failure" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "temporary marker failure" },
}
local commands_before_failed_forced_refresh = #commands
Plugin:entry()
assert(#commands == commands_before_failed_forced_refresh + 2, "a forced refresh runs each configured lookup even after caching")
outputs = {
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
local commands_before_retry_after_forced_failure = #commands
subscriptions.cd()
assert(#commands == commands_before_retry_after_forced_failure + 2, "a failed forced refresh evicts prior collection and tag-query results")

listing["/batch"] = {
	{ url = "/batch/one", cha = { is_dir = true } },
	{ url = "/batch/two", cha = { is_dir = true } },
	{ url = "/batch/three", cha = { is_dir = true } },
	{ url = "/batch/four", cha = { is_dir = true } },
}
for _, name in ipairs({ "one", "two", "three", "four" }) do
	listing["/batch/" .. name] = { { url = "/batch/" .. name .. "/song.flac", cha = {} } }
end
outputs = {
	{ status = { success = true }, stdout = table.concat({
		"/batch/one/song.flac",
		"/batch/two/song.flac",
		"/batch/three/song.flac",
		"/batch/four/song.flac",
	}, "\n") .. "\n" },
}
Plugin:setup({})
_G.cx = { active = { current = { cwd = "/batch" } } }
local renders_before_batched_subtrees = renders
Plugin:entry()
assert(
	renders == renders_before_batched_subtrees + 4,
	"a fast run batches all direct-subdirectory statuses into one redraw"
)
assert(Plugin:linemode(file("/batch/four/song.flac")) == "●", "the final snapshot retains every batched status")

outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
Plugin:setup({
	tag_markers = {
		{ label = "S", field = "onsync" },
		{ label = "P", field = "portable" },
	},
})
_G.cx = { active = { current = { cwd = "/music" } } }
local renders_before_batched_tags = renders
Plugin:entry()
assert(
	renders == renders_before_batched_tags + 6,
	"fast tag-marker results publish together in one redraw"
)
assert(Plugin:linemode(file("/music/album/song.flac")) == "● S● P○", "the final snapshot retains every batched tag marker")

_G.cx.active.selected = {
	{ url = "/music/album", cha = { is_dir = true } },
	{ url = "/music/loose.mp3", cha = {} },
}
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n/music/loose.mp3\n" },
}
Plugin:setup({ tag_markers = { { label = "S", field = "onsync" } } })
local commands_before_setting_tag = #commands
Plugin.entry({ args = { toggle = "S" } })
assert(#commands == commands_before_setting_tag + 3, "a toggle refreshes only its marker after mutation")
assert(
	table.concat(commands[commands_before_setting_tag + 2].args, "|")
		== "modify|-y|path:/music/album/song.flac|,|path:/music/loose.mp3|onsync=true",
	"a partly tagged directory sets the field on every candidate"
)
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n/music/loose.mp3\n" },
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "" },
}
local commands_before_removing_tag = #commands
Plugin.entry({ args = { toggle = "S" } })
assert(#commands == commands_before_removing_tag + 3, "an all-tagged target refreshes only its marker after mutation")
assert(
	table.concat(commands[commands_before_removing_tag + 2].args, "|")
		== "modify|-y|path:/music/album/song.flac|,|path:/music/loose.mp3|onsync!",
	"an all-tagged directory removes the field from every candidate"
)

_G.cx.active.selected = {}
_G.cx.active.current.hovered = { url = "/music/loose.mp3", cha = {} }
outputs = {
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
local commands_before_hovered_tag = #commands
Plugin.entry({ args = { toggle = "S" } })
assert(#commands == commands_before_hovered_tag + 3, "a hovered fallback refreshes only its marker after mutation")
assert(
	table.concat(commands[commands_before_hovered_tag + 2].args, "|")
		== "modify|-y|path:/music/loose.mp3|onsync=true",
	"without selection, a toggle mutates only the hovered candidate"
)
local saw_only_hovered_item_pending = false
for _, snapshot in ipairs(render_history) do
	local marker = snapshot.marker_statuses[1]
	if snapshot.phase == "ready" and snapshot.marker_phases[1] == "ready"
		and marker and marker.album == "none" and marker.loose == "pending" then
		saw_only_hovered_item_pending = true
	end
end
assert(saw_only_hovered_item_pending, "a toggle leaves non-target marker statuses unchanged")

Plugin:setup({
	cache = true,
	library = "/data/library.db",
	directory = "/music",
	tag_markers = { { label = "S", field = "onsync" } },
})
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
}
local commands_before_cached_toggle = #commands
Plugin.entry()
assert(#commands == commands_before_cached_toggle + 2, "a cached snapshot seeds collection and marker lookups")
on_command_output = function(command)
	if table.concat(command.args, "|"):find("|modify|") then
		library_metadata["/data/library.db"].mtime = library_metadata["/data/library.db"].mtime + 1
		on_command_output = nil
	end
end
outputs = {
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
-- Functional invocations load a separate Lua module, so they must update the
-- cache state later used by the setup-context directory-change callback.
package.loaded.main = nil
local TogglePlugin = require("main")
TogglePlugin.entry({ args = { toggle = "S" } })
local commands_before_cached_directory_change = #commands
subscriptions.cd()
assert(#commands == commands_before_cached_directory_change, "a toggle preserves the cached collection lookup")
library_metadata["/data/library.db"].mtime = library_metadata["/data/library.db"].mtime + 1
outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = true }, stdout = "/music/loose.mp3\n" },
}
subscriptions.cd()
assert(
	#commands == commands_before_cached_directory_change,
	"a delayed post-toggle fingerprint change preserves the cached collection lookup"
)

local saw_toggle_command, saw_toggle_success = false, false
for _, message in ipairs(debug_messages) do
	saw_toggle_command = saw_toggle_command or message:find("%[DEBUG%-toggle%-7d21%] mutation batch=1%-2 start: beet modify") ~= nil
	saw_toggle_success = saw_toggle_success or message:find("%[DEBUG%-toggle%-7d21%] mutation succeeded") ~= nil
end
assert(saw_toggle_command, "toggle diagnostics include the precise beets mutation command")
assert(saw_toggle_success, "toggle diagnostics record a successful refresh")

print("adapter tests passed")
