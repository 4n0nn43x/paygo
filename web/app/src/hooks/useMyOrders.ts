import { useCallback, useEffect, useState } from 'react';
import { Contract } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI } from '../lib/abis';
import { fetchAssetMeta } from '../lib/assetMeta';

export interface OrderRow {
  id: string; role: 'seller' | 'buyer'; status: number;
  paidCount: number; n: number; price: bigint; name: string; image?: string;
}

export type MyOrdersState =
  | { kind: 'idle' } | { kind: 'loading' } | { kind: 'ok'; rows: OrderRow[] } | { kind: 'error'; message: string };

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** Every order the connected wallet is a party to, newest first.
 *  ponytail: reads orders 1..nextOrderId-1 and filters client-side. No indexer, no deployment-block
 *  constant to keep in sync with the escrow address, and correct for the tens of orders a testnet
 *  carries. `OrderCreated` indexes both seller and buyer, so if the count ever outgrows this the
 *  upgrade is two `queryFilter` calls of the same shape, plus a fromBlock (`fromBlock: 0` times the
 *  CC3 RPC out, measured). */
export function useMyOrders(cfg: { escrow: string }, ccRead: JsonRpcProvider, me: string | null) {
  const [state, setState] = useState<MyOrdersState>({ kind: 'idle' });

  const reload = useCallback(async () => {
    if (!me) { setState({ kind: 'idle' }); return; }
    setState(s => s.kind === 'ok' ? s : { kind: 'loading' });
    try {
      const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
      const next = Number(await esc.nextOrderId());
      const ids = Array.from({ length: Math.max(0, next - 1) }, (_, i) => i + 1);
      const orders = await Promise.all(ids.map(id => esc.getOrder(id)));
      const mine = orders.map((o, i) => ({ o, id: ids[i] })).filter(({ o }) => eq(o.seller, me) || eq(o.buyer, me));
      const metas = await Promise.all(mine.map(({ o }) => fetchAssetMeta(o.asset, o.tokenId, ccRead)));
      const rows: OrderRow[] = mine.map(({ o, id }, i) => {
        const amounts: bigint[] = Array.from(o.amounts, (x: any) => BigInt(x));
        return {
          id: String(id),
          role: eq(o.seller, me) ? 'seller' as const : 'buyer' as const,
          status: Number(o.status),
          paidCount: Number(o.paidCount),
          n: Number(o.n),
          price: amounts.reduce((a, b) => a + b, 0n),
          name: metas[i]?.name || `Item #${o.tokenId}`,
          image: metas[i]?.image,
        };
      }).reverse();
      setState({ kind: 'ok', rows });
    } catch (e: any) {
      setState({ kind: 'error', message: e?.shortMessage || e?.message || String(e) });
    }
  }, [cfg.escrow, ccRead, me]);

  useEffect(() => { reload(); }, [reload]);
  return { state, reload };
}
