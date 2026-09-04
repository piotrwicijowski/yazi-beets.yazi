local root = (... and (...):match("^(.*)/[^/]+$")) or "."
package.path = root .. "/yazi-beets.yazi/?.lua;" .. package.path

local plugin_state = {}
local commands = {}
local renders = 0
local subscriptions = {}
local outputs = {
	{ status = { success = true }, stdout = "/music/album/song.flac\n" },
	{ status = { success = false, code = 1 }, stdout = "", stderr = "database unavailable" },
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
_G.cx = { active = { current = { cwd = "/music" } } }
_G.ps = { sub = function(event, callback) subscriptions[event] = callback end }
_G.Url = function(path) return path end
_G.fs = {
	read_dir = function(path)
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

local Plugin = require("main")

local function file(path, properties)
	return { url = path, cha = properties or {} }
end

Plugin:setup({})
assert(type(subscriptions.cd) == "function", "setup must subscribe to directory changes")
assert(#commands == 1, "setup starts one lookup for the active directory")
assert(commands[1].program == "beet")
assert(table.concat(commands[1].args, " ") == "list -p path:/music")
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

Plugin:setup({ library = "/data/library.db" })
Plugin:entry()
assert(#commands == 2, "invalid configuration never invokes beet")
assert(Plugin:linemode(file("/music/loose.mp3")) == "!")
assert(Plugin:card(file("/music/loose.mp3")):find("Correct configuration"))

print("adapter tests passed")
