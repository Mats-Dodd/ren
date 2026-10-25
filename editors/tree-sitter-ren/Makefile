# The grammar's checks. `make check` before committing a change to the
# grammar, or to the compiler's parser.

TS := node_modules/.bin/tree-sitter

.PHONY: check generate test differential

check: generate test differential

node_modules: package.json
	npm install --silent
	touch node_modules

generate: node_modules
	$(TS) generate

# the corpus (test/corpus) and the highlight assertions (test/highlight)
test: generate
	$(TS) test

# every program the compiler parses parses here too
differential: generate
	cd ../.. && dune build
	python3 differential.py
