import { useState } from 'react';
import { Contract } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, PASS_ABI } from '../../lib/abis';
import { fmt } from '../../lib/format';

export function PassportCard({ cfg, ccRead, me }: {
  cfg: { escrow: string }; ccRead: JsonRpcProvider; me: string | null;
}) {
  const [addr, setAddr] = useState('');
  const [out, setOut] = useState<React.ReactNode>(null);

  async function show() {
    const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
    const p = new Contract(await esc.passport(), PASS_ABI, ccRead);
    const a = addr || me;
    if (!a) return;
    const r = await p.records(a);
    const bps = await p.depositBps(a);
    const minted = (await p.balanceOf(a)) > 0n;
    setOut(
      <table><tbody>
        <tr><td>installments honored (each one an Attestcoin proof)</td><td><b>{String(r.honored)}</b></td></tr>
        <tr><td>defaults consumed</td><td><b>{String(r.defaulted)}</b></td></tr>
        <tr><td>volume proven</td><td>{fmt(r.volume)}</td></tr>
        <tr><td>next deposit</td><td><b>{Number(bps) / 100} %</b></td></tr>
        <tr><td>passport token</td><td>{minted ? <span className="ok">minted (soulbound)</span> : <span className="mut">none yet</span>}</td></tr>
      </tbody></table>
    );
  }

  return (
    <section className="card"><h2><span className="n">4</span> Credit passport</h2>
      <div className="desc">ERC-5192 soulbound. Not a score — a record of payment facts, each one an Attestcoin-verified installment.</div>
      <label>Address</label><input id="p-addr" placeholder="0x… (defaults to you)" value={addr} onChange={e => setAddr(e.target.value)} /><button id="p-load" className="sec" onClick={show}>Show</button>
      <div id="p-out">{out}</div>
      <div style={{ marginTop: 16 }}><span className="mut" style={{ fontSize: 12 }}>Share this checkout</span>
        <img id="qr" alt="QR" src={'https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=' + encodeURIComponent(location.href)} />
      </div>
    </section>
  );
}
