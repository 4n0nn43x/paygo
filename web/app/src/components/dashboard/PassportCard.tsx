import { useEffect, useState } from 'react';
import { Contract } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, PASS_ABI } from '../../lib/abis';
import { fmt } from '../../lib/format';
import { BrandMark } from './BrandMark';

type Rec = { honored: number; defaulted: number; volume: bigint; bps: number; minted: boolean };

/** Credit passport as a card you own (plastic-card ratio, navy): four facts, no chart, no score. */
export function PassportCard({ cfg, ccRead, me }: { cfg: { escrow: string }; ccRead: JsonRpcProvider; me: string | null }) {
  const [addr, setAddr] = useState('');
  const [rec, setRec] = useState<Rec | null>(null);
  const who = addr.trim() || me;

  useEffect(() => {
    let live = true;
    if (!who || !/^0x[0-9a-fA-F]{40}$/.test(who)) { setRec(null); return; }
    (async () => {
      try {
        const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
        const p = new Contract(await esc.passport(), PASS_ABI, ccRead);
        const [r, bps, bal] = await Promise.all([p.records(who), p.depositBps(who), p.balanceOf(who)]);
        if (live) setRec({ honored: Number(r.honored), defaulted: Number(r.defaulted), volume: BigInt(r.volume), bps: Number(bps), minted: bal > 0n });
      } catch { if (live) setRec(null); }
    })();
    return () => { live = false; };
  }, [who, cfg.escrow, ccRead]);

  return (
    <section className="card">
      <h2>Credit passport</h2>
      <div className="desc">Not a score. Every line is a payment the chain verified. It sizes your next deposit.</div>
      <div className="pass">
        <div className="pass-top"><BrandMark className="mark" /><span className="mono">{who ? who.slice(0, 6) + '…' + who.slice(-4) : 'no wallet'}</span></div>
        <div className="pass-grid">
          <div><span className="k">Honored</span><span className="v">{rec ? rec.honored : '–'}</span></div>
          <div><span className="k">Defaults</span><span className="v">{rec ? rec.defaulted : '–'}</span></div>
          <div><span className="k">Volume proven</span><span className="v small">{rec ? fmt(rec.volume) : '–'}</span></div>
          <div><span className="k">Next deposit</span><span className="v">{rec ? `${rec.bps / 100}%` : '–'}</span></div>
        </div>
        <div className="pass-foot">{rec?.minted ? 'soulbound · cannot be sold or transferred' : 'issued on your first proven installment'}</div>
      </div>
      <label htmlFor="p-addr">Look up another address</label>
      <input id="p-addr" placeholder="0x…" value={addr} onChange={e => setAddr(e.target.value)} />
    </section>
  );
}
