/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        mono: ['"DM Mono"', 'monospace'],
        serif: ['Fraunces', 'serif'],
      },
      colors: {
        ghost: {
          bg: '#080705',
          card: '#0e0d0b',
          gold: '#d4a359',
          'gold-dark': '#b8872d',
          green: '#7ab87a',
          red: '#e07070',
          'text-primary': '#f0ede8',
          'text-secondary': '#a09890',
          'text-muted': '#5a5550',
          'text-dim': '#3a3530',
        }
      },
      animation: {
        'pulse-slow': 'pulse 2s ease-in-out infinite',
        'fade-up': 'fadeUp 0.6s ease both',
        'scan': 'scan 10s linear infinite',
        'ticker': 'ticker 20s linear infinite',
        'shimmer': 'shimmer 2s linear infinite',
      },
      keyframes: {
        fadeUp: {
          'from': { opacity: '0', transform: 'translateY(32px)' },
          'to': { opacity: '1', transform: 'translateY(0)' },
        },
        scan: {
          '0%': { transform: 'translateY(-100%)' },
          '100%': { transform: 'translateY(800%)' },
        },
        ticker: {
          '0%': { transform: 'translateX(0)' },
          '100%': { transform: 'translateX(-50%)' },
        },
        shimmer: {
          '0%': { backgroundPosition: '-200% center' },
          '100%': { backgroundPosition: '200% center' },
        },
      }
    },
  },
  plugins: [],
}
