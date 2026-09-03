import { useRef, useState } from 'react';
import { Contract, isAddress, parseEther } from 'ethers';
import { ImagePlus } from 'lucide-react';
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
  const [images, setImages] = useState<string[]>([]);
  const [imgDraft, setImgDraft] = useState('');
  const [imgError, setImgError] = useState('');
  const [drag, setDrag] = useState(false);
  const [showLink, setShowLink] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const [buyer, setBuyer] = useState('');
  const [price, setPrice] = useState('100');
  const [n, setN] = useState('4');
  const [interval, setInterval_] = useState('1000');
  const [bond, setBond] = useState('0.001');
  const [out, setOut] = useState<React.ReactNode>(null);

  // A dropped file has nowhere to live: the token stores a string, and this project hosts nothing. So the
  // photo is downscaled here and written into the token itself as a data URI — which is what "real on-chain
  // metadata" actually means. Storage costs ~20k gas per 32 bytes, hence the hard ceiling below.
  const MAX_URI = 12_000;

  async function fileToDataUri(file: File): Promise<string> {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, 320 / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    for (const q of [0.7, 0.5, 0.35, 0.2]) {
      const uri = canvas.toDataURL('image/jpeg', q);
      if (uri.length <= MAX_URI) return uri;
    }
    throw new Error('still too heavy after downscaling — use a link instead');
  }

  async function addFiles(files: FileList | File[] | null) {
    if (!files?.length) return;
    const added: string[] = [];
    for (const f of Array.from(files)) {
      if (!f.type.startsWith('image/')) continue;
      try { added.push(await fileToDataUri(f)); }
      catch (e) { setImgError(errMsg(e)); }
    }
    if (!added.length) return;
    const next = [...images, ...added.filter(u => !images.includes(u))];
    setImages(next);
    setAssetImage(added[added.length - 1]);
    setImgError('');
  }

  function onPaste(e: React.ClipboardEvent) {
    const f = Array.from(e.clipboardData.files).filter(x => x.type.startsWith('image/'));
    if (f.length) { e.preventDefault(); addFiles(f); return; }
    const text = e.clipboardData.getData('text').trim();
    if (/^(https?:\/\/|data:image\/)/.test(text)) { e.preventDefault(); setImgDraft(text); setShowLink(true); }
  }

  // The on-chain metadata carries ONE image, so the gallery is a shortlist you add to and pick from:
  // whichever thumbnail is selected is the one written to the token's tokenURI.
  function addImage() {
    const u = imgDraft.trim();
    if (!/^(https?:\/\/|data:image\/)/.test(u)) { setImgError('That is not an image link. It should start with https://'); return; }
    if (!images.includes(u)) setImages([...images, u]);
    setAssetImage(u);
    setImgDraft('');
    setImgError('');
  }

  function removeImage(u: string) {
    setImages(images.filter(x => x !== u));
    if (assetImage === u) setAssetImage(images.find(x => x !== u) ?? '');
  }

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
      <div className="desc">Put an item up on terms. It locks in escrow on Creditcoin and stays there until the last installment is proven, or until the buyer stops paying and it comes back to you. You set the price and the schedule; their passport sets the deposit.</div>
      {!me && <div className="empty-t">Connect a wallet to list.</div>}
      <div className="form-2">
        <fieldset>
          <legend>The item</legend>
          <label htmlFor="s-name">Name</label><input id="s-name" placeholder="e.g. 1978 Vespa" value={assetName} onChange={e => setAssetName(e.target.value)} />
          <label htmlFor="s-desc">Description</label><input id="s-desc" placeholder="optional" value={assetDesc} onChange={e => setAssetDesc(e.target.value)} />
          <label>Images</label>
          <div className={`dropzone${drag ? ' over' : ''}${images.length ? ' filled' : ''}`} tabIndex={0}
            aria-label="Photos of the item: drop, paste, or browse"
            onClick={images.length ? undefined : () => fileRef.current?.click()}
            onKeyDown={e => { if (!images.length && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); fileRef.current?.click(); } }}
            onDragOver={e => { e.preventDefault(); setDrag(true); }}
            onDragLeave={() => setDrag(false)}
            onDrop={e => { e.preventDefault(); setDrag(false); addFiles(e.dataTransfer.files); }}
            onPaste={onPaste}>
            {images.length ? (
              <div className="gallery">
                {images.map(u => (
                  <div className="thumb-wrap" key={u}>
                    <button type="button" title={u} aria-pressed={u === assetImage}
                      className={`thumb${u === assetImage ? ' on' : ''}`}
                      onClick={e => { e.stopPropagation(); setAssetImage(u); }}>
                      <img src={u} alt="" onError={e => (e.target as HTMLImageElement).classList.add('broken')} />
                    </button>
                    <button type="button" className="thumb-x" aria-label="Remove this photo"
                      onClick={e => { e.stopPropagation(); removeImage(u); }}>×</button>
                  </div>
                ))}
                <button type="button" className="thumb add" aria-label="Add more photos"
                  onClick={e => { e.stopPropagation(); fileRef.current?.click(); }}>
                  <ImagePlus aria-hidden="true" />
                </button>
              </div>
            ) : (
              <>
                <span className="dz-icon"><ImagePlus aria-hidden="true" /></span>
                <span className="dz-text">Add photos of the item</span>
                <span className="dz-sub">drop them here, click to browse, or paste</span>
              </>
            )}
          </div>
          <input ref={fileRef} type="file" accept="image/*" multiple hidden
            onChange={e => { addFiles(e.target.files); e.target.value = ''; }} />
          {showLink ? (
            <div className="row-add">
              <input id="s-image" placeholder="https://…" value={imgDraft} autoFocus
                onChange={e => setImgDraft(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addImage(); } }} />
              <button type="button" className="sec" onClick={addImage}>Add</button>
            </div>
          ) : (
            <button type="button" className="link-btn" onClick={() => setShowLink(true)}>or paste a link</button>
          )}
          <div className="gallery-hint">
            {imgError ? <span className="bad">{imgError}</span>
              : images.length ? 'Click a thumbnail to choose the one published with the item.'
              : 'Photos are shrunk and written into the token itself. Add as many as you like, publish one.'}
          </div>
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
            <div><label htmlFor="s-int">Time between installments <span className="mut">Ethereum blocks, ×1000</span></label><input id="s-int" value={interval} onChange={e => setInterval_(e.target.value)} /></div>
            <div><label htmlFor="s-bond">Custody bond (tCTC)</label><input id="s-bond" value={bond} onChange={e => setBond(e.target.value)} /></div>
          </div>
        </fieldset>
      </div>
      <button disabled={!me} onClick={create}>List it and lock it in escrow</button>
      <div className="out mono">{out}</div>
    </div>
  );
}
