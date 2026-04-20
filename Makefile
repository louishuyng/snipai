NVIM    ?= nvim
DEPS    := .deps
PLENARY := $(DEPS)/plenary.nvim

.PHONY: help deps test test-unit test-integration test-file smoke format format-check lint clean

help:
	@echo "snipai make targets:"
	@echo "  make deps             clone test dependencies into $(DEPS)/"
	@echo "  make test             run full test suite (unit + integration)"
	@echo "  make test-unit        run unit tests only (fastest)"
	@echo "  make test-integration run integration / smoke tests (real PTY, fs_poll)"
	@echo "  make test-file F=tests/unit/foo_spec.lua   run one spec"
	@echo "  make smoke            release-time: run real claude CLI through the runner"
	@echo "  make format           format all lua with stylua"
	@echo "  make format-check     check formatting without modifying"
	@echo "  make lint             stylua --check + luacheck (if installed)"
	@echo "  make clean            remove $(DEPS)/ and generated docs"

deps: $(PLENARY)

$(PLENARY):
	@mkdir -p $(DEPS)
	@echo "==> cloning plenary.nvim"
	@git clone --depth=1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

# --clean is critical: without it, any snipai copy in the user's
# ~/.local/share/nvim/site/pack/ shadows the repo under test and the
# whole suite silently exercises the installed version instead of the
# code you just changed. --noplugin alone is not enough.
test: deps
	@$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }" \
		-c "qa!"

test-unit: deps
	@$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/unit { minimal_init = 'tests/minimal_init.lua', sequential = true }" \
		-c "qa!"

test-integration: deps
	@$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/integration { minimal_init = 'tests/minimal_init.lua', sequential = true }" \
		-c "qa!"

test-file: deps
	@[ -n "$(F)" ] || (echo "usage: make test-file F=tests/unit/foo_spec.lua" && exit 1)
	@$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "lua require('plenary.busted').run('$(F)', { minimal_init = 'tests/minimal_init.lua', sequential = true })" \
		-c "qa!"

smoke:
	@command -v claude >/dev/null 2>&1 || { echo "smoke: \`claude\` CLI not on PATH" >&2; exit 2; }
	@$(NVIM) --headless --noplugin -u tests/minimal_init.lua -l scripts/smoke.lua

format:
	@stylua lua/ tests/

format-check:
	@stylua --check lua/ tests/

lint:
	@stylua --check lua/ tests/
	@command -v luacheck >/dev/null && luacheck lua/ tests/ --globals vim --no-unused-args || echo "(luacheck not installed, skipping)"

clean:
	@rm -rf $(DEPS) doc/tags
