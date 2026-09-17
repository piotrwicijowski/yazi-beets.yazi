.PHONY: test check

test:
	lua tests/core_spec.lua
	lua tests/adapter_spec.lua

check: test
	luac -p core.lua main.lua tests/core_spec.lua tests/adapter_spec.lua
