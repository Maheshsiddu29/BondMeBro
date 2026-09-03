.PHONY: install build test fmt fmt-check snapshot snapshot-check coverage slither ci demo clean

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

# WHAT THE SNAPSHOT TRACKS, AND WHAT IT DELIBERATELY DOES NOT.
#
# Two classes of test have gas figures that move without any executable change, so tracking them
# turns the snapshot into a source of false alarms rather than a regression signal:
#
#   testFuzz_*   Foundry reports mean and median across the fuzz corpus. Those drift run to run --
#                measured up to 2.06% on an unchanged tree, which is past any tolerance tight
#                enough to still catch a real regression. `--fuzz-seed` does NOT fix it: with a
#                pinned seed the medians match and the means still move.
#
#   test_constructor_rejectsZeroOwner
#                calls HookMiner.find INSIDE the measured body. Salt search is brute force over
#                CREATE2 candidates, and the candidates depend on the creation-code hash -- which
#                every comment and NatSpec edit changes, because comments change compiler metadata.
#                Its entry was 63,315,366 gas of address mining. That is not production behaviour.
#                The test itself is a CORRECTNESS test and is untouched; only its uselessness as a
#                gas metric is removed. `make test` still runs it.
#
# What remains is 431 deterministic entries -- bonded and unbonded swaps, the beforeSwap and
# afterSwap worst cases, settlement in every shape, checkpoint scanning, settleMany batches --
# verified byte-identical across three independent generations.
SNAPSHOT_EXCLUDE := ^(testFuzz_.*|test_constructor_rejectsZeroOwner\(\))$$

# test/audit/ holds UNTRACKED, throwaway tests written during security review. They exist on a
# reviewer's machine and not in CI, so letting them into the snapshot would make the committed file
# depend on who generated it -- `snapshot-check` would then fail on a clean checkout for reasons
# that have nothing to do with gas.
SNAPSHOT_EXCLUDE_PATH := test/audit/*

snapshot:
	forge snapshot --no-match-test '$(SNAPSHOT_EXCLUDE)' --no-match-path '$(SNAPSHOT_EXCLUDE_PATH)'

snapshot-check:
	forge snapshot --check --no-match-test '$(SNAPSHOT_EXCLUDE)' --no-match-path '$(SNAPSHOT_EXCLUDE_PATH)'

# The pattern is ANCHORED. An unanchored "lib" also matches src/libraries/, which silently
# excluded every library in this repo from the coverage report — the numbers looked fine
# because the only file left was the hook. Do not un-anchor it.
#
# NO TEST IS EXCLUDED ANY MORE. `test_adversarial_victimCallbackStaysInsideTheCeiling` used to be
# skipped here because it wrapped `gasleft()` around a whole swap and compared the total against
# the `beforeSwap` CALLBACK ceiling — a total that inflates under coverage's unoptimized build and
# failed for reasons that had nothing to do with the hook. The test now measures the callback frame
# itself, which is small enough to stay inside 150,000 even unoptimized, so it runs here too.
# Coverage now executes the identical test set as `make test`.
coverage:
	forge coverage --no-match-coverage "^(lib|test|script)/" --report summary

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
