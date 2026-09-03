import { useCallback, useEffect, useRef, useState } from 'react';
import { Contract } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, CHAININFO_ABI, CHAININFO_ADDRESS } from '../lib/abis';
import { fetchAssetMeta, type AssetMeta } from '../lib/assetMeta';
import type { ScheduleStep } from '../components/dashboard/ScheduleTimeline';

export interface OrderView {
  id: number; seller: string; buyer: string; asset: string; tokenId: bigint; payee: string;
  n: number; paidCount: number; status: number; disputedNo: number; assertedAt: bigint;
  chipId: string; custodyVerified: boolean; custodyDisputed: boolean;
  amounts: bigint[]; steps: ScheduleStep[]; price: bigint; paidAmount: bigint;
  nextNo: number | null; nextDeadline: bigint | null; overdue: boolean; cureEndsAt: bigint | null;
  att: bigint; grace: bigint; cure: bigint; ccBlock: number; meta: AssetMeta | null;
}

export type OrderState =
  | { kind: 'idle' } | { kind: 'loading' } | { kind: 'missing' }
  | { kind: 'ok'; order: OrderView } | { kind: 'error'; message: string };

/** The one place the page reads an order: escrow state, paid flags, attested clock, asset metadata. */
export function useOrder(cfg: { escrow: string; chainKey: number }, ccRead: JsonRpcProvider, orderId: string) {
  const [state, setState] = useState<OrderState>({ kind: 'idle' });
  const seq = useRef(0);

  const reload = useCallback(async () => {
    const id = Number(orderId);
    const my = ++seq.current;
    if (!Number.isInteger(id) || id <= 0) { setState({ kind: 'idle' }); return; }
    setState(s => (s.kind === 'ok' && s.order.id === id) ? s : { kind: 'loading' });
    try {
      const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
      const o = await esc.getOrder(id);
      const n = Number(o.n);
      if (my !== seq.current) return;
      if (n === 0) { setState({ kind: 'missing' }); return; }
      const ci = new Contract(CHAININFO_ADDRESS, CHAININFO_ABI, ccRead);
      const [att, grace, cure, ccBlock, meta] = await Promise.all([
        ci.get_latest_attestation_height_and_hash(cfg.chainKey), esc.GRACE(), esc.CURE_WINDOW(),
        ccRead.getBlockNumber(), fetchAssetMeta(o.asset, o.tokenId, ccRead),
      ]);
      const paid: boolean[] = await Promise.all(Array.from({ length: n }, (_, i) => esc.paid(id, i)));
      if (my !== seq.current) return;
      const amounts: bigint[] = Array.from(o.amounts, (x: any) => BigInt(x));
      const steps: ScheduleStep[] = amounts.map((amount, i) => ({
        no: i, amount, deadline: BigInt(o.firstDeadline) + BigInt(i) * BigInt(o.interval), paid: paid[i],
      }));
      const nextNo = paid.findIndex(p => !p);
      const nextDeadline = nextNo >= 0 ? steps[nextNo].deadline : null;
      const attH = BigInt(att.height), graceB = BigInt(grace), cureB = BigInt(cure);
      const status = Number(o.status);
      setState({ kind: 'ok', order: {
        id, seller: o.seller, buyer: o.buyer, asset: o.asset, tokenId: BigInt(o.tokenId), payee: o.payee,
        n, paidCount: Number(o.paidCount), status, disputedNo: Number(o.disputedNo), assertedAt: BigInt(o.assertedAt),
        chipId: o.chipId, custodyVerified: o.custodyVerified, custodyDisputed: o.custodyDisputed,
        amounts, steps, price: amounts.reduce((a, b) => a + b, 0n),
        paidAmount: amounts.reduce((a, b, i) => a + (paid[i] ? b : 0n), 0n),
        nextNo: nextNo >= 0 ? nextNo : null, nextDeadline,
        overdue: status === 0 && nextDeadline != null && att.exists && attH > nextDeadline + graceB,
        cureEndsAt: status === 1 ? BigInt(o.assertedAt) + cureB : null,
        att: attH, grace: graceB, cure: cureB, ccBlock: Number(ccBlock), meta,
      } });
    } catch (e: any) {
      if (my === seq.current) setState({ kind: 'error', message: e?.shortMessage || e?.message || String(e) });
    }
  }, [cfg.escrow, cfg.chainKey, ccRead, orderId]);

  useEffect(() => { const t = setTimeout(reload, 350); return () => clearTimeout(t); }, [reload]);
  return { state, reload };
}
