local root = (... and (...):match("^(.*)/[^/]+$")) or "."
package.path = root .. "/yazi-beets.yazi/?.lua;" .. package.path

local plugin_state = {}
local commands = {}
local renders = 0
local directory_reads = 0
local subscriptions = {}
local outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "database unavailable" },
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
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
}
_G.ui = { render = function() renders = renders + 1 end }
_G.cx = nil
_G.ps = { sub = function(event, callback) subscriptions[event] = callback end }
_G.Url = function(path) return path end
_G.fs = {
	read_dir = function(path)
		directory_reads = directory_reads + 1
		return listing[tostring(path)]
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
		return table.remove(outputs, 1)
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

print("adapter tests passed")
