import { useState } from 'react';
import { Contract, Signature, AbiCoder, keccak256 } from 'ethers';
import { CreditCard, PenLine } from 'lucide-react';
import { ROUTER_ABI, USDC_ABI } from '../../lib/abis';
import { net, SEP, errMsg } from '../../lib/chain';
import { fmt } from '../../lib/format';
import type { Cfg } from '../../lib/config';
import type { OrderView } from '../../hooks/useOrder';

export function BuyerCard({ cfg, me, log, order, reload }: {
  cfg: Cfg; me: string | null; log: (m: string, c?: string) => void; order: OrderView | null; reload: () => void;
}) {
  const [gap, setGap] = useState('90');
  const [out, setOut] = useState<React.ReactNode>(null);
  const ready = !!order && !!me;
  const rest = order ? order.amounts.slice(1).reduce((a, b) => a + b, 0n) : 0n;

  async function permitDigest(usdc: Contract, owner: string, spender: string, value: bigint, deadline: number) {
    const nonce = await usdc.nonces(owner);
    const name = await usdc.name();
    return {
      domain: { name, version: '1', chainId: 11155111, verifyingContract: cfg.usdc },
      types: { Permit: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'nonce', type: 'uint256' }, { name: 'deadline', type: 'uint256' }] },
      msg: { owner, spender, value, nonce, deadline },
    };
  }

  async function payDeposit() {
    if (!order || !me) return;
    try {
      const s = await net(SEP.chainId, SEP);
      const usdc = new Contract(cfg.usdc, USDC_ABI, s);
      const router = new Contract(cfg.router, ROUTER_ABI, s);
      const amt = order.amounts[0];
      if ((await usdc.balanceOf(me)) < amt) { setOut('minting test USDC…'); await (await usdc.mint(me, amt * 4n)).wait(); }
      const dl = Math.floor(Date.now() / 1000) + 3600;
      const d = await permitDigest(usdc, me, cfg.router, amt, dl);
      const sig = Signature.from(await s.signTypedData(d.domain, d.types, d.msg));
      const tx = await router.payWithPermit(cfg.escrow, order.id, 0, cfg.usdc, order.payee, amt, dl, sig.v, sig.r, sig.s);
      setOut('paying… ' + tx.hash);
      await tx.wait();
      setOut(<>deposit paid on Ethereum: <span className="ok">{tx.hash}</span><br />the relayer proves it on Creditcoin in ~10 min, then the schedule lights up.</>);
      log('deposit paid ' + tx.hash, 'ok');
      reload();
    } catch (e) { setOut(errMsg(e)); }
  }

  async function autopay() {
    if (!order || !me) return;
    try {
      const s = await net(SEP.chainId, SEP);
      const usdc = new Contract(cfg.usdc, USDC_ABI, s);
      const g = +gap;
      const now = Math.floor(Date.now() / 1000);
      if ((await usdc.balanceOf(me)) < rest) { setOut('minting test USDC…'); await (await usdc.mint(me, rest)).wait(); }
      const domain = { name: await usdc.name(), version: '1', chainId: 11155111, verifyingContract: cfg.usdc };
      const types = { ReceiveWithAuthorization: [{ name: 'from', type: 'address' }, { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'validAfter', type: 'uint256' }, { name: 'validBefore', type: 'uint256' }, { name: 'nonce', type: 'bytes32' }] };
      const abi = AbiCoder.defaultAbiCoder();
      const list: any[] = [];
      for (let i = 1; i < order.n; i++) {
        const validAfter = now + g * i, validBefore = validAfter + 7 * 86400;
        const value = order.amounts[i];
        // routing-bound nonce = keccak256(escrow, orderId, installmentNo, payee): the Router recomputes it, so payee can't be swapped
        const nonce = keccak256(abi.encode(['address', 'uint256', 'uint8', 'address'], [cfg.escrow, order.id, i, order.payee]));
        const sig = Signature.from(await s.signTypedData(domain, types, { from: me, to: cfg.router, value, validAfter, validBefore, nonce }));
        list.push({ orderId: String(order.id), installmentNo: i, token: cfg.usdc, payee: order.payee, amount: value.toString(), from: me, validAfter, validBefore, v: sig.v, r: sig.r, s: sig.s });
      }
      const r = await (await fetch('/authorizations', { method: 'POST', body: JSON.stringify(list) })).json();
      // Never tell the buyer they are covered when they are not: a rejected or empty batch means no
      // installment will pay itself, and a late payment never cures.
      if (r.error || !r.accepted) {
        setOut(<><span className="bad">Autopay was NOT armed{r.error ? ': ' + r.error : ''}.</span> Pay each installment yourself, or retry.</>);
        log('autopay refused: ' + (r.error ?? 'nothing accepted'), 'bad');
        return;
      }
      setOut(<><span className="ok">{r.accepted} authorizations signed and handed to the relayer.</span> Close your laptop: installments pay themselves every {gap}s and get proven on Creditcoin.</>);
      log('autopay armed: ' + r.accepted + ' installments', 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <div>
      <div className="desc">Two steps, on Ethereum. Pay the deposit in one click, then sign once for the rest: the relayer submits each installment when it is due.</div>
      {!order && <div className="empty-t">Load an order first (pick its id in the header).</div>}
      {order && !me && <div className="empty-t">Connect a wallet to pay.</div>}
      <div className="steps">
        <div className="step">
          <div className="step-h"><span className="step-n">1</span><CreditCard aria-hidden="true" />Deposit</div>
          <div className="step-v mono">{order ? fmt(order.amounts[0]) : '–'}</div>
          <div className="step-s">{order?.steps[0].paid ? <span className="ok">proven</span> : 'one transaction, signed with a permit'}</div>
          <button disabled={!ready || order?.steps[0].paid} onClick={payDeposit}>Pay deposit</button>
        </div>
        <div className="step">
          <div className="step-h"><span className="step-n">2</span><PenLine aria-hidden="true" />Sign once</div>
          <div className="step-v mono">{order ? fmt(rest) : '–'}</div>
          <div className="step-s">{order ? `${order.n - 1} installments, pre-signed, submitted by anyone when due` : 'remaining installments'}</div>
          <label htmlFor="b-gap">Seconds between installments <span className="mut">(demo pacing)</span></label>
          <input id="b-gap" value={gap} onChange={e => setGap(e.target.value)} />
          <button disabled={!ready} onClick={autopay}>Sign once, autopay the rest</button>
        </div>
      </div>
      <div className="out mono">{out}</div>
    </div>
  );
}
