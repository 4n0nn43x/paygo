import { useEffect, useState } from 'react';
import { JsonRpcProvider } from 'ethers';

export interface Cfg {
  router: string;
  custodyRouter?: string;
  escrow: string;
  usdc: string;
  asset: string;
  chainKey: number;
  sepoliaRpc: string;
  ccRpc: string;
}

export interface WorkerState {
  pending: { hash: string; height: number }[];
  autopay: { orderId: string; installmentNo: number; txHash?: string; error?: string; validAfter: number }[];
  settles: { tx: string; count: number; gas: string }[];
  done: number;
  custodyPending: { hash: string; height: number }[];
  custodyDone: number;
}

/** Fetches /state once (same as the original init()), exposes read-only providers built from it. */
export function useConfig() {
  const [cfg, setCfg] = useState<Cfg | null>(null);
  const [ccRead, setCcRead] = useState<JsonRpcProvider | null>(null);
  const [sepRead, setSepRead] = useState<JsonRpcProvider | null>(null);

  useEffect(() => {
    fetch('/state')
      .then(r => r.json())
      .then((c: Cfg) => {
        setCfg(c);
        setCcRead(new JsonRpcProvider(c.ccRpc));
        setSepRead(new JsonRpcProvider(c.sepoliaRpc));
      });
  }, []);

  return { cfg, ccRead, sepRead };
}
