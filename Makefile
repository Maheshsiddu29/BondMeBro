.PHONY: install build test fmt fmt-check snapshot coverage slither ci clean

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
coverage:
	forge coverage --no-match-coverage "^(lib|test|script)/" --report summary

slither:
	slither . --exclude-dependencies --filter-paths "lib/"

# Run exactly what CI runs, before you push.
#
# ORDER MATTERS. `slither .` runs `forge clean` first, then rebuilds with
# `--skip ./test/** ./script/**` — so it wipes out/ and leaves src/ artifacts only.
# Anything that needs test or script artifacts must run AFTER it, or it recompiles
# from scratch. Hence slither first, then build/test/coverage on a fresh tree.
ci: fmt-check slither build test coverage
	@echo "All CI checks passed locally."

clean:
	forge clean
