import type { Config } from "tailwindcss";

/** CLOG machine theme — direction 1a. Black glass & chrome; yellow = state + money. */
const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}", "./lib/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        void: "#050506",
        chassis: { 900: "#07070A", 800: "#0A0A0D", 700: "#0E0E11", 600: "#121216", 500: "#17171C", 400: "#1C1C21" },
        edge: { hard: "#33333A", soft: "#2E2E34", hair: "#26262C", inner: "#1B1B20" },
        chrome: { 100: "#D6D8DD", 200: "#C9CBD0", 300: "#8C8F97", 400: "#7E818A", 500: "#5A5A62" },
        ink: { 100: "#F2EFEA", 200: "#EFE6DA", 300: "#C9C6BF", 400: "#9A9790", 500: "#8F8C85", 600: "#8A877F" },
        /* hairlines only — never text (fails 4.5:1) */
        hairline: "#595753",
        bulb: "#FFF3D6",
        amber: { DEFAULT: "#FFC61A", dim: "#C9A227", cap: "#F3D585", travel: "#8A7130", ink: "#2A2318" },
        ok: "#7FD6A0",
        bad: "#FF6A4D",
      },
      fontFamily: {
        display: ["var(--font-display)", "'Archivo Black'", "sans-serif"],
        body: ["var(--font-body)", "Archivo", "sans-serif"],
        mono: ["var(--font-mono)", "'Space Mono'", "monospace"],
      },
      fontSize: {
        label: ["0.625rem", { lineHeight: "1", letterSpacing: "0.18em" }],
        meta: ["0.6875rem", { lineHeight: "1.3", letterSpacing: "0.12em" }],
        fig: ["1rem", { lineHeight: "1.2" }],
        "fig-lg": ["1.5rem", { lineHeight: "1.1" }],
      },
      backgroundImage: {
        "chassis-face": "linear-gradient(180deg,#1C1C21 0%,#101014 42%,#0A0A0D 100%)",
        "chassis-plate": "linear-gradient(180deg,#191920,#0D0D11)",
        "glass-body": "radial-gradient(130% 100% at 50% 0%, #15151A 0%, #0A0A0D 55%, #07070A 100%)",
        "glass-sheen": "linear-gradient(112deg, rgba(255,255,255,0.07) 0%, rgba(255,255,255,0) 32%)",
        "glass-scan": "repeating-linear-gradient(0deg, rgba(255,255,255,0.026) 0 1px, transparent 1px 4px)",
        "marquee-glow": "radial-gradient(120% 90% at 50% -30%, rgba(255,243,214,0.13), transparent 62%)",
        "cap-amber": "radial-gradient(60% 60% at 50% 30%, #FFF6DF, #F3D585)",
        "tear-band": "linear-gradient(90deg, rgba(255,60,60,.45), rgba(255,255,255,.7) 40%, rgba(60,220,255,.45))",
        "chrome-rod": "linear-gradient(#5A5A62,#8E8E96)",
        "prize-empty": "repeating-linear-gradient(135deg,#2A2A30 0 6px,#1E1E23 6px 12px)",
      },
      boxShadow: {
        chassis: "inset 0 1px 0 rgba(255,255,255,0.14), inset 0 -1px 0 rgba(0,0,0,0.6), 0 50px 100px -50px rgba(0,0,0,0.95)",
        display: "inset 0 3px 12px rgba(0,0,0,.9)",
        cap: "0 8px 0 #8A7130, 0 16px 26px -10px rgba(0,0,0,.9), inset 0 2px 0 rgba(255,255,255,.8)",
        "cap-down": "0 2px 0 #8A7130, inset 0 2px 0 rgba(255,255,255,.6)",
        prize: "inset 0 -7px 16px rgba(0,0,0,.26), 0 14px 24px -8px rgba(0,0,0,.85)",
      },
      animation: {
        "clog-marquee": "clog-marquee 38s linear infinite",
        "clog-lamp": "clog-lamp 2.4s ease-in-out infinite",
        "clog-lamp-fast": "clog-lamp 700ms ease-in-out infinite",
        "clog-hover": "clog-hover 4.2s ease-in-out infinite",
        "clog-sway": "clog-sway 6s ease-in-out infinite",
        "clog-hum": "clog-hum 260ms ease-in-out infinite",
        "clog-tear": "clog-tear 220ms linear 1 both",
        "clog-shake": "clog-shake 180ms linear 1",
        "clog-impact": "clog-impact 420ms cubic-bezier(.2,.8,.3,1) 1",
        "clog-flicker": "clog-flicker 600ms linear 1 both",
      },
    },
  },
  plugins: [],
};

export default config;
