import type { Config } from "tailwindcss";

export default {
  darkMode: "media",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        app: {
          bg: "#FFFFFF",
          surface: "#F7F7F6",
          ink: "#1A1A1A",
          secondary: "#8A8A8A",
          muted: "#B0B0B0",
          border: "rgba(0,0,0,0.10)",
          darkBg: "#111110",
          darkSurface: "#1C1C1A",
          darkInk: "#F0EFEB",
          darkSecondary: "#888888",
          darkBorder: "rgba(255,255,255,0.10)"
        },
        sensor: {
          purple: "#7F77DD",
          teal: "#1D9E75",
          blue: "#378ADD",
          red: "#E24B4A",
          green: "#3B6D11",
          amber: "#B66B00"
        }
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "Fira Code", "monospace"]
      }
    }
  },
  plugins: []
} satisfies Config;
