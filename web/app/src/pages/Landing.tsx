import '../styles/landing.css';
import { Reveal } from '../components/landing/Reveal';
import { BrandMark } from '../components/dashboard/BrandMark';
import { MechanismCard } from '../components/landing/MechanismCard';
import { StatCard } from '../components/landing/StatCard';
import { Marquee } from '../components/landing/Marquee';
import { Dial } from '../components/landing/Dial';

const ARROW = <svg className="i" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6" /></svg>;
const ARROW_SM = <svg className="i" viewBox="0 0 24 24" style={{ width: 16 }}><path d="M5 12h14M13 6l6 6-6 6" /></svg>;

const RUNS_ON = ['USDC', 'Ethereum', 'Creditcoin', 'Attestcoin proofs'];
const PROMISES = ['PAY IN USDC', 'ON ETHEREUM', 'ESCROWED ON CREDITCOIN', 'NO MIDDLEMAN', 'NO HIDDEN FEES', 'NO LOCK-OUT BUTTON', 'PROOF OF EVERY PAYMENT'];

export function Landing() {
  return (
    <div id="top">
      <header>
        <div className="wrap">
          <nav className="nav">
            <a className="brand" href="#top"><BrandMark className="mark" />PayGo</a>
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
                <h1>Buy now, pay in installments - <span className="em">trust no one.</span></h1>
                <p className="hero-sub">The asset is escrowed on Creditcoin. You pay in stablecoin on Ethereum. Every installment counts only once it's <strong>proven by Attestcoin</strong> - miss one and the asset returns to the seller, on its own.</p>
                <div className="hero-cta">
                  <a className="btn btn-dark" href="#cta">Try the live checkout <span className="arc">{ARROW}</span></a>
                  <a className="btn btn-cream btn-sm" href="#acts">90-sec demo</a>
                </div>
              </div>
              <Dial />
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
        <Reveal className="reveal two">
          <div><div className="eyebrow">How it holds</div><h2 className="sec-h">Meet the mechanism.</h2></div>
          <p className="lead">You can't prove a payment <span className="muted">didn't</span> happen. So PayGo flips it: default is the resting state, and a proof of an on-time payment is the only thing that pushes it back.</p>
        </Reveal>
        <Reveal className="stagger cards">
          <MechanismCard variant="light"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><rect x="4" y="9" width="16" height="11" rx="2" /><path d="M8 9V6a4 4 0 018 0v3" /></svg>}
            title="Escrowed on Creditcoin" desc="The seller locks the asset in the contract. Nobody - not even us - holds a lockout button. It moves only on proof, or on default."
            tag="contract · not custody" />
          <MechanismCard variant="dark"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><path d="M12 2v20M17 5H9.5a3.5 3.5 0 000 7h5a3.5 3.5 0 010 7H6" /></svg>}
            title="Paid on Ethereum" desc="Each installment is paid in USDC where your money already lives - one-click permit, or sign once and autopay submits the rest."
            tag="permissionless" />
          <MechanismCard variant="dark"
            icon={<svg className="i" viewBox="0 0 24 24" style={{ width: 22 }}><path d="M12 3l7 4v5c0 4-3 7-7 9-4-2-7-5-7-9V7z" /><path d="M9 12l2 2 4-4" /></svg>}
            title="Proven by Attestcoin" desc="A Merkle inclusion proof of the payment is what the escrow accepts - verified on-chain in one block. No oracle, no keeper."
            tag="inclusion proof" />
        </Reveal>
        <Reveal className="reveal neg">
          <span><b>0</b> hidden fees</span><span><b>0</b> middlemen</span><span><b>0</b> credit checks</span><span><b>0</b> lock-out buttons</span>
          <span>miss a payment: the item goes back, <b>nothing more</b></span>
        </Reveal>
      </div></section>

      {/* PROOF */}
      <section id="proof"><div className="wrap">
        <Reveal className="reveal two">
          <div><div className="eyebrow">Simple numbers</div><h2 className="sec-h">No fine print. The rules are the same for everyone.</h2></div>
          <p className="lead"><span className="muted">Buy on terms, pay where your money already lives, and keep</span> proof of every payment<span className="muted"> you make. No account to open, no one to call.</span></p>
        </Reveal>
        <Reveal className="stagger stats">
          <StatCard hot value={15} suffix="%" label="deposit once you have a clean payment record. Newcomers start at 40%." />
          <StatCard value={1} unit="signature" label="at checkout. The remaining installments pay themselves, on time." />
          <StatCard prefix="~" value={10} unit="min" label="from your payment on Ethereum to its confirmation on Creditcoin. Automatic." />
          <StatCard value={0} label="people who can freeze, repossess or reprice your plan. Only the schedule decides." />
        </Reveal>
        <Reveal className="reveal backers">
          <div className="l">What you get,<br />in plain words.</div>
          <div className="mq"><Marquee items={PROMISES} /></div>
        </Reveal>
      </div></section>

      {/* USE CASES */}
      <section id="acts"><div className="wrap">
        <Reveal className="reveal two">
          <div><div className="eyebrow">PayGo in practice</div><h2 className="sec-h">Three acts. Nobody presses a button.</h2></div>
          <p className="lead"><span className="muted">Sign once at checkout - then close your laptop. The plan pays itself, and the chain keeps the receipts.</span></p>
        </Reveal>
        <div className="uc">
          <Reveal as="div" className="stagger uc-list">
            <div className="uc-item"><div className="step">ACT 01</div><h4>I buy on terms</h4><p>Pick an asset, pay a deposit sized by your credit passport - 40% for a newcomer, 15% with a clean record. The asset locks on Creditcoin.</p></div>
            <div className="uc-item"><div className="step">ACT 02</div><h4>It pays itself</h4><p>Each installment is paid on Ethereum and proven on Creditcoin. The schedule lights up, the passport grows - a casebook of payment facts.</p></div>
            <div className="uc-item"><div className="step">ACT 03</div><h4>I don't pay</h4><p>Miss a payment past the grace period and the item simply returns to the seller. What you already paid stays paid. No collector, no lock-out.</p></div>
          </Reveal>
          <Reveal className="reveal uc-big">
            <div className="aurora"><i className="a1"></i><i className="a2"></i></div><div className="grid"></div>
            <h3>A credit passport made of proofs.</h3>
            <p>Not a score. A record you own, where every line is a payment the chain itself verified. PayGo reads it to shrink your next deposit, from 40% down to 15%.</p>
            <a className="link-arrow" href="#cta"><span className="arc">{ARROW_SM}</span> See it in the checkout</a>
          </Reveal>
        </div>
      </div></section>

      {/* CTA */}
      <section id="cta"><div className="wrap">
        <Reveal className="reveal band">
          <div className="aurora"><i className="a1"></i><i className="a2"></i><i className="a3"></i></div><div className="grid"></div>
          <div className="eyebrow" style={{ letterSpacing: '.15em' }}>Sign once. The plan pays itself.</div>
          <h2>Buy in installments. Keep the proof. Trust no one.</h2>
          <p>Running today on the Creditcoin and Ethereum test networks. Open the checkout and watch an installment confirm live.</p>
          <div className="hero-cta">
            <a className="btn btn-cream" href="/dashboard/">Try the live checkout <span className="arc">{ARROW}</span></a>
            <a className="btn-ghost" href="#docs">Read the mechanism</a>
          </div>
        </Reveal>
      </div></section>

      <footer id="docs"><div className="wrap">
        <div className="foot">
          <div>
            <div className="brand" style={{ marginBottom: 8 }}><BrandMark className="mark" />PayGo</div>
            <div className="muted" style={{ fontSize: 13.5 }}>Installment purchases, secured by proof. Runs on Creditcoin and Ethereum.</div>
          </div>
          <div className="foot-links"><a href="#mechanism">Mechanism</a><a href="#proof">Proof</a><a href="#acts">Demo</a><a href="https://docs.creditcoin.org/attestcoin-protocol.md">How proofs work</a></div>
        </div>
      </div></footer>
    </div>
  );
}
