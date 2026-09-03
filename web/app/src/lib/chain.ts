import { BrowserProvider, type Signer } from 'ethers';

export const CC = {
  chainId: '0x18e8f',
  chainName: 'Creditcoin CC3 Testnet',
  rpcUrls: ['https://rpc.cc3-testnet.creditcoin.network'],
  nativeCurrency: { name: 'tCTC', symbol: 'tCTC', decimals: 18 },
  blockExplorerUrls: ['https://explorer.cc3-testnet.creditcoin.network'],
};

export const SEP = {
  chainId: '0xaa36a7',
  chainName: 'Sepolia',
  rpcUrls: ['https://ethereum-sepolia-rpc.publicnode.com'],
  nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
};

/** Switch (or add) the connected wallet to the target chain, return a signer. */
export async function net(chainIdHex: string, add?: typeof CC | typeof SEP): Promise<Signer> {
  const p = (window as any).ethereum;
  if (!p) throw new Error('Install MetaMask');
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainIdHex }] });
  } catch (e: any) {
    if (e.code === 4902 && add) await p.request({ method: 'wallet_addEthereumChain', params: [add] });
    else throw e;
  }
  const bp = new BrowserProvider(p);
  return bp.getSigner();
}

export function errMsg(e: any): string {
  return e?.shortMessage || e?.message || String(e);
}
