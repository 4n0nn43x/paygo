import { Contract } from 'ethers';
import { ASSET_ABI } from './abis';

export interface AssetMeta { name: string; description: string; image?: string }

const PREFIX = 'data:application/json,';

/** Fetches and parses a DemoAsset's on-chain tokenURI (contracts/Demo.sol's data-URI JSON). */
export async function fetchAssetMeta(assetAddress: string, tokenId: bigint | number, provider: any): Promise<AssetMeta | null> {
  try {
    const asset = new Contract(assetAddress, ASSET_ABI, provider);
    const uri: string = await asset.tokenURI(tokenId);
    if (!uri.startsWith(PREFIX)) return null;
    return JSON.parse(uri.slice(PREFIX.length));
  } catch { return null; }
}
