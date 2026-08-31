import { useState } from 'react';
import { Contract, Wallet, SigningKey, formatEther } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, CUSTODY_ROUTER_ABI } from '../../lib/abis';
import { net, CC, SEP, errMsg } from '../../lib/chain';
import type { Cfg } from '../../lib/config';

const ZERO = '0x0000000000000000000000000000000000000000';

// The chip is a standalone keypair, never the connected wallet: it signs a raw digest
// locally (matches CustodyRouter's ECDSA.recover with no message prefix), then anyone submits it.
export function CustodyCard({ cfg, ccRead, log }: { cfg: Cfg; ccRead: JsonRpcProvider; log: (m: string, c?: string) => void }) {
  const [chipKey, setChipKey] = useState('');
  const [id, setId] = useState('1');
  const [out, setOut] = useState<React.ReactNode>(null);

  function genChip() {
    const w = Wallet.createRandom();
    setChipKey(w.privateKey);
    setOut(<>chip address: <b>{w.address}</b> — bind it to the seller's Origin attestation, then reuse the same key to prove Delivery</>);
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
      setOut(<>chip <b>{chip}</b> attested {role ? 'Delivery' : 'Origin'} on Sepolia: <span className="ok">{tx.hash}</span><br />the worker will prove it on Creditcoin in ~10 min</>);
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
        {o.custodyVerified ? <span className="ok">authenticity confirmed</span> : o.custodyDisputed ? <span className="bad">mismatch — cryptographic proof of substitution</span> : <span className="mut">unresolved</span>}
        {to !== ZERO && <> · recipient: {to}</>}
      </>
    );
  }

  async function resolveBond() {
    try {
      const s = await net(CC.chainId, CC);
      const tx = await new Contract(cfg.escrow, ESCROW_ABI, s).withdrawBond(id);
      setOut('resolving… ' + tx.hash);
      await tx.wait();
      setOut(<>bond resolved into the claimable pool: <span className="ok">{tx.hash}</span> — the recipient can now "Claim my bond"</>);
      log('bond resolved ' + tx.hash, 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  async function claimBond() {
    try {
      const s = await net(CC.chainId, CC);
      const tx = await new Contract(cfg.escrow, ESCROW_ABI, s).claimBond();
      setOut('claiming… ' + tx.hash);
      await tx.wait();
      setOut(<>bond claimed: <span className="ok">{tx.hash}</span></>);
      log('bond claimed ' + tx.hash, 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <section className="card"><h2><span className="n">5</span> Proof-of-Custody</h2>
      <div className="desc">A chip embedded in the physical asset signs at listing (Origin) and again at handoff (Delivery). Same chip both times → the custody bond returns to the seller. A different chip → cryptographic proof of substitution, the bond is slashed to the buyer. No jury for the common case.</div>
      <label>Chip private key (demo stand-in for an NFC chip's keypair)</label><input id="c-key" placeholder="0x…" value={chipKey} onChange={e => setChipKey(e.target.value)} /><button id="c-gen" className="sec" onClick={genChip}>Generate a chip</button>
      <label>Order id</label><input id="c-id" value={id} onChange={e => setId(e.target.value)} />
      <button id="c-origin" onClick={() => attestCustody(0)}>Attest Origin (seller)</button><button id="c-delivery" className="sec" onClick={() => attestCustody(1)}>Attest Delivery (buyer scan)</button>
      <button id="c-bond" className="sec" onClick={checkBond}>Check bond</button><button id="c-withdraw" className="sec" onClick={resolveBond}>Resolve bond</button><button id="c-claim" className="sec" onClick={claimBond}>Claim my bond</button>
      <div id="c-out" className="mono">{out}</div>
    </section>
  );
}
