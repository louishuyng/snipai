NVIM    ?= nvim
DEPS    := .deps
PLENARY := $(DEPS)/plenary.nvim

.PHONY: help deps test test-unit test-file format format-check lint clean

help:
	@echo "snipai make targets:"
	@echo "  make deps          clone test dependencies into $(DEPS)/"
	@echo "  make test          run full test suite"
	@echo "  make test-unit     run unit tests only (fastest)"
	@echo "  make test-file F=tests/unit/foo_spec.lua   run one spec"
	@echo "  make format        format all lua with stylua"
	@echo "  make format-check  check formatting without modifying"
	@echo "  make lint          stylua --check + luacheck (if installed)"
	@echo "  make clean         remove $(DEPS)/ and generated docs"

deps: $(PLENARY)

$(PLENARY):
	@mkdir -p $(DEPS)
	@echo "==> cloning plenary.nvim"
	@git clone --depth=1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

test: deps
	@$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }" \
		-c "qa!"

test-unit: deps
	@$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/unit { minimal_init = 'tests/minimal_init.lua', sequential = true }" \
		-c "qa!"

test-file: deps
	@[ -n "$(F)" ] || (echo "usage: make test-file F=tests/unit/foo_spec.lua" && exit 1)
	@$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(F)" \
		-c "qa!"

format:
	@stylua lua/ tests/

format-check:
	@stylua --check lua/ tests/

lint:
	@stylua --check lua/ tests/
	@command -v luacheck >/dev/null && luacheck lua/ tests/ --globals vim --no-unused-args || echo "(luacheck not installed, skipping)"

clean:
	@rm -rf $(DEPS) doc/tags
