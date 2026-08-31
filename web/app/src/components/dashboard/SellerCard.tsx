import { useState } from 'react';
import { Contract, parseEther } from 'ethers';
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
      const buyerAddr = buyer || me;
      const bondWei = parseEther(bond || '0');
      const tx = await esc.createOrder(buyerAddr, cfg.asset, id, me, cfg.usdc,
        BigInt(Math.round(+price * 1e6)), +n, first, +interval, { value: bondWei });
      await tx.wait();
      const oid = (await esc.nextOrderId()) - 1n;
      setOut(<>order <b>{String(oid)}</b> created · asset #{String(id)} escrowed · first deadline Sepolia height {first}</>);
      log('order ' + oid + ' created', 'ok');
      onOrderCreated(String(oid));
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <section className="card"><h2><span className="n">1</span> Seller — list an asset</h2>
      <div className="desc">Creditcoin CC3. Mint a demo asset, escrow it with a price and a schedule. The buyer's deposit is sized by their passport (40 % → 15 %).</div>
      <label>Asset name (optional — real on-chain tokenURI metadata)</label><input id="s-name" placeholder="e.g. 1978 Vespa" value={assetName} onChange={e => setAssetName(e.target.value)} />
      <label>Description</label><input id="s-desc" placeholder="optional" value={assetDesc} onChange={e => setAssetDesc(e.target.value)} />
      <label>Image URL</label><input id="s-image" placeholder="https://…" value={assetImage} onChange={e => setAssetImage(e.target.value)} />
      {assetName.trim() && <AssetPreview meta={{ name: assetName, description: assetDesc, image: assetImage }} />}
      <label>Buyer address</label><input id="s-buyer" placeholder="0x… (defaults to you)" value={buyer} onChange={e => setBuyer(e.target.value)} />
      <label>Price (tUSDC)</label><input id="s-price" value={price} onChange={e => setPrice(e.target.value)} />
      <label>Installments</label><input id="s-n" value={n} onChange={e => setN(e.target.value)} />
      <label>Interval (Sepolia blocks, multiple of 1000)</label><input id="s-int" value={interval} onChange={e => setInterval_(e.target.value)} />
      <label>Custody bond (tCTC — skip only with a clean seller passport)</label><input id="s-bond" value={bond} onChange={e => setBond(e.target.value)} />
      <button id="s-create" onClick={create}>Mint demo asset &amp; create order</button>
      <div id="s-out" className="mono">{out}</div>
    </section>
  );
}
