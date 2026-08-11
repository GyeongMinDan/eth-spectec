NAME = spectec-core

SWITCH = eth-spectec

OPAM_EXEC = opam exec --switch=$(SWITCH) --
DUNE = cd spectec && $(OPAM_EXEC) dune

# Compile & Format

.PHONY: exe fmt promote clean

EXESPEC = spectec/_build/default/bin/main.exe

exe:
	rm -f ./$(NAME)
	$(DUNE) build bin/main.exe --profile=release
	@echo
	ln -f $(EXESPEC) ./$(NAME)

fmt:
	$(DUNE) fmt

promote:
	$(DUNE) promote

clean:
	rm -f ./$(NAME)
	$(DUNE) clean

# Tests
#
# Individual tests:
#   make test-ssz        - SSZ Merkle and hash-tree-root unit tests
#   make test-elab       - Elaboration test
#   make test-struct     - Structuring test
#   make test-il-pos     - IL interpreter positive tests (slow)
#   make test-il-neg     - IL interpreter negative tests
#   make test-sl-pos     - SL interpreter positive tests (slow)
#   make test-sl-neg     - SL interpreter negative tests
#
# Grouped tests:
#   make test-quick      - Fast tests only (SSZ + elab + struct)
#   make test-il         - All IL tests (pos + neg)
#   make test-sl         - All SL tests (pos + neg)
#   make test            - All tests

.PHONY: test test-quick test-ssz test-elab test-struct
.PHONY: test-il test-il-pos test-il-neg
.PHONY: test-sl test-sl-pos test-sl-neg
.PHONY: promote

test-elab:
	@echo "#### Running elaboration test"
	@$(DUNE) build @test/elab/runtest --profile=release && echo OK

test-struct:
	@echo "#### Running structuring test"
	@$(DUNE) build @test/struct/runtest --profile=release && echo OK

test-ssz:
	@echo "#### Running SSZ Merkle and hash-tree-root tests"
	@$(DUNE) build @test/ssz/runtest --profile=release && echo OK

# $(1): il / sl
# $(2): pos / neg
define run_interp_test
	@echo "#### Running $(1) interpreter $(2) tests"
	@$(DUNE) build @test/interp/$(1)-$(2) --profile=release
	@cat spectec/_build/default/test/interp/$(1)-$(2).err >&2
	@echo OK
endef

test-il-pos:
	$(call run_interp_test,il,pos)

test-il-neg:
	$(call run_interp_test,il,neg)

test-sl-pos:
	$(call run_interp_test,sl,pos)

test-sl-neg:
	$(call run_interp_test,sl,neg)

test-quick: test-ssz test-elab test-struct
	@echo "#### Quick tests passed"

test-il: test-il-pos test-il-neg
	@echo "#### IL tests passed"

test-sl: test-sl-pos test-sl-neg
	@echo "#### SL tests passed"

test: test-quick test-il test-sl
	@echo "#### All tests passed"
