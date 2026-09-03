.PHONY: install build test fmt fmt-check snapshot coverage slither ci demo clean

install:
	forge install Uniswap/v4-periphery
	forge install OpenZeppelin/uniswap-hooks
	pip install slither-analyzer

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

snapshot:
	forge snapshot

# The pattern is ANCHORED. An unanchored "lib" also matches src/libraries/, which silently
# excluded every library in this repo from the coverage report — the numbers looked fine
# because the only file left was the hook. Do not un-anchor it.
# Coverage disables optimization. Exclude only this gas-ceiling assertion, whose gas
# measurement is meaningful in the optimized test run, not in a coverage build.
# `make test` still runs it unchanged, along with every other gas and adversarial test.
# Foundry matches the full function signature, including (). Make needs $$ for a literal $.
coverage:
	forge coverage --no-match-coverage "^(lib|test|script)/" --no-match-test '^test_adversarial_victimCallbackStaysInsideTheCeiling[(][)]$$' --report summary

slither:
	slither . --exclude-dependencies --filter-paths "lib/"

# Run the local format, static-analysis, optimized-test and coverage checks.
# GitHub CI additionally uses the ci profile and checks the committed gas snapshot.
#
# ORDER MATTERS. `slither .` runs `forge clean` first, then rebuilds with
# `--skip ./test/** ./script/**` — so it wipes out/ and leaves src/ artifacts only.
# Anything that needs test or script artifacts must run AFTER it, or it recompiles
# from scratch. Hence slither first, then build/test/coverage on a fresh tree.
ci: fmt-check slither build test coverage
	@echo "All CI checks passed locally."

demo:
	forge test --match-path test/Demo.t.sol -vv

clean:
	forge clean
