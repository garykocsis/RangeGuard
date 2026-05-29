.PHONY: help build test test-v fmt fmt-check clean snapshot coverage gas deploy-anvil deploy-sepolia deploy-anvil-dry deploy-sepolia-dry

# Load local env vars when present (PRIVATE_KEY, SEPOLIA_RPC_URL, etc.)
-include .env
export

SCRIPT := script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook
ANVIL_RPC_URL ?= http://127.0.0.1:8545

# Default target
help:
	@echo "Available targets:"
	@echo "  make build       - Compile contracts"
	@echo "  make test        - Run test suite"
	@echo "  make test-v      - Run tests with verbose logs"
	@echo "  make fmt         - Format Solidity files"
	@echo "  make fmt-check   - Check formatting without changes"
	@echo "  make clean       - Remove build artifacts"
	@echo "  make snapshot    - Create gas snapshot"
	@echo "  make coverage    - Generate coverage report"
	@echo "  make gas         - Run tests with gas report"
	@echo "  make deploy-anvil      - Broadcast deploy script to local anvil"
	@echo "  make deploy-anvil-dry  - Simulate deploy script on local anvil"
	@echo "  make deploy-sepolia    - Broadcast deploy script to Sepolia"
	@echo "  make deploy-sepolia-dry  - Simulate deploy script on Sepolia"

build:
	forge build

test:
	forge test

test-v:
	forge test -vvv

install:
	forge install https://github.com/Uniswap/v4-hooks-public

fmt:
	forge fmt

fmt-check:
	forge fmt --check

clean:
	forge clean

snapshot:
	forge snapshot

coverage:
	forge coverage

gas:
	forge test --gas-report

deploy-anvil:
	@forge script $(SCRIPT) --rpc-url $(ANVIL_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast -vvvv

deploy-anvil-dry:
	@forge script $(SCRIPT) --rpc-url $(ANVIL_RPC_URL) --private-key $(PRIVATE_KEY) -vvvv

deploy-sepolia:
	@forge script $(SCRIPT) --rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast -vvvv

deploy-sepolia-dry:
	@forge script $(SCRIPT) --rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY) -vvvv
