import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        bg: "#070A11",
        surface: {
          DEFAULT: "#101724",
          raised: "#171F2E",
        },
        border: {
          DEFAULT: "#1E2A3B",
          strong: "#2C3B4F",
        },
        ink: {
          DEFAULT: "#EAEFF5",
          dim: "#8A9AAE",
          faint: "#5C6E84",
        },
        cyan: {
          DEFAULT: "#1FF0D4",
          dim: "#12967F",
          wash: "#0C2E2A",
        },
        gold: {
          DEFAULT: "#FFB238",
          dim: "#A67A22",
          wash: "#2E2110",
        },
        violet: {
          DEFAULT: "#B98CFF",
          dim: "#7A5BAE",
          wash: "#211A33",
        },
        danger: {
          DEFAULT: "#FF6B6B",
          wash: "#2B1717",
        },
      },
      fontFamily: {
        display: ["var(--font-display)", "sans-serif"],
        body: ["var(--font-body)", "sans-serif"],
        mono: ["var(--font-data)", "monospace"],
      },
      borderRadius: {
        sm: "4px",
        DEFAULT: "6px",
        md: "8px",
        lg: "10px",
      },
      maxWidth: {
        content: "1240px",
      },
      keyframes: {
        "glow-pulse": {
          "0%, 100%": { opacity: "0.55" },
          "50%": { opacity: "1" },
        },
        "soft-rise": {
          from: { opacity: "0", transform: "translateY(6px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
      },
      animation: {
        "glow-pulse": "glow-pulse 2.2s ease-in-out infinite",
        "soft-rise": "soft-rise 0.35s ease-out",
      },
      boxShadow: {
        "glow-cyan": "0 0 0 1px rgba(31,240,212,0.25), 0 0 24px -4px rgba(31,240,212,0.35)",
        "glow-gold": "0 0 0 1px rgba(255,178,56,0.3), 0 0 28px -4px rgba(255,178,56,0.4)",
        "glow-violet": "0 0 0 1px rgba(185,140,255,0.25), 0 0 20px -6px rgba(185,140,255,0.35)",
      },
    },
  },
  plugins: [],
};

export default config;
