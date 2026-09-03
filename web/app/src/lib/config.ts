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

/** Polls /state every 15 s: the first response fixes the config and the read-only providers, every
 *  response refreshes the worker state. If the worker goes offline the page keeps reading the chain. */
export function useConfig() {
  const [cfg, setCfg] = useState<Cfg | null>(null);
  const [ccRead, setCcRead] = useState<JsonRpcProvider | null>(null);
  const [sepRead, setSepRead] = useState<JsonRpcProvider | null>(null);
  const [workerState, setWorkerState] = useState<WorkerState | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function refresh() {
      try {
        const s: Cfg & WorkerState = await (await fetch('/state')).json();
        if (cancelled) return;
        setWorkerState(s);
        setCfg(c => c ?? s);
        setCcRead(p => p ?? new JsonRpcProvider(s.ccRpc));
        setSepRead(p => p ?? new JsonRpcProvider(s.sepoliaRpc));
      } catch { /* worker offline: the page still reads the chain directly */ }
    }
    refresh();
    const t = setInterval(refresh, 15000);
    return () => { cancelled = true; clearInterval(t); };
  }, []);

  return { cfg, ccRead, sepRead, workerState };
}
