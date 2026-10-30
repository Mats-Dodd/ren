# The grammar's checks. `make check` before committing a change to the
# grammar, or to the compiler's parser.

TS := $(if $(TREE_SITTER),$(TREE_SITTER),node_modules/.bin/tree-sitter)
ifeq ($(TREE_SITTER),)
TS_DEPS := node_modules/.ren-install
endif

.PHONY: check generate test differential

check: generate test differential

node_modules/.ren-install: package.json package-lock.json
	npm ci --no-audit --no-fund
	touch $@

generate: $(TS_DEPS)
	$(TS) generate --abi 14

# the corpus (test/corpus) and the highlight assertions (test/highlight)
test: generate
	$(TS) test

# every program the compiler parses parses here too
differential: generate
	cd ../.. && dune build --root .
	python3 differential.py
