import '../styles/landing.css';
import { Reveal, Stagger } from '../components/landing/Reveal';
import { MechanismCard } from '../components/landing/MechanismCard';
import { StatCard } from '../components/landing/StatCard';
import { RatioStatCard } from '../components/landing/RatioStatCard';
import { Marquee } from '../components/landing/Marquee';
import { MiniSchedule } from '../components/landing/MiniSchedule';

const ARROW = <svg className="i" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6" /></svg>;
const ARROW_SM = <svg className="i" viewBox="0 0 24 24" style={{ width: 16 }}><path d="M5 12h14M13 6l6 6-6 6" /></svg>;

const RUNS_ON = ['Attestcoin', 'Creditcoin CC3', 'Ethereum Sepolia', 'USDC', 'EIP-3009', 'ERC-5192'];
const PRIMITIVES = ['ATTESTCOIN BLOCKPROVER 0x0FD2', 'CHAININFO 0x0FD3', 'MERKLE INCLUSION', 'EIP-3009 RECEIVEWITHAUTHORIZATION', 'EIP-2612 PERMIT', 'ERC-5192 SOULBOUND', 'CONTINUITY PROOF'];

function BrandMark() {
  return (
    <svg className="mark" viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <rect className="rot" x="3" y="3" width="26" height="26" rx="8" stroke="#E9A21A" strokeWidth="2" />
      <circle cx="16" cy="16" r="4.4" fill="#E9A21A" />
    </svg>
  );
}

export function Landing() {
  return (
    <div id="top">
      <header>
        <div className="wrap">
          <nav className="nav">
            <a className="brand" href="#top"><BrandMark />PayGo</a>
            <div className="nav-links"><a href="#mechanism">Mechanism</a><a href="#proof">Proof</a><a href="#acts">Demo</a><a href="#docs">Docs</a></div>
            <a className="btn btn-dark btn-sm" href="#cta">Open checkout</a>
          </nav>
        </div>
      </header>

      {/* HERO */}
      <section className="hero">
        <div className="wrap">
          <div className="hero-card">
            <div className="aurora"><i className="a1"></i><i className="a2"></i><i className="a3"></i></div>
            <div className="mesh"></div>
            <div className="hero-in">
              <div>
                <h1>Buy now, pay in installments — <span className="em">trust no one.</span></h1>
                <p className="hero-sub">The asset is escrowed on Creditcoin. You pay in stablecoin on Ethereum. Every installment counts only once it's <strong>proven by Attestcoin</strong> — miss one and the asset returns to the seller, on its own.</p>
                <div className="hero-cta">
                  <a className="btn btn-dark" href="#cta">Try the live checkout <span className="arc">{ARROW}</span></a>
                  <a className="btn btn-cream btn-sm" href="#acts">90-sec demo</a>
                </div>
              </div>
              <div className="flow" aria-label="A payment on Ethereum, proven by Attestcoin, settles on Creditcoin">
                <div className="node">
                  <div className="node-h"><span className="chain">ETHEREUM · SEPOLIA</span><span className="diamond"></span></div>
                  <div className="row2"><span className="ic"><svg className="i" viewBox="0 0 24 24" style={{ width: 16 }}><path d="M12 2v20M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6" /></svg></span> payInstallment · <b>20.00 USDC</b></div>
                  <div className="row2 sub">emits InstallmentPaid</div>
                </div>
                <div className="beam">
                  <div className="rail"></div>
                  <div className="coin"></div>
                  <div className="lab"><svg className="i" viewBox="0 0 24 24" style={{ width: 13 }}><path d="M12 3l7 4v5c0 4-3 7-7 9-4-2-7-5-7-9V7z" /><path d="M9 12l2 2 4-4" /></svg>Attestcoin · inclusion proof</div>
                </div>
                <div className="node cc">
                  <div className="node-h"><span className="chain">CREDITCOIN · CC3</span><span className="badge ccbadge">escrow</span></div>
                  <div className="row2"><span className="ic"><svg className="i" viewBox="0 0 24 24" style={{ width: 16 }}><rect x="4" y="9" width="16" height="11" rx="2" /><path d="M8 9V6a4 4 0 018 0v3" /></svg></span> Asset #128 · <b>locked</b></div>
                  <MiniSchedule />
                  <div className="row2 sub">each proof advances the schedule → the asset releases on the last</div>
                </div>
              </div>
            </div>
            <div className="hero-brands">
              <div className="lab">RUNS ON</div>
              <div style={{ overflow: 'hidden' }}><Marquee items={RUNS_ON} /></div>
            </div>
          </div>
        </div>
      </section>

      {/* MECHANISM */}
      <section id="mechanism"><div className="wrap">
        <Reveal className="two">
          <div><div className="eyebrow">How it holds</div><h2 className="sec-h">Meet the mechanism.</h2></div>
          <p className="lead">You can't prove a payment <span className="muted">didn't</span> happen. So PayGo flips it: default is the resting state, and a proof of an on-time payment is the only thing that pushes it back.</p>
        </Reveal>
        <Stagger className="cards">
          <MechanismCard variant="light"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><rect x="4" y="9" width="16" height="11" rx="2" /><path d="M8 9V6a4 4 0 018 0v3" /></svg>}
            title="Escrowed on Creditcoin" desc="The seller locks the asset in the contract. Nobody — not even us — holds a lockout button. It moves only on proof, or on default."
            tag="contract · not custody" />
          <MechanismCard variant="dark"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><path d="M12 2v20M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6" /></svg>}
            title="Paid on Ethereum" desc="Each installment is paid in USDC where your money already lives — one-click permit, or sign once and autopay submits the rest."
            tag="permissionless" />
          <MechanismCard variant="dark"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><path d="M12 3l7 4v5c0 4-3 7-7 9-4-2-7-5-7-9V7z" /><path d="M9 12l2 2 4-4" /></svg>}
            title="Proven by Attestcoin" desc="A Merkle inclusion proof of the payment is what the escrow accepts — verified on-chain in one block. No oracle, no keeper."
            tag="inclusion proof" />
        </Stagger>
        <Reveal className="neg">
          <span><b>0</b> price oracles</span><span><b>0</b> keepers</span><span><b>0</b> liquidators</span><span><b>0</b> funds bridged</span>
          <span>the unhappy path costs <b>no gas</b> until someone wants the asset back</span>
        </Reveal>
      </div></section>

      {/* PROOF */}
      <section id="proof"><div className="wrap">
        <Reveal className="two">
          <div><div className="eyebrow">Proven, not promised</div><h2 className="sec-h">Measured on testnet. Real proofs, not estimates.</h2></div>
          <p className="lead"><span className="muted">Deadlines are quantized onto 1000-block epochs, so many installments settle under</span> one continuity proof<span className="muted">. Batching is the lever — and it's cheap.</span></p>
        </Reveal>
        <Stagger className="stats">
          <StatCard hot value={159912} sep unit="gas" label="per installment when four settle in one continuity proof" />
          <StatCard prefix="−" value={55} suffix="%" label="gas per installment vs. settling each one on its own" />
          <RatioStatCard a={0} b={76} label="projects in edition 1 that used the batch — PayGo is the first" />
          <StatCard value={5} label="security checks on every proof: nullifier, verify, receipt, emitter, fields" />
        </Stagger>
        <Reveal className="backers">
          <div className="l">Standing on the primitives<br />it actually uses — nothing bridged.</div>
          <div className="mq"><Marquee items={PRIMITIVES} /></div>
        </Reveal>
      </div></section>

      {/* USE CASES */}
      <section id="acts"><div className="wrap">
        <Reveal className="two">
          <div><div className="eyebrow">PayGo in practice</div><h2 className="sec-h">Three acts. Nobody presses a button.</h2></div>
          <p className="lead"><span className="muted">Sign once at checkout — then close your laptop. The plan pays itself, and the chain keeps the receipts.</span></p>
        </Reveal>
        <div className="uc">
          <Stagger as="div" className="uc-list">
            <div className="uc-item"><div className="step">ACT 01</div><h4>I buy on terms</h4><p>Pick an asset, pay a deposit sized by your credit passport — 40% for a newcomer, 15% with a clean record. The asset locks on Creditcoin.</p></div>
            <div className="uc-item"><div className="step">ACT 02</div><h4>It pays itself</h4><p>Each installment is paid on Ethereum and proven on Creditcoin. The schedule lights up, the passport grows — a casebook of payment facts.</p></div>
            <div className="uc-item"><div className="step">ACT 03</div><h4>I don't pay</h4><p>Silence past grace, asserted against the attested clock by anyone. The cure window passes, the asset returns to the seller. No liquidation.</p></div>
          </Stagger>
          <Reveal className="uc-big">
            <div className="aurora"><i className="a1"></i><i className="a2"></i></div><div className="grid"></div>
            <h3>A credit passport made of proofs.</h3>
            <p>Not a score — a soulbound record where every entry is an Attestcoin-verified installment. PayGo reads it back to shrink your next deposit. The founding mission of Creditcoin, rebuilt trustless.</p>
            <a className="link-arrow" href="#cta"><span className="arc">{ARROW_SM}</span> See it in the checkout</a>
          </Reveal>
        </div>
      </div></section>

      {/* CTA */}
      <section id="cta"><div className="wrap">
        <Reveal className="band">
          <div className="aurora"><i className="a1"></i><i className="a2"></i><i className="a3"></i></div><div className="grid"></div>
          <div className="eyebrow" style={{ letterSpacing: '.15em' }}>Signe une fois, le plan se paie tout seul</div>
          <h2>The default is the default state. The proof is what saves you.</h2>
          <p>Trustless cross-chain hire-purchase, running today on Creditcoin CC3 and Ethereum Sepolia. Open the checkout and watch an installment settle live.</p>
          <div className="hero-cta">
            <a className="btn btn-cream" href="/dashboard/">Try the live checkout <span className="arc">{ARROW}</span></a>
            <a className="btn-ghost" href="#docs">Read the mechanism</a>
          </div>
        </Reveal>
      </div></section>

      <footer id="docs"><div className="wrap">
        <div className="foot">
          <div>
            <div className="brand" style={{ marginBottom: 8 }}><BrandMark />PayGo</div>
            <div className="muted" style={{ fontSize: 13.5 }}>BUIDL CTC 2026 · Creditcoin × Attestcoin. Not a company — a protocol.</div>
          </div>
          <div className="foot-links"><a href="#mechanism">Mechanism</a><a href="#proof">Proof</a><a href="#acts">Demo</a><a href="https://docs.creditcoin.org/attestcoin-protocol.md">Attestcoin</a></div>
        </div>
      </div></footer>
    </div>
  );
}
