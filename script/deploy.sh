#!/usr/bin/env sh
# Deploys PayGo on Sepolia (Router + TestUSDC) and CC3 testnet (Escrow + DemoAsset).
# Usage: set .env (see .env.example) then `sh script/deploy.sh`. Prints the lines to paste back into .env.
set -eu
. ./.env
PK=$CREDITCOIN_WALLET_PRIVATE_KEY            # same key on both chains
DECODER=node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder:0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f
GRACE=${GRACE:-2000}                          # Ethereum blocks after deadline before default may be asserted (~6h40)
CURE=${CURE:-240}                             # Creditcoin blocks (~1h) to prove an on-time payment after assertion
CUSTODY_WINDOW=${CUSTODY_WINDOW:-240}         # Creditcoin blocks (~1h) after Completed before an unresolved bond reverts to the seller

addr() { grep -o 'Deployed to: 0x[0-9a-fA-F]*' | cut -d' ' -f3; }

echo "# Sepolia"
ROUTER=$(forge create --broadcast --rpc-url "$SOURCE_CHAIN_RPC_URL" --private-key "$PK" contracts/PayGoRouter.sol:PayGoRouter 2>/dev/null | addr)
CUSTODY_ROUTER=$(forge create --broadcast --rpc-url "$SOURCE_CHAIN_RPC_URL" --private-key "$PK" contracts/CustodyRouter.sol:CustodyRouter 2>/dev/null | addr)
USDC=$(forge create --broadcast --rpc-url "$SOURCE_CHAIN_RPC_URL" --private-key "$PK" contracts/Demo.sol:TestUSDC 2>/dev/null | addr)
echo "ROUTER_ADDRESS=$ROUTER"
echo "CUSTODY_ROUTER_ADDRESS=$CUSTODY_ROUTER"
echo "USDC_ADDRESS=$USDC"

echo "# Creditcoin (EvmV1Decoder linked at the testnet library address — forgetting --libraries is deploy trap #1)"
ASSET=$(forge create --broadcast --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$PK" contracts/Demo.sol:DemoAsset 2>/dev/null | addr)
# ASSET must exist before ESCROW: only allowlisted asset contracts may be escrowed (createOrder rejects
# anything else) — a seller-supplied ERC-721 whose transferFrom is coded to revert on release can't be listed.
# Same reasoning applies to payToken (SC-AUDIT-01): only allowlisted ERC20s may be named at createOrder.
ESCROW=$(forge create --broadcast --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$PK" --libraries "$DECODER" \
  contracts/PayGoEscrow.sol:PayGoEscrow --constructor-args \
  "$SOURCE_CHAIN_KEY" "$ROUTER" "$GRACE" "$CURE" "[$ASSET]" "$CUSTODY_ROUTER" "$CUSTODY_WINDOW" "[$USDC]" 2>/dev/null | addr)
echo "ESCROW_ADDRESS=$ESCROW"
echo "ASSET_ADDRESS=$ASSET"
