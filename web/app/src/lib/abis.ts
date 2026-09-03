// Human-readable ABIs: only the functions the dashboard calls.
export const ESCROW_ABI = [
  'function createOrder(address buyer,address asset,uint256 tokenId,address payee,address payToken,uint256 price,uint8 n,uint64 firstDeadline,uint64 interval) payable returns (uint256)',
  'function nextOrderId() view returns (uint256)',
  'function getOrder(uint256) view returns (tuple(address seller,address buyer,address asset,uint256 tokenId,address payee,address payToken,uint64 firstDeadline,uint64 interval,uint8 n,uint8 paidCount,uint8 disputedNo,uint8 status,uint64 assertedAt,uint64 closedAt,address chipId,bool custodyVerified,bool custodyDisputed,uint256[] amounts))',
  'function paid(uint256,uint8) view returns (bool)',
  'function passport() view returns (address)',
  'function sellerPassport() view returns (address)',
  'function declareDefault(uint256)',
  'function finalizeDefault(uint256)',
  'function GRACE() view returns (uint64)',
  'function CURE_WINDOW() view returns (uint64)',
  'function custodyBond(uint256) view returns (uint256)',
  'function bondRecipient(uint256) view returns (address)',
  'function withdrawBond(uint256)',
  'function claimableBond(address) view returns (uint256)',
  'function claimBond()',
  'function claimAsset(uint256)',
  'function withdrawAsset(uint256)',
] as const;

export const CUSTODY_ROUTER_ABI = [
  'function digest(address escrow,uint256 orderId,uint8 role) view returns (bytes32)',
  'function attestPossession(address escrow,uint256 orderId,uint8 role,address chip,bytes signature)',
] as const;

export const PASS_ABI = [
  'function records(address) view returns (uint32 honored,uint32 defaulted,uint256 volume)',
  'function depositBps(address) view returns (uint16)',
  'function balanceOf(address) view returns (uint256)',
] as const;

export const ASSET_ABI = [
  'function mint(address) returns (uint256)',
  'function mintWithMeta(address to, string name, string description, string image) returns (uint256)',
  'function tokenURI(uint256) view returns (string)',
  'function next() view returns (uint256)',
  'function approve(address,uint256)',
  'function ownerOf(uint256) view returns (address)',
] as const;

export const ROUTER_ABI = [
  'function payWithPermit(address escrow,uint256 orderId,uint8 installmentNo,address token,address payee,uint256 amount,uint256 deadline,uint8 v,bytes32 r,bytes32 s)',
] as const;

export const USDC_ABI = [
  'function mint(address,uint256)',
  'function nonces(address) view returns (uint256)',
  'function name() view returns (string)',
  'function balanceOf(address) view returns (uint256)',
] as const;

export const CHAININFO_ABI = [
  'function get_latest_attestation_height_and_hash(uint64) view returns (tuple(uint64 height,bytes32 hash,bool isAttestation,bool exists))',
] as const;

export const CHAININFO_ADDRESS = '0x0000000000000000000000000000000000000fD3';

export const STATUS = ['Active', 'DefaultAsserted', 'Defaulted', 'Completed'] as const;
