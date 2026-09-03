import { useState } from 'react';
import { Contract, Wallet, SigningKey, formatEther } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { Cpu, PackageOpen, Truck } from 'lucide-react';
import { ESCROW_ABI, CUSTODY_ROUTER_ABI } from '../../lib/abis';
import { net, CC, SEP, errMsg } from '../../lib/chain';
import type { Cfg } from '../../lib/config';

const ZERO = '0x0000000000000000000000000000000000000000';

// The chip is a standalone keypair, never the connected wallet: it signs a raw digest
// locally (matches CustodyRouter's ECDSA.recover with no message prefix), then anyone submits it.
export function CustodyCard({ cfg, ccRead, log, orderId, reload }: {
  cfg: Cfg; ccRead: JsonRpcProvider; log: (m: string, c?: string) => void; orderId: string; reload: () => void;
}) {
  const [chipKey, setChipKey] = useState('');
  const [out, setOut] = useState<React.ReactNode>(null);
  const id = orderId;

  function genChip() {
    const w = Wallet.createRandom();
    setChipKey(w.privateKey);
    setOut(<>chip address: <b>{w.address}</b>. Bind it at listing (Origin), then reuse the same key to prove Delivery.</>);
  }

  async function attestCustody(role: 0 | 1) {
    try {
      const pk = chipKey;
      if (!pk) { setOut('paste or generate a chip key first'); return; }
      const chip = new Wallet(pk).address;
      const s = await net(SEP.chainId, SEP);
      const cr = new Contract(cfg.custodyRouter!, CUSTODY_ROUTER_ABI, s);
      const digest = await cr.digest(cfg.escrow, id, role);
      const sig = new SigningKey(pk).sign(digest).serialized;
      const tx = await cr.attestPossession(cfg.escrow, id, role, chip, sig);
      setOut((role ? 'delivery' : 'origin') + ' attestation… ' + tx.hash);
      await tx.wait();
      setOut(<>chip <b>{chip}</b> attested {role ? 'Delivery' : 'Origin'} on Ethereum: <span className="ok">{tx.hash}</span><br />the relayer proves it on Creditcoin in ~10 min</>);
      log((role ? 'delivery' : 'origin') + ' attested ' + tx.hash, 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  async function checkBond() {
    const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
    const bond = await esc.custodyBond(id);
    const to = await esc.bondRecipient(id);
    const o = await esc.getOrder(id);
    setOut(
      <>bond: <b>{formatEther(bond)} tCTC</b> · chip bound: {o.chipId === ZERO ? <span className="mut">none yet</span> : o.chipId}<br />
        {o.custodyVerified ? <span className="ok">authenticity confirmed</span> : o.custodyDisputed ? <span className="bad">mismatch, cryptographic proof of substitution</span> : <span className="mut">unresolved</span>}
        {to !== ZERO && <> · recipient: {to}</>}
      </>
    );
  }

  async function esc(fn: 'withdrawBond' | 'claimBond', label: string) {
    try {
      const s = await net(CC.chainId, CC);
      const c = new Contract(cfg.escrow, ESCROW_ABI, s);
      const tx = fn === 'withdrawBond' ? await c.withdrawBond(id) : await c.claimBond();
      setOut(label + '… ' + tx.hash);
      await tx.wait();
      setOut(<>{label}: <span className="ok">{tx.hash}</span></>);
      log(label + ' ' + tx.hash, 'ok');
      reload();
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <div>
      <div className="desc">A chip inside the item signs at listing, and again at handoff.</div>
      <div className="form-2">
        <fieldset>
          <legend><Cpu aria-hidden="true" />The chip</legend>
          <label htmlFor="c-key">Chip key <span className="mut">stands in for the NFC chip inside the item</span></label>
          <input id="c-key" placeholder="0x…" value={chipKey} onChange={e => setChipKey(e.target.value)} />
          <button className="sec" onClick={genChip}>Generate a chip</button>
        </fieldset>
        <fieldset>
          <legend>Scan for order {id}</legend>
          <div className="btn-col">
            <button onClick={() => attestCustody(0)}><PackageOpen aria-hidden="true" />Origin <span className="hint">seller, at listing</span></button>
            <button onClick={() => attestCustody(1)}><Truck aria-hidden="true" />Delivery <span className="hint">buyer, at handoff</span></button>
          </div>
        </fieldset>
      </div>
      <div className="btn-row">
        <button className="sec" onClick={checkBond}>Check bond</button>
        <button className="sec" onClick={() => esc('withdrawBond', 'bond resolved')}>Resolve bond</button>
        <button className="sec" onClick={() => esc('claimBond', 'bond claimed')}>Claim my bond</button>
      </div>
      <div className="out mono">{out}</div>
      <p className="note">Same chip both times means nothing was swapped, and the bond returns to the seller.
        A different chip proves nothing, since a chip is just a keypair, so the bond is burned rather than
        paid to anyone.</p>
    </div>
  );
}
