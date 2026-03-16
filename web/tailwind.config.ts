import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        // Primary brand — electric indigo with depth
        brand: {
          50: "#eef2ff",
          100: "#e0e7ff",
          200: "#c7d2fe",
          300: "#a5b4fc",
          400: "#818cf8",
          500: "#6366f1",
          600: "#4f46e5",
          700: "#4338ca",
          800: "#3730a3",
          900: "#312e81",
          950: "#1e1b4b",
        },
        // Surfaces — deep navy-black with blue undertone
        surface: {
          0: "#06070b",
          1: "#0c0d14",
          2: "#13141f",
          3: "#1a1c2b",
          4: "#232538",
          5: "#2d3048",
        },
        // Semantic accents
        accent: {
          green: "#34d399",
          red: "#f87171",
          amber: "#fbbf24",
          cyan: "#22d3ee",
          violet: "#a78bfa",
        },
        // Glass effect borders
        glass: {
          border: "rgba(255, 255, 255, 0.06)",
          highlight: "rgba(255, 255, 255, 0.03)",
        },
      },
      fontFamily: {
        sans: [
          "Inter",
          "-apple-system",
          "BlinkMacSystemFont",
          "system-ui",
          "sans-serif",
        ],
        mono: ["JetBrains Mono", "SF Mono", "Fira Code", "monospace"],
        display: ["Inter", "system-ui", "sans-serif"],
      },
      fontSize: {
        "display-xl": ["3.5rem", { lineHeight: "1.1", letterSpacing: "-0.02em", fontWeight: "700" }],
        "display-lg": ["2.5rem", { lineHeight: "1.15", letterSpacing: "-0.02em", fontWeight: "700" }],
        "display-md": ["2rem", { lineHeight: "1.2", letterSpacing: "-0.01em", fontWeight: "600" }],
        "display-sm": ["1.5rem", { lineHeight: "1.3", letterSpacing: "-0.01em", fontWeight: "600" }],
        "body-lg": ["1.125rem", { lineHeight: "1.6" }],
        "body-md": ["0.9375rem", { lineHeight: "1.6" }],
        "body-sm": ["0.8125rem", { lineHeight: "1.5" }],
        "caption": ["0.6875rem", { lineHeight: "1.4", letterSpacing: "0.02em" }],
        "overline": ["0.625rem", { lineHeight: "1.4", letterSpacing: "0.08em", fontWeight: "600" }],
      },
      borderRadius: {
        "2xl": "1rem",
        "3xl": "1.25rem",
        "4xl": "1.5rem",
      },
      spacing: {
        "18": "4.5rem",
        "88": "22rem",
      },
      boxShadow: {
        "glow-sm": "0 0 20px -5px rgba(99, 102, 241, 0.15)",
        "glow-md": "0 0 40px -10px rgba(99, 102, 241, 0.2)",
        "glow-lg": "0 0 60px -15px rgba(99, 102, 241, 0.25)",
        "glow-green": "0 0 30px -8px rgba(52, 211, 153, 0.2)",
        "glow-red": "0 0 30px -8px rgba(248, 113, 113, 0.2)",
        "elevation-1": "0 1px 3px rgba(0, 0, 0, 0.3), 0 1px 2px rgba(0, 0, 0, 0.2)",
        "elevation-2": "0 4px 12px rgba(0, 0, 0, 0.3), 0 2px 4px rgba(0, 0, 0, 0.2)",
        "elevation-3": "0 12px 40px rgba(0, 0, 0, 0.4), 0 4px 12px rgba(0, 0, 0, 0.2)",
      },
      backgroundImage: {
        "gradient-radial": "radial-gradient(var(--tw-gradient-stops))",
        "gradient-mesh":
          "radial-gradient(at 40% 20%, rgba(99, 102, 241, 0.08) 0px, transparent 50%), radial-gradient(at 80% 0%, rgba(34, 211, 153, 0.05) 0px, transparent 50%), radial-gradient(at 0% 50%, rgba(168, 85, 247, 0.05) 0px, transparent 50%)",
        "glass-gradient":
          "linear-gradient(135deg, rgba(255,255,255,0.03) 0%, rgba(255,255,255,0.01) 100%)",
      },
      animation: {
        "fade-in": "fadeIn 0.5s ease-out",
        "fade-up": "fadeUp 0.5s ease-out",
        "slide-in-right": "slideInRight 0.3s ease-out",
        "scale-in": "scaleIn 0.2s ease-out",
        "pulse-slow": "pulse 3s cubic-bezier(0.4, 0, 0.6, 1) infinite",
        "shimmer": "shimmer 2s linear infinite",
        "glow-pulse": "glowPulse 2s ease-in-out infinite alternate",
        "count-up": "countUp 0.8s ease-out",
      },
      keyframes: {
        fadeIn: {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
        fadeUp: {
          "0%": { opacity: "0", transform: "translateY(10px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        slideInRight: {
          "0%": { opacity: "0", transform: "translateX(-10px)" },
          "100%": { opacity: "1", transform: "translateX(0)" },
        },
        scaleIn: {
          "0%": { opacity: "0", transform: "scale(0.95)" },
          "100%": { opacity: "1", transform: "scale(1)" },
        },
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" },
        },
        glowPulse: {
          "0%": { opacity: "0.4" },
          "100%": { opacity: "1" },
        },
      },
      transitionTimingFunction: {
        "out-expo": "cubic-bezier(0.16, 1, 0.3, 1)",
      },
    },
  },
  plugins: [],
};

export default config;
