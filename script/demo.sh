#!/usr/bin/env sh
# Demo in 3 acts, from the CLI. Requires .env filled by script/deploy.sh.
#   sh script/demo.sh order            → seller mints an asset, escrows it, buyer = $BUYER (default: self), 4 installments
#   sh script/demo.sh pay <orderId> <n> → pay installment n on Sepolia (mints test USDC as needed)
#   sh script/demo.sh default <orderId> → assert default (needs attested height > deadline + GRACE)
#   sh script/demo.sh finalize <orderId>
#   sh script/demo.sh show <orderId>
set -eu
. ./.env
PK=$CREDITCOIN_WALLET_PRIVATE_KEY
ME=$(cast wallet address --private-key "$PK")
BUYER=${BUYER:-$ME}
CC="--rpc-url $CREDITCOIN_RPC_URL --private-key $PK"
SEP="--rpc-url $SOURCE_CHAIN_RPC_URL --private-key $PK"
EPOCH=1000

case "${1:-}" in
order)
  ID=$(cast call $ASSET_ADDRESS "next()(uint256)" --rpc-url $CREDITCOIN_RPC_URL)
  cast send $ASSET_ADDRESS "mint(address)" $ME $CC >/dev/null
  cast send $ASSET_ADDRESS "approve(address,uint256)" $ESCROW_ADDRESS $ID $CC >/dev/null
  # first deadline = next epoch boundary at least 2 epochs ahead of the current Sepolia head
  HEAD=$(cast block-number --rpc-url $SOURCE_CHAIN_RPC_URL)
  FIRST=$(( (HEAD / EPOCH + 2) * EPOCH ))
  AMOUNTS="[40000000,20000000,20000000,20000000]"   # 40 + 3×20 tUSDC (6 decimals)
  cast send $ESCROW_ADDRESS "createOrder(address,address,uint256,address,address,uint256[],uint64,uint64)" \
    $BUYER $ASSET_ADDRESS $ID $ME $USDC_ADDRESS "$AMOUNTS" $FIRST $EPOCH $CC >/dev/null
  OID=$(( $(cast call $ESCROW_ADDRESS "nextOrderId()(uint256)" --rpc-url $CREDITCOIN_RPC_URL) - 1 ))
  echo "order $OID: asset #$ID escrowed, buyer $BUYER, deadlines $FIRST +k×$EPOCH (Sepolia height)";;
pay)
  OID=$2; N=$3
  AMT=$(cast call $ESCROW_ADDRESS "getOrder(uint256)((address,address,address,uint256,address,address,uint64,uint64,uint8,uint8,uint8,uint8,uint64,uint256[]))" $OID --rpc-url $CREDITCOIN_RPC_URL | tr -d '[]() ' | cut -d, -f$((14 + N)))
  cast send $USDC_ADDRESS "mint(address,uint256)" $ME $AMT $SEP >/dev/null
  cast send $USDC_ADDRESS "approve(address,uint256)" $ROUTER_ADDRESS $AMT $SEP >/dev/null
  TX=$(cast send $ROUTER_ADDRESS "payInstallment(address,uint256,uint8,address,address,uint256)" $ESCROW_ADDRESS $OID $N $USDC_ADDRESS $ME $AMT $SEP --json | grep -o '"transactionHash":"0x[0-9a-f]*"' | cut -d'"' -f4)
  echo "paid installment $N of order $OID on Sepolia: $TX  (the worker will prove & settle it)";;
default)  cast send $ESCROW_ADDRESS "declareDefault(uint256)" $2 $CC | grep -E "status|transactionHash";;
finalize) cast send $ESCROW_ADDRESS "finalizeDefault(uint256)" $2 $CC | grep -E "status|transactionHash";;
show)     cast call $ESCROW_ADDRESS "getOrder(uint256)((address,address,address,uint256,address,address,uint64,uint64,uint8,uint8,uint8,uint8,uint64,uint256[]))" $2 --rpc-url $CREDITCOIN_RPC_URL;;
*) sed -n 2,8p "$0";;
esac
