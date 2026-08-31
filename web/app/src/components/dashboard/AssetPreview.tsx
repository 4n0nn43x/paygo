import type { AssetMeta } from '../../lib/assetMeta';

export function AssetPreview({ meta, tokenId }: { meta: AssetMeta | null; tokenId?: string | number }) {
  if (!meta) return null;
  return (
    <div className="asset-preview">
      {meta.image && <img src={meta.image} alt={meta.name} onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }} />}
      <div>
        <div className="asset-preview-name">{meta.name}{tokenId != null && <span className="mut"> · #{String(tokenId)}</span>}</div>
        {meta.description && <div className="asset-preview-desc">{meta.description}</div>}
      </div>
    </div>
  );
}
