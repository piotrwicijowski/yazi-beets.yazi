local root = (... and (...):match("^(.*)/[^/]+$")) or "."
package.path = root .. "/yazi-beets.yazi/?.lua;" .. package.path

local Core = require("core")

local total = 0
local function test(name, callback)
	total = total + 1
	local ok, err = pcall(callback)
	if not ok then
		io.stderr:write("not ok - " .. name .. "\n" .. tostring(err) .. "\n")
		os.exit(1)
	end
	print("ok - " .. name)
end

local function same(actual, expected)
	assert(#actual == #expected, "different lengths")
	for index, value in ipairs(expected) do
		assert(actual[index] == value, string.format("entry %d: expected %q, got %q", index, value, tostring(actual[index])))
	end
end

test("builds one full-library lookup without library flags", function()
	local command = assert(Core.lookup_command({}))
	assert(command.program == "beet")
	same(command.args, { "list", "-p" })
end)

test("passes a complete library override to the full-library lookup", function()
	local command = assert(Core.lookup_command({ library = "/data/library.db", directory = "/music" }))
	same(command.args, {
		"-l", "/data/library.db", "-d", "/music", "list", "-p",
	})
end)

test("rejects partial and empty library overrides", function()
	for _, options in ipairs({
		{ library = "/data/library.db" },
		{ directory = "/music" },
		{ library = "", directory = "/music" },
		{ library = "/data/library.db", directory = "" },
	}) do
		local command, err = Core.lookup_command(options)
		assert(command == nil)
		assert(err:find("both non%-empty library and directory"))
	end
end)

test("validates and normalizes flat exclusion lists", function()
	local exclusions = assert(Core.validate_exclusions({
		ignore_extensions = { "jpg", "GZ", "jpg" },
		ignore_subdirectories = { "Artwork", "Artwork" },
	}))
	assert(exclusions.ignore_extensions.jpg)
	assert(exclusions.ignore_extensions.gz)
	assert(exclusions.ignore_subdirectories.Artwork)

	for _, case in ipairs({
		{ options = { ignore_extensions = "jpg" }, expected = "ignore_extensions" },
		{ options = { ignore_extensions = { [1] = "jpg", [3] = "png" } }, expected = "ignore_extensions" },
		{ options = { ignore_extensions = { " jpg" } }, expected = "ignore_extensions%[1%]" },
		{ options = { ignore_extensions = { ".jpg" } }, expected = "ignore_extensions%[1%]" },
		{ options = { ignore_subdirectories = { "" } }, expected = "ignore_subdirectories%[1%]" },
		{ options = { ignore_subdirectories = { 3 } }, expected = "ignore_subdirectories%[1%]" },
	}) do
		local result, err = Core.validate_exclusions(case.options)
		assert(result == nil)
		assert(err:find(case.expected), err)
	end
end)

local function directory(path, children)
	return { path = path, kind = "directory", children = children }
end

local function file(path)
	return { path = path, kind = "file" }
end

test("classifies files and recursive directories while excluding symlinks", function()
	local tree = directory("/music", {
		file("/music/collected.flac"),
		directory("/music/album", {
			file("/music/album/uncollected.ogg"),
			{ path = "/music/album/linked.flac", kind = "symlink" },
		}),
		directory("/music/empty", {}),
	})
	local evaluation = Core.evaluate(tree, {
		["/music/collected.flac"] = true,
	})

	assert(evaluation.statuses["/music/collected.flac"].status == "collected")
	assert(evaluation.statuses["/music/album/uncollected.ogg"].status == "uncollected")
	assert(evaluation.statuses["/music/album"].status == "uncollected")
	assert(evaluation.statuses["/music/empty"].status == "not applicable")
	assert(evaluation.statuses["/music"].status == "mixed")
	assert(evaluation.statuses["/music"].candidates == 2)
	assert(evaluation.statuses["/music"].collected == 1)
	assert(evaluation.statuses["/music/album/linked.flac"] == nil)
end)

test("excludes configured extensions and directory subtrees", function()
	local tree = directory("/music", {
		file("/music/cover.JPG"),
		directory("/music/album", {
			file("/music/album/song.flac"),
			directory("/music/album/Artwork", {
				file("/music/album/Artwork/cover.png"),
			}),
		}),
		directory("/music/empty", {}),
	})
	local exclusions = assert(Core.validate_exclusions({
		ignore_extensions = { "jpg" },
		ignore_subdirectories = { "Artwork" },
	}))
	local evaluation = Core.evaluate(tree, { ["/music/album/song.flac"] = true }, exclusions)

	assert(Core.candidate_count(tree, exclusions) == 1)
	assert(evaluation.statuses["/music/cover.JPG"].status == "not applicable")
	assert(evaluation.statuses["/music/cover.JPG"].reason == "excluded by configuration")
	assert(evaluation.statuses["/music/album/Artwork"].status == "not applicable")
	assert(evaluation.statuses["/music/album/Artwork/cover.png"].status == "not applicable")
	assert(evaluation.statuses["/music/empty"].reason == "no candidate descendants")
	assert(evaluation.statuses["/music"].status == "collected")
	assert(evaluation.statuses["/music"].candidates == 1)
	assert(Core.card("/music/cover.JPG", evaluation.statuses["/music/cover.JPG"], "default"):find("excluded from collection%-membership evaluation"))

	local ignored_root = directory("/music/cache", { file("/music/cache/song.flac") })
	local root_exclusions = assert(Core.validate_exclusions({ ignore_subdirectories = { "cache" } }))
	local root_evaluation = Core.evaluate(ignored_root, {}, root_exclusions)
	assert(Core.candidate_count(ignored_root, root_exclusions) == 0)
	assert(root_evaluation.statuses["/music/cache"].reason == "excluded by configuration")
end)

test("scans all descendants and turns a scan failure into an error", function()
	local listing = {
		["/music"] = { directory("/music/album"), file("/music/loose.mp3") },
		["/music/album"] = { file("/music/album/song.flac") },
	}
	local tree = assert(Core.scan("/music", function(path)
		return listing[path]
	end))
	local evaluation = Core.evaluate(tree, { ["/music/album/song.flac"] = true })
	assert(evaluation.statuses["/music"].status == "mixed")

	local missing_tree, err = Core.scan("/music", function()
		return nil, "permission denied"
	end)
	assert(missing_tree == nil)
	assert(err:find("permission denied"))
end)

test("maps every collection status to its agreed marker", function()
	local markers = {
		collected = "●",
		mixed = "◐",
		uncollected = "○",
		unavailable = "!",
		["pending collection status"] = "…",
		["not applicable"] = "—",
	}
	for status, marker in pairs(markers) do
		assert(Core.marker(status) == marker)
	end

	local card = Core.card("/music", { status = "collected" }, "default beets configuration")
	assert(card:find("Collected"))
	assert(card:find("Path: /music"))
	assert(card:find("Library: default beets configuration"))
end)

test("maps pending and unavailable results to truthful markers and cards", function()

	local pending = Core.status_for({ phase = "pending" }, "/music/song.flac")
	assert(pending.status == "pending collection status")
	local unavailable = Core.status_for({ phase = "unavailable", reason = "beet exited with code 1" }, "/music/song.flac")
	assert(unavailable.status == "unavailable")
	assert(unavailable.reason == "beet exited with code 1")

	local card = Core.card("/music", {
		status = "unavailable",
		reason = "invalid configuration",
		candidates = 3,
		collected = 1,
	}, "default beets configuration")
	assert(card:find("Unavailable"))
	assert(card:find("Path: /music"))
	assert(card:find("Library: default beets configuration"))
	assert(card:find("Candidates: 3 %(1 collected%)"))
	assert(card:find("Correct configuration or run the refresh command"))
end)

test("aggregates all-collected and all-uncollected directories", function()
	local tree = directory("/music", { file("/music/a.flac"), file("/music/b.ogg") })
	assert(Core.evaluate(tree, {
		["/music/a.flac"] = true,
		["/music/b.ogg"] = true,
	}).statuses["/music"].status == "collected")
	assert(Core.evaluate(tree, {}).statuses["/music"].status == "uncollected")
end)

test("parses beets output without altering emitted paths", function()
	local paths = Core.collected_paths("/music/a.flac\n/music/b.ogg\n\n")
	assert(paths["/music/a.flac"])
	assert(paths["/music/b.ogg"])
	assert(paths["/music/a.flac/"] == nil)
end)

print(string.format("%d tests passed", total))
