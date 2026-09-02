.PHONY: install build test fmt fmt-check snapshot coverage slither ci clean frontend-install frontend-build frontend-dev

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

coverage:
	forge coverage --no-match-coverage "lib|test|script" --report summary

slither:
	slither . --exclude-dependencies --filter-paths "lib/" --fail-medium

# Run exactly what CI runs, before you push.
ci: fmt-check build test coverage slither
	@echo "All CI checks passed locally."

clean:
	forge clean

frontend-install:
	cd frontend && npm install

frontend-build:
	cd frontend && npm run build

frontend-dev:
	cd frontend && npm run dev
