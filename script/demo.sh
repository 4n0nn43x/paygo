#!/usr/bin/env sh
# Demo in 3 acts, from the CLI. Requires .env filled by script/deploy.sh.
#   sh script/demo.sh order            → seller mints an asset, escrows it, buyer = $BUYER (default: self), 4 installments
#   sh script/demo.sh pay <orderId> <n> → pay installment n on Sepolia (mints test USDC as needed)
#   sh script/demo.sh default <orderId> → assert default (needs attested height > deadline + GRACE)
#   sh script/demo.sh finalize <orderId>
#   sh script/demo.sh claim <orderId>    → buyer collects the asset after Completed (pull, not automatic)
#   sh script/demo.sh withdraw <orderId> → seller collects the asset back after Defaulted (pull, not automatic)
#   sh script/demo.sh show <orderId>
#   sh script/demo.sh passport [addr]   → the buyer's credit passport (facts + deposit rule)
#   --- Proof-of-Custody (chip-backed authenticity, BOND=<wei> on `order` to post a custody stake) ---
#   sh script/demo.sh attest-origin   <orderId> <chipPrivKey> [sellerPrivKey] → seller's chip signs at listing
#   sh script/demo.sh attest-delivery <orderId> <chipPrivKey> [buyerPrivKey]  → buyer's delivery scan; same chip = bond returns to seller, different chip = slashed to buyer
#     (submitter must be the order's seller for attest-origin, buyer for attest-delivery — defaults to $PK)
#   sh script/demo.sh bond <orderId>            → outstanding custody bond
#   sh script/demo.sh withdraw-bond <orderId>   → resolve the bond (timed-out or already decided) into the claimable pool
#   sh script/demo.sh claim-bond [privKey]      → pull your resolved bond (defaults to $PK)
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
  cast send $ASSET_ADDRESS "mint(address)" $ME $CC >/dev/null 2>&1
  cast send $ASSET_ADDRESS "approve(address,uint256)" $ESCROW_ADDRESS $ID $CC >/dev/null 2>&1
  # first deadline = next epoch boundary at least 2 epochs ahead of the current Sepolia head
  HEAD=$(cast block-number --rpc-url $SOURCE_CHAIN_RPC_URL)
  FIRST=$(( (HEAD / EPOCH + 2) * EPOCH ))
  PRICE=${PRICE:-100000000}; N=${N:-4}               # 100 tUSDC in 4 installments; deposit sized by the buyer's passport
  BOND=${BOND:-1000000000000000}                     # custody bond in wei CTC (default 0.001 CTC); 0 needs a clean SellerPassport
  cast send --value $BOND $ESCROW_ADDRESS "createOrder(address,address,uint256,address,address,uint256,uint8,uint64,uint64)" \
    $BUYER $ASSET_ADDRESS $ID $ME $USDC_ADDRESS $PRICE $N $FIRST $EPOCH $CC >/dev/null 2>&1
  OID=$(( $(cast call $ESCROW_ADDRESS "nextOrderId()(uint256)" --rpc-url $CREDITCOIN_RPC_URL) - 1 ))
  echo "order $OID: asset #$ID escrowed, buyer $BUYER, deadlines $FIRST +k×$EPOCH (Sepolia height)"
  cast call $ESCROW_ADDRESS "getOrder(uint256)((address,address,address,uint256,address,address,uint64,uint64,uint8,uint8,uint8,uint8,uint64,uint64,address,bool,bool,uint256[]))" $OID --rpc-url $CREDITCOIN_RPC_URL | grep -o '\[[0-9 \[\]e.,]*\]$' | sed 's/^/  installments: /';;
pay)
  OID=$2; N=$3
  # strip cast's " [4e7]" scientific annotations, then read the Nth element of the amounts[] array
  RAW=$(cast call $ESCROW_ADDRESS "getOrder(uint256)((address,address,address,uint256,address,address,uint64,uint64,uint8,uint8,uint8,uint8,uint64,uint64,address,bool,bool,uint256[]))" $OID --rpc-url $CREDITCOIN_RPC_URL | sed -E 's/ \[[0-9.e+]+\]//g')
  AMTS=$(echo "$RAW" | grep -o '\[[0-9, ]*\]' | tail -1 | tr -d '[] ')
  AMT=$(echo "$AMTS" | cut -d, -f$((N + 1)))
  cast send $USDC_ADDRESS "mint(address,uint256)" $ME $AMT $SEP >/dev/null 2>&1
  cast send $USDC_ADDRESS "approve(address,uint256)" $ROUTER_ADDRESS $AMT $SEP >/dev/null 2>&1
  TX=$(cast send $ROUTER_ADDRESS "payInstallment(address,uint256,uint8,address,address,uint256)" $ESCROW_ADDRESS $OID $N $USDC_ADDRESS $ME $AMT $SEP --json 2>/dev/null | grep -o '"transactionHash":"0x[0-9a-f]*"' | cut -d'"' -f4 | head -1)
  echo "paid installment $N of order $OID on Sepolia: $TX  (the worker will prove & settle it)";;
default)  cast send $ESCROW_ADDRESS "declareDefault(uint256)" $2 $CC 2>&1 | grep -E "^status|^transactionHash|Error";;
finalize) cast send $ESCROW_ADDRESS "finalizeDefault(uint256)" $2 $CC 2>&1 | grep -E "^status|^transactionHash|Error";;
claim)    cast send $ESCROW_ADDRESS "claimAsset(uint256)" $2 $CC 2>&1 | grep -E "^status|^transactionHash|Error";;
withdraw) cast send $ESCROW_ADDRESS "withdrawAsset(uint256)" $2 $CC 2>&1 | grep -E "^status|^transactionHash|Error";;
show)     cast call $ESCROW_ADDRESS "getOrder(uint256)((address,address,address,uint256,address,address,uint64,uint64,uint8,uint8,uint8,uint8,uint64,uint64,address,bool,bool,uint256[]))" $2 --rpc-url $CREDITCOIN_RPC_URL;;
passport) P=$(cast call $ESCROW_ADDRESS "passport()(address)" --rpc-url $CREDITCOIN_RPC_URL); A=${2:-$ME}
  echo "buyer passport  $P  records(honored,defaulted,volume)=$(cast call $P 'records(address)(uint32,uint32,uint256)' $A --rpc-url $CREDITCOIN_RPC_URL | tr '\n' ' ') depositBps=$(cast call $P 'depositBps(address)(uint16)' $A --rpc-url $CREDITCOIN_RPC_URL)"
  SP=$(cast call $ESCROW_ADDRESS "sellerPassport()(address)" --rpc-url $CREDITCOIN_RPC_URL)
  echo "seller passport $SP  records(confirmed,disputed)=$(cast call $SP 'records(address)(uint32,uint32)' $A --rpc-url $CREDITCOIN_RPC_URL | tr '\n' ' ') waivesBond=$(cast call $SP 'waivesBond(address)(bool)' $A --rpc-url $CREDITCOIN_RPC_URL)";;
attest-origin|attest-delivery)
  OID=$2; CHIP_PK=$3; SUBMITTER_PK=${4:-$PK}; ROLE=0; [ "$1" = attest-delivery ] && ROLE=1
  CHIP=$(cast wallet address --private-key "$CHIP_PK")
  DIGEST=$(cast call $CUSTODY_ROUTER_ADDRESS "digest(address,uint256,uint8)(bytes32)" $ESCROW_ADDRESS $OID $ROLE --rpc-url $SOURCE_CHAIN_RPC_URL)
  SIG=$(cast wallet sign --private-key "$CHIP_PK" --no-hash "$DIGEST")
  cast send $CUSTODY_ROUTER_ADDRESS "attestPossession(address,uint256,uint8,address,bytes)" $ESCROW_ADDRESS $OID $ROLE $CHIP $SIG --rpc-url $SOURCE_CHAIN_RPC_URL --private-key "$SUBMITTER_PK" 2>&1 | grep -E "^status|^transactionHash|Error"
  echo "chip $CHIP attested role $ROLE (0=origin,1=delivery) for order $OID on Sepolia, submitted by $(cast wallet address --private-key "$SUBMITTER_PK") (the worker proves & settleCustody's it — must match the order's seller/buyer or it's silently ignored)";;
bond)          cast call $ESCROW_ADDRESS "custodyBond(uint256)(uint256)" $2 --rpc-url $CREDITCOIN_RPC_URL;;
withdraw-bond) cast send $ESCROW_ADDRESS "withdrawBond(uint256)" $2 $CC 2>&1 | grep -E "^status|^transactionHash|Error";;
claim-bond)    CPK=${2:-$PK}; cast send $ESCROW_ADDRESS "claimBond()" --rpc-url $CREDITCOIN_RPC_URL --private-key "$CPK" 2>&1 | grep -E "^status|^transactionHash|Error";;
*) sed -n 2,17p "$0";;
esac
