import { useState } from 'react';
import { Contract, isAddress, parseEther } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, ASSET_ABI } from '../../lib/abis';
import { net, CC, errMsg } from '../../lib/chain';
import type { Cfg } from '../../lib/config';
import { AssetPreview } from './AssetPreview';

export function SellerCard({ cfg, sepRead, me, log, onOrderCreated }: {
  cfg: Cfg; sepRead: JsonRpcProvider; me: string | null; log: (m: string, c?: string) => void;
  onOrderCreated: (orderId: string) => void;
}) {
  const [assetName, setAssetName] = useState('');
  const [assetDesc, setAssetDesc] = useState('');
  const [assetImage, setAssetImage] = useState('');
  const [buyer, setBuyer] = useState('');
  const [price, setPrice] = useState('100');
  const [n, setN] = useState('4');
  const [interval, setInterval_] = useState('1000');
  const [bond, setBond] = useState('0.001');
  const [out, setOut] = useState<React.ReactNode>(null);

  async function create() {
    // the escrow rejects buyer == msg.sender (passport-sybil gate), so there is no "defaults to you"
    if (!isAddress(buyer.trim())) { setOut('enter the buyer\'s address: it must be another wallet than yours'); return; }
    if (me && buyer.trim().toLowerCase() === me.toLowerCase()) { setOut('the buyer must be another wallet than yours (the escrow rejects self-dealing)'); return; }
    try {
      const s = await net(CC.chainId, CC);
      const asset = new Contract(cfg.asset, ASSET_ABI, s);
      const esc = new Contract(cfg.escrow, ESCROW_ABI, s);
      const id = await asset.next();
      setOut('minting asset #' + id + '…');
      if (assetName.trim()) {
        await (await asset.mintWithMeta(me, assetName.trim(), assetDesc.trim(), assetImage.trim())).wait();
      } else {
        await (await asset.mint(me)).wait();
      }
      await (await asset.approve(cfg.escrow, id)).wait();
      const head = await sepRead.getBlockNumber();
      const first = (Math.floor(head / 1000) + 2) * 1000;
      const buyerAddr = buyer.trim();
      const bondWei = parseEther(bond || '0');
      const tx = await esc.createOrder(buyerAddr, cfg.asset, id, me, cfg.usdc,
        BigInt(Math.round(+price * 1e6)), +n, first, +interval, { value: bondWei });
      await tx.wait();
      const oid = (await esc.nextOrderId()) - 1n;
      setOut(<>order <b>{String(oid)}</b> created · asset #{String(id)} escrowed · first deadline Ethereum block {first}</>);
      log('order ' + oid + ' created', 'ok');
      onOrderCreated(String(oid));
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <div>
      <div className="desc">On Creditcoin. Mint a demo asset with real on-chain metadata, then escrow it with a price and a schedule. The buyer's deposit is sized by their passport.</div>
      {!me && <div className="empty-t">Connect a wallet to list.</div>}
      <div className="form-2">
        <fieldset>
          <legend>The asset</legend>
          <label htmlFor="s-name">Name</label><input id="s-name" placeholder="e.g. 1978 Vespa" value={assetName} onChange={e => setAssetName(e.target.value)} />
          <label htmlFor="s-desc">Description</label><input id="s-desc" placeholder="optional" value={assetDesc} onChange={e => setAssetDesc(e.target.value)} />
          <label htmlFor="s-image">Image URL</label><input id="s-image" placeholder="https://…" value={assetImage} onChange={e => setAssetImage(e.target.value)} />
          {assetName.trim() && <AssetPreview meta={{ name: assetName, description: assetDesc, image: assetImage }} />}
        </fieldset>
        <fieldset>
          <legend>The terms</legend>
          <label htmlFor="s-buyer">Buyer address</label><input id="s-buyer" placeholder="0x… another wallet than yours" value={buyer} onChange={e => setBuyer(e.target.value)} />
          <div className="row-2">
            <div><label htmlFor="s-price">Price (tUSDC)</label><input id="s-price" value={price} onChange={e => setPrice(e.target.value)} /></div>
            <div><label htmlFor="s-n">Installments</label><input id="s-n" value={n} onChange={e => setN(e.target.value)} /></div>
          </div>
          <div className="row-2">
            <div><label htmlFor="s-int">Interval <span className="mut">(Ethereum blocks, ×1000)</span></label><input id="s-int" value={interval} onChange={e => setInterval_(e.target.value)} /></div>
            <div><label htmlFor="s-bond">Custody bond (tCTC)</label><input id="s-bond" value={bond} onChange={e => setBond(e.target.value)} /></div>
          </div>
        </fieldset>
      </div>
      <button disabled={!me} onClick={create}>Mint the asset and create the order</button>
      <div className="out mono">{out}</div>
    </div>
  );
}
