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
        bg: "#0A0E14",
        surface: {
          DEFAULT: "#131A24",
          raised: "#1A2230",
        },
        border: {
          DEFAULT: "#232D3B",
          strong: "#2E3B4C",
        },
        ink: {
          DEFAULT: "#E7ECF2",
          dim: "#8493A6",
          faint: "#5A6B80",
        },
        cyan: {
          DEFAULT: "#2DE3C8",
          dim: "#1B8F7D",
          wash: "#0F2A28",
        },
        gold: {
          DEFAULT: "#F4B740",
          dim: "#9C7A2E",
          wash: "#2B2313",
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
    },
  },
  plugins: [],
};

export default config;
