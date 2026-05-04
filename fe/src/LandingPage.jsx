import { useState, useEffect, useRef } from "react";

// ─── Redacted text with hover reveal ───────────────────────────────────────
function Redacted({ children, width = "auto" }) {
  const [revealed, setRevealed] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [showTooltip, setShowTooltip] = useState(false);
  const [tooltipFading, setTooltipFading] = useState(false);
  const [rectPos, setRectPos] = useState({ x: 0, w: 0 });
  const [charsRevealed, setCharsRevealed] = useState(0);
  const ref = useRef(null);

  const text = String(children);

  const handleMouseEnter = () => {
    setHovered(true);
    if (!revealed && !showTooltip && !tooltipFading) {
      setShowTooltip(true);
      setTimeout(() => {
        setTooltipFading(true);
        setTimeout(() => {
          setShowTooltip(false);
          setTooltipFading(false);
        }, 300);
      }, 2000);
    }
  };

  const handleMouseMove = (e) => {
    if (!ref.current) return;
    const bounds = ref.current.getBoundingClientRect();
    setRectPos({ x: e.clientX - bounds.left - 60, w: 120 });
  };

  const handleClick = () => {
    if (!revealed) {
      setRevealed(true);
      setShowTooltip(false);
      let count = 0;
      const interval = setInterval(() => {
        count++;
        setCharsRevealed(count);
        if (count >= text.length) clearInterval(interval);
      }, 40);
    }
  };

  return (
    <span
      ref={ref}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={() => setHovered(false)}
      onMouseMove={handleMouseMove}
      onClick={handleClick}
      className={`relative inline-block ${!revealed ? 'cursor-crosshair' : 'cursor-default'}`}
      style={{ width }}
    >
      {/* Revealed State */}
      {revealed && (
        <span className="relative text-ghost-gold whitespace-nowrap">
          {text.substring(0, charsRevealed)}
          {charsRevealed < text.length && (
            <span className="animate-pulse bg-ghost-gold w-[8px] h-[1em] inline-block ml-[2px] align-middle rounded-sm" />
          )}
        </span>
      )}

      {/* Redacted State */}
      {!revealed && (
        <span className="relative inline-block">
          {/* Black bar with scanline texture */}
          <span 
            className="inline-block bg-[#1a1810] rounded-sm px-1 text-transparent select-none tracking-widest transition-colors duration-100"
            style={{ 
              backgroundImage: 'repeating-linear-gradient(transparent 0px, transparent 2px, rgba(212,163,89,0.05) 2px, rgba(212,163,89,0.05) 3px)' 
            }}
          >
            {children}
          </span>

          {/* [classified] tooltip */}
          {showTooltip && (
            <span className={`absolute -top-8 left-1/2 -translate-x-1/2 bg-ghost-card border border-ghost-gold/20 text-ghost-gold text-[10px] uppercase tracking-widest px-2 py-1 rounded-sm pointer-events-none transition-opacity duration-300 ${tooltipFading ? 'opacity-0' : 'opacity-100'}`}>
              [classified]
            </span>
          )}

          {/* Hover window that "clears" the redaction */}
          {hovered && (
            <span 
              className="absolute top-0 h-full bg-ghost-gold/10 border border-ghost-gold/40 rounded-sm pointer-events-none mix-blend-screen flex items-center justify-center overflow-hidden backdrop-blur-none transition-all duration-200"
              style={{ left: `${rectPos.x}px`, width: `${rectPos.w}px` }}
            >
              <span className="text-[9px] text-ghost-gold tracking-widest font-mono whitespace-nowrap opacity-70">
                DECLASSIFY
              </span>
            </span>
          )}
        </span>
      )}
    </span>
  );
}

// ─── Mempool row (animated ciphertext vs plaintext) ─────────────────────────
function MempoolRow({ label, plain, cipher, isKey = false }) {
  const [show, setShow] = useState(false);
  useEffect(() => {
    const t = setTimeout(() => setShow(true), 600);
    return () => clearTimeout(t);
  }, []);

  return (
    <div 
      className={`grid grid-cols-[120px_1fr_1fr] md:grid-cols-[160px_1fr_1fr] gap-3 py-2 border-b border-white/5 items-center transition-opacity duration-400 ease-in ${show ? 'opacity-100' : 'opacity-0'}`}
    >
      <span className="text-[10px] text-ghost-text-muted font-mono break-all md:break-normal">{label}</span>
      <span className={`text-[11px] font-mono break-all md:break-normal ${isKey ? 'text-ghost-red bg-ghost-red/10 px-1.5 py-0.5 rounded-sm' : 'text-[#6a6258]'}`}>
        {plain}
      </span>
      <span className={`text-[11px] font-mono break-all md:break-normal ${isKey ? 'text-ghost-green bg-ghost-green/10 px-1.5 py-0.5 rounded-sm' : 'text-ghost-text-muted'}`}>
        {cipher}
      </span>
    </div>
  );
}

// ─── Section reveal on scroll ────────────────────────────────────────────────
function Reveal({ children, delay = 0 }) {
  const [visible, setVisible] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    const obs = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) { setVisible(true); obs.disconnect(); }
    }, { threshold: 0.15 });
    if (ref.current) obs.observe(ref.current);
    return () => obs.disconnect();
  }, []);

  return (
    <div 
      ref={ref} 
      className="transition-all duration-600 ease-out"
      style={{
        opacity: visible ? 1 : 0,
        transform: visible ? "translateY(0)" : "translateY(24px)",
        transitionDelay: `${delay}ms`
      }}
    >
      {children}
    </div>
  );
}

// ─── Main Landing Page ───────────────────────────────────────────────────────
export default function LandingPage({ onLaunchApp }) {
  const [mempoolTick, setMempoolTick] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => setMempoolTick(t => t + 1), 3000);
    return () => clearInterval(interval);
  }, []);

  const ciphers = [
    "0x3f8a2c...", "0x7b2e4f...", "0x1d9c83...", "0x4a71f2...", "0x9e3b5c...",
  ];
  const cipher = ciphers[mempoolTick % ciphers.length];

  return (
    <div className="min-h-screen bg-ghost-bg text-ghost-text-primary font-mono overflow-x-hidden">
      {/* Nav */}
      <nav className="fixed top-0 left-0 right-0 z-50 px-6 md:px-10 py-[18px] flex justify-between items-center bg-ghost-bg/85 backdrop-blur-md border-b border-white/5">
        <div className="flex items-center gap-[10px]">
          <span className="text-[20px] text-ghost-gold">👻</span>
          <span className="font-serif text-[18px] font-light tracking-[-0.02em]">
            Ghost<span className="text-ghost-gold">Swap</span>
          </span>
        </div>

        <div className="flex items-center gap-8">
          <div className="hidden md:flex items-center gap-8">
            {["Docs", "GitHub", "Discord"].map(link => (
              <a key={link} href="#" className="text-[11px] text-ghost-text-muted no-underline tracking-[0.06em] transition-colors duration-150 hover:text-ghost-text-secondary">
                {link}
              </a>
            ))}
          </div>
          <button
            onClick={onLaunchApp}
            className="bg-gradient-to-br from-ghost-gold to-ghost-gold-dark border-none rounded-sm px-5 py-[9px] text-ghost-card text-[11px] font-medium tracking-[0.08em] cursor-pointer uppercase transition-all duration-200 hover:brightness-110 hover:-translate-y-[1px] active:scale-[0.98]"
          >
            Launch App
          </button>
        </div>
      </nav>

      {/* Hero */}
      <section className="min-h-screen flex flex-col items-center justify-center pt-[120px] px-6 md:px-10 pb-[80px] relative overflow-hidden text-center">
        {/* Background glow */}
        <div className="absolute w-[600px] h-[600px] rounded-full top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none" 
             style={{ background: "radial-gradient(circle, rgba(212,163,89,0.07) 0%, transparent 70%)" }} />

        {/* Grid lines */}
        <div className="absolute inset-0 pointer-events-none"
             style={{
               backgroundImage: `linear-gradient(rgba(212,163,89,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(212,163,89,0.03) 1px, transparent 1px)`,
               backgroundSize: "60px 60px"
             }} />

        {/* Scanline */}
        <div className="absolute inset-0 overflow-hidden pointer-events-none opacity-[0.04]">
          <div className="absolute w-full h-[3px] bg-ghost-gold animate-scan" />
        </div>

        {/* Classified badge */}
        <div className="inline-flex items-center gap-2 border border-ghost-gold/30 rounded-sm px-3.5 py-1.5 mb-10 text-[10px] text-ghost-gold tracking-[0.15em] uppercase animate-fade-up">
          <span className="w-1.5 h-1.5 rounded-full bg-ghost-gold animate-pulse-slow inline-block" />
          Built on Fhenix CoFHE · Uniswap v4 · Arbitrum
        </div>

        {/* Main headline */}
        <h1 className="font-serif text-[48px] md:text-[clamp(48px,8vw,88px)] font-extralight leading-[1.05] tracking-[-0.03em] mb-6 animate-fade-up max-w-[800px]" style={{ animationDelay: '0.1s' }}>
          Your swap.
          <br />
          <span className="text-ghost-gold italic">Their blindspot.</span>
        </h1>

        {/* Subheadline with redacted text */}
        <p className="text-[15px] md:text-[clamp(15px,2vw,18px)] text-[#7a7068] max-w-[560px] leading-[1.7] mb-12 animate-fade-up" style={{ animationDelay: '0.2s' }}>
          The first swap interface where your{" "}
          <Redacted>reservation price</Redacted>
          {" "}is encrypted before it leaves your browser.
          Solvers fill your order without ever reading your minimum.
          Click the redacted text to reveal.
        </p>

        {/* CTA buttons */}
        <div className="flex gap-3 flex-wrap justify-center animate-fade-up" style={{ animationDelay: '0.3s' }}>
          <button
            onClick={onLaunchApp}
            className="bg-gradient-to-br from-ghost-gold to-ghost-gold-dark border-none rounded-sm px-9 py-4 text-ghost-card text-[13px] font-medium tracking-[0.1em] cursor-pointer uppercase transition-all duration-200 hover:brightness-110 hover:-translate-y-[1px] active:scale-[0.98]"
          >
            Swap Privately →
          </button>
          <button
            className="bg-transparent border border-white/10 rounded-sm px-9 py-4 text-[#7a7068] text-[13px] tracking-[0.1em] cursor-pointer uppercase transition-colors duration-150 hover:border-white/20 hover:text-ghost-text-secondary"
          >
            Read Docs
          </button>
        </div>

        {/* Scroll indicator */}
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 flex flex-col items-center gap-2 animate-fade-up" style={{ animationDelay: '0.8s' }}>
          <span className="text-[9px] text-ghost-text-dim tracking-[0.12em]">SCROLL</span>
          <div className="w-[1px] h-[40px] bg-gradient-to-b from-ghost-gold to-transparent animate-pulse-slow" />
        </div>
      </section>

      {/* Problem section — the two mempool panels */}
      <section className="py-[80px] md:py-[120px] px-6 md:px-10 max-w-[1000px] mx-auto">
        <Reveal>
          <div className="text-[10px] text-ghost-gold tracking-[0.15em] uppercase mb-4">
            The Problem
          </div>
          <h2 className="font-serif text-[32px] md:text-[clamp(32px,5vw,52px)] font-light tracking-[-0.02em] mb-4 leading-[1.1]">
            Every swap you've ever made{" "}
            <span className="text-ghost-red italic">leaked your price.</span>
          </h2>
          <p className="text-ghost-text-muted text-[15px] leading-[1.7] max-w-[560px] mb-12">
            Uniswap's <code className="text-ghost-text-secondary bg-white/5 px-1.5 py-[1px] rounded-sm">amountOutMinimum</code> is
            transmitted in plaintext. Solvers read your reservation price before filling your order — and fill you at exactly your worst acceptable price.
          </p>
        </Reveal>

        <Reveal delay={150}>
          {/* Mempool comparison */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {/* Regular Uniswap */}
            <div className="bg-ghost-red/5 border border-ghost-red/20 rounded-sm p-5">
              <div className="text-[10px] text-[#b43c3c] tracking-[0.1em] uppercase mb-4 flex items-center gap-1.5">
                ⚠ Standard Uniswap — Mempool Visible
              </div>
              <MempoolRow label="tokenIn" plain="0xC02aaa..." cipher="" isKey={false} />
              <MempoolRow label="amountIn" plain="1000000000000000000" cipher="" isKey={false} />
              <MempoolRow label="amountOutMinimum" plain="3198000000" cipher="" isKey={true} />
              <MempoolRow label="recipient" plain="0x742d...4f2b" cipher="" isKey={false} />
              <div className="mt-3.5 text-[11px] text-[#b43c3c] leading-[1.6]">
                ↑ Solver reads this. Fills you at 3,198 USDC. Pockets the difference.
              </div>
            </div>

            {/* GhostSwap */}
            <div className="bg-ghost-green/5 border border-ghost-green/20 rounded-sm p-5">
              <div className="text-[10px] text-ghost-green tracking-[0.1em] uppercase mb-4 flex items-center gap-1.5">
                ✓ GhostSwap — Encrypted Intent
              </div>
              {[
                { label: "tokenIn", val: "0xC02aaa...", key: false },
                { label: "amountIn", val: cipher, key: false },
                { label: "amountOutMinimum", val: "████████████", key: true },
                { label: "recipient", val: "0x742d...4f2b", key: false },
              ].map(row => (
                <div key={row.label} className="grid grid-cols-[120px_1fr] md:grid-cols-[160px_1fr] gap-3 py-2 border-b border-white/5 items-center">
                  <span className="text-[10px] text-ghost-text-muted font-mono break-all md:break-normal">{row.label}</span>
                  <span className={`text-[11px] font-mono break-all md:break-normal transition-colors duration-400 ${row.key ? 'text-ghost-green bg-ghost-green/10 px-1.5 py-0.5 rounded-sm' : 'text-ghost-text-muted'}`}>
                    {row.val}
                  </span>
                </div>
              ))}
              <div className="mt-3.5 text-[11px] text-ghost-green leading-[1.6]">
                ↑ Solver sees ciphertext. Cannot extract your reservation price. Fills honestly.
              </div>
            </div>
          </div>
        </Reveal>
      </section>

      {/* Stats ticker */}
      <div className="border-y border-white/5 py-5 overflow-hidden relative">
        <div className="flex gap-[80px] animate-ticker w-max">
          {[...Array(2)].map((_, i) => (
            <div key={i} className="flex gap-[80px] items-center">
              {[
                { val: "$500M+", label: "MEV extracted annually" },
                { val: "100%", label: "amountOutMinimum encrypted" },
                { val: "0 bytes", label: "readable mempool data" },
                { val: "11-24", label: "block reveal delay" },
                { val: "FHE", label: "cryptographic guarantee" },
              ].map(stat => (
                <div key={stat.label} className="flex items-center gap-5 whitespace-nowrap">
                  <span className="text-[20px] font-serif font-light text-ghost-gold">
                    {stat.val}
                  </span>
                  <span className="text-[11px] text-ghost-text-dim tracking-[0.06em] uppercase">
                    {stat.label}
                  </span>
                  <span className="text-[#2a2520] text-[18px]">·</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>

      {/* How it works */}
      <section className="py-[80px] md:py-[120px] px-6 md:px-10 max-w-[1000px] mx-auto">
        <Reveal>
          <div className="text-[10px] text-ghost-gold tracking-[0.15em] uppercase mb-4">
            How It Works
          </div>
          <h2 className="font-serif text-[32px] md:text-[clamp(32px,5vw,52px)] font-light tracking-[-0.02em] mb-16 leading-[1.1]">
            Four steps. Zero leakage.
          </h2>
        </Reveal>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-0.5">
          {[
            {
              n: "01",
              title: "Draft Intent",
              desc: "You enter your swap parameters. Your minimum price is encrypted client-side using Fhenix CoFHE before leaving your browser.",
              tag: "@cofhe/sdk encryptInputs()",
            },
            {
              n: "02",
              title: "Submit Encrypted",
              desc: "Your transaction hits the mempool as ciphertext. Front-running bots and solvers see an unreadable blob. There is nothing to front-run.",
              tag: "euint128 amountOutMinimum",
            },
            {
              n: "03",
              title: "FHE Settlement",
              desc: "The Uniswap v4 hook processes your encrypted intent. Solvers fill at their honest best price — they cannot see your floor to undercut it.",
              tag: "FHE.gt() onchain",
            },
            {
              n: "04",
              title: "Private Reveal",
              desc: "After 11-24 blocks, you call reveal. Only you — and optionally a compliance party — can decrypt the trade details using your permit key.",
              tag: "sealoutput(permit)",
            },
          ].map((step, i) => (
            <Reveal key={step.n} delay={i * 80}>
              <div
                className="bg-[#0e0d0b]/60 border border-white/5 p-8 relative transition-colors duration-200 hover:border-ghost-gold/25 hover:bg-ghost-gold/5"
              >
                <div className="text-[48px] font-serif font-extralight text-ghost-gold/10 absolute top-4 right-5 leading-none">
                  {step.n}
                </div>
                <div className="text-[11px] text-ghost-gold mb-3 tracking-[0.06em]">
                  {step.title}
                </div>
                <p className="text-[14px] text-[#7a7068] leading-[1.7] mb-5">
                  {step.desc}
                </p>
                <code className="text-[11px] text-ghost-text-muted bg-white/5 py-1 px-2.5 rounded-sm font-mono">
                  {step.tag}
                </code>
              </div>
            </Reveal>
          ))}
        </div>
      </section>

      {/* Tech stack */}
      <section className="py-[80px] px-6 md:px-10 border-t border-white/5 max-w-[1000px] mx-auto">
        <Reveal>
          <div className="text-[10px] text-ghost-text-dim tracking-[0.15em] uppercase mb-8 text-center">
            Built With
          </div>
          <div className="flex justify-center gap-6 md:gap-10 flex-wrap">
            {[
              { name: "Fhenix CoFHE", desc: "FHE coprocessor" },
              { name: "Uniswap v4", desc: "Hook architecture" },
              { name: "Arbitrum", desc: "L2 execution" },
              { name: "Foundry", desc: "Contract toolchain" },
            ].map(tech => (
              <div key={tech.name} className="text-center w-[120px] md:w-auto">
                <div className="text-[14px] text-ghost-text-secondary mb-1 font-medium">{tech.name}</div>
                <div className="text-[10px] text-ghost-text-dim tracking-[0.06em]">{tech.desc}</div>
              </div>
            ))}
          </div>
        </Reveal>
      </section>

      {/* CTA footer */}
      <section className="py-[120px] px-6 md:px-10 text-center relative overflow-hidden">
        <div className="absolute w-[400px] h-[400px] rounded-full top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none"
             style={{ background: "radial-gradient(circle, rgba(212,163,89,0.06) 0%, transparent 70%)" }} />

        <Reveal>
          <h2 className="font-serif text-[36px] md:text-[clamp(36px,6vw,64px)] font-extralight tracking-[-0.03em] mb-5 leading-[1.1]">
            Your{" "}
            <Redacted>amountOutMinimum</Redacted>
            <br />
            is no longer for sale.
          </h2>
          <p className="text-ghost-text-muted text-[15px] mb-10 leading-[1.6]">
            Hover the redacted text. Then try the app.
          </p>
          <button
            onClick={onLaunchApp}
            className="bg-gradient-to-br from-ghost-gold to-ghost-gold-dark border-none rounded-sm px-10 py-[18px] text-ghost-card text-[14px] font-medium tracking-[0.1em] cursor-pointer uppercase transition-all duration-200 shadow-[0_0_40px_rgba(212,163,89,0.2)] hover:brightness-110 hover:-translate-y-[1px] active:scale-[0.98]"
          >
            Launch GhostSwap →
          </button>
        </Reveal>
      </section>

      {/* Footer */}
      <footer className="border-t border-white/5 py-8 px-6 md:px-10 flex flex-col md:flex-row justify-between items-center gap-4 text-[10px] text-ghost-text-dim tracking-[0.06em]">
        <span>👻 GhostSwap — Privacy by math, not policy</span>
        <div className="flex gap-6 flex-wrap justify-center">
          {["Arbitrum Sepolia", "Fhenix CoFHE", "Uniswap v4"].map(t => (
            <span key={t}>{t}</span>
          ))}
        </div>
      </footer>
    </div>
  );
}
