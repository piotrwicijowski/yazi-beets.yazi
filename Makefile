.PHONY: test check

test:
	lua tests/core_spec.lua
	lua tests/adapter_spec.lua

check: test
	luac -p yazi-beets.yazi/core.lua yazi-beets.yazi/main.lua tests/core_spec.lua tests/adapter_spec.lua
