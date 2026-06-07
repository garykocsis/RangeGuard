/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        // RangeGuard dark palette
        ink: {
          900: '#0a0e14',
          800: '#0f141d',
          700: '#161c28',
          600: '#1f2735',
          500: '#2b3445',
        },
        guard: {
          // brand accent (teal/green — "guard your range")
          400: '#34d399',
          500: '#10b981',
          600: '#059669',
        },
      },
      fontFamily: {
        mono: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'Monaco', 'monospace'],
      },
    },
  },
  plugins: [],
}
