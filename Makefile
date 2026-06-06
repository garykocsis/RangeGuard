.PHONY: help build test test-v fmt fmt-check clean snapshot coverage gas \
        deploy-anvil deploy-anvil-dry \
        deploy-hook deploy-hook-dry stage-init-seed mint-usdc \
        faucet deploy-reactive deploy-reactive-dry \
        reactive-balance reactive-paused reactive-topup reactive-pause reactive-resume \
        deps

# Load local env vars when present (PRIVATE_KEY, SEPOLIA_RPC_URL, etc.)
-include .env
export

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
HOOK_SCRIPT     := script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook
STAGE_SCRIPT    := script/StageInitSeedPool.s.sol:StageInitSeedPool
REACTIVE_SCRIPT := script/DeployRangeGuardReactive.s.sol:DeployRangeGuardReactive

ANVIL_RPC_URL    ?= http://127.0.0.1:8545
SEPOLIA_CHAIN_ID := 11155111

# Reactive Lasna (Omni fork). NOTE: lasna-OMNI-rpc, distinct from the pre-Omni lasna-rpc.
LASNA_RPC_URL    ?= https://lasna-omni-rpc.rnk.dev/

# Live deployment addresses (Session 12). Override on the command line if redeploying,
# e.g. `make deploy-reactive HOOK_ADDRESS=0x...`.
DEPLOYER          ?= 0x193D1F3E085efc80e1027891FaA770E81ECC4A1d
HOOK_ADDRESS      ?= 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0
REACTIVE_ADDRESS  ?= 0xC0e6b70c8FF75962541183fdc247E7B07AD6B70b
MOCK_USDC_ADDRESS ?= 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA
FAUCET            ?= 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
FAUCET_VALUE      ?= 0.1ether
RGAS_FUND_AMOUNT  ?= 0.05ether
SEED_USDC_AMOUNT  ?= 10000000000   # 10,000 USDC (6 decimals)

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
help:
	@echo "Dev:"
	@echo "  make build               - Compile contracts"
	@echo "  make test                - Run test suite (278 expected)"
	@echo "  make test-v              - Run tests with verbose logs"
	@echo "  make fmt / fmt-check     - Format / check Solidity formatting"
	@echo "  make snapshot / gas      - Gas snapshot / gas report"
	@echo "  make coverage            - Coverage report"
	@echo "  make clean               - Remove build artifacts"
	@echo "  make deps                - (info) dependencies are VENDORED; no install needed"
	@echo ""
	@echo "Sepolia host-chain deploy (needs PRIVATE_KEY + SEPOLIA_RPC_URL in .env):"
	@echo "  make deploy-hook-dry     - Simulate the hook deploy (prints mined address)"
	@echo "  make deploy-hook         - Broadcast the hook deploy to Sepolia (--verify)"
	@echo "  make mint-usdc           - Mint 10,000 MockUSDC to DEPLOYER (buffer seed)"
	@echo "  make stage-init-seed     - Stage config + init pool + seed buffer (HOOK_ADDRESS=...)"
	@echo ""
	@echo "Reactive Lasna deploy (ReactVM):"
	@echo "  make faucet              - Get lREACT on Lasna (sends $(FAUCET_VALUE) Sepolia ETH)"
	@echo "  make deploy-reactive-dry - Simulate the reactive deploy on Lasna (HOOK_ADDRESS=...)"
	@echo "  make deploy-reactive     - Broadcast the reactive deploy to Lasna"
	@echo ""
	@echo "Reactive ops (Lasna):"
	@echo "  make reactive-balance    - Show the reactive contract's rGas (lREACT) balance"
	@echo "  make reactive-paused     - Show pause state (ACTIVE / PAUSED)"
	@echo "  make reactive-topup      - Send $(RGAS_FUND_AMOUNT) lREACT to the reactive contract"
	@echo "  make reactive-pause      - Pause the Cron heartbeat (owner only)"
	@echo "  make reactive-resume     - Resume the Cron heartbeat (owner only)"
	@echo ""
	@echo "Local:"
	@echo "  make deploy-anvil-dry / deploy-anvil - Simulate / broadcast the hook deploy on anvil"

# ----------------------------------------------------------------------------
# Dev
# ----------------------------------------------------------------------------
build:
	forge build

test:
	forge test

test-v:
	forge test -vvv

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

deps:
	@echo "All dependencies are VENDORED (committed under lib/, not git submodules):"
	@echo "  forge-std, v4-hooks-public, reactive-lib-omni (see lib/reactive-lib-omni/VENDORED.md)."
	@echo "A fresh 'git clone' + 'forge build' works with no submodule init."

# ----------------------------------------------------------------------------
# Local (anvil)
# ----------------------------------------------------------------------------
deploy-anvil:
	@forge script $(HOOK_SCRIPT) --rpc-url $(ANVIL_RPC_URL) --private-key $(PRIVATE_KEY) --broadcast -vvvv

deploy-anvil-dry:
	@forge script $(HOOK_SCRIPT) --rpc-url $(ANVIL_RPC_URL) --private-key $(PRIVATE_KEY) -vvvv

# ----------------------------------------------------------------------------
# Sepolia host chain
# ----------------------------------------------------------------------------
deploy-hook-dry:
	@forge script $(HOOK_SCRIPT) --rpc-url $(SEPOLIA_RPC_URL) --chain-id $(SEPOLIA_CHAIN_ID) -vvvv

deploy-hook:
	@forge script $(HOOK_SCRIPT) --rpc-url $(SEPOLIA_RPC_URL) --chain-id $(SEPOLIA_CHAIN_ID) --broadcast --verify -vvvv

mint-usdc:
	@cast send $(MOCK_USDC_ADDRESS) "mint(address,uint256)" $(DEPLOYER) $(SEED_USDC_AMOUNT) \
		--rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY)

stage-init-seed:
	@forge script $(STAGE_SCRIPT) --rpc-url $(SEPOLIA_RPC_URL) --chain-id $(SEPOLIA_CHAIN_ID) --broadcast -vvvv

# ----------------------------------------------------------------------------
# Reactive Lasna (ReactVM)
# ----------------------------------------------------------------------------
faucet:
	@cast send $(FAUCET) "request(address)" $(DEPLOYER) --value $(FAUCET_VALUE) \
		--rpc-url $(SEPOLIA_RPC_URL) --private-key $(PRIVATE_KEY)

deploy-reactive-dry:
	@forge script $(REACTIVE_SCRIPT) --rpc-url $(LASNA_RPC_URL) -vvvv

deploy-reactive:
	@forge script $(REACTIVE_SCRIPT) --rpc-url $(LASNA_RPC_URL) --broadcast -vvvv

reactive-balance:
	@cast balance $(REACTIVE_ADDRESS) --rpc-url $(LASNA_RPC_URL) --ether

reactive-paused:
	@P=$$(cast storage $(REACTIVE_ADDRESS) 0 --rpc-url $(LASNA_RPC_URL) | cut -c23-24); \
		[ "$$P" = "01" ] && echo "PAUSED" || echo "ACTIVE"

reactive-topup:
	@cast send $(REACTIVE_ADDRESS) --value $(RGAS_FUND_AMOUNT) \
		--rpc-url $(LASNA_RPC_URL) --private-key $(PRIVATE_KEY)

reactive-pause:
	@cast send $(REACTIVE_ADDRESS) "pause()" --rpc-url $(LASNA_RPC_URL) --private-key $(PRIVATE_KEY)

reactive-resume:
	@cast send $(REACTIVE_ADDRESS) "resume()" --rpc-url $(LASNA_RPC_URL) --private-key $(PRIVATE_KEY)
