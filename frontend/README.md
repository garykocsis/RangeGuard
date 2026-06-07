# RangeGuard Frontend Dashboard

React 18 + Vite + Tailwind SPA. Reads live Sepolia events via viem. No backend — all data from public Sepolia RPC calls.

## Run locally

```bash
npm install
npm run dev
# → http://localhost:5173
```

## Modes

- **Live:** `http://localhost:5173` — real on-chain data for the demo positionKey
- **Demo:** `http://localhost:5173/?demo=true` — simulated 45-day lifecycle (clearly labeled as Sepolia fork, not live data)
- **Any position:** `http://localhost:5173/?positionKey=0x...` — view any position in the pool

## Tech stack

- React 18 + Vite
- Tailwind CSS
- viem (no ethers.js)
- Public Sepolia RPC — no API key required

## Deploy

Vercel configuration:

- Framework preset: **Vite**
- Root directory: **frontend**
- Build command: **npm run build**
- Output directory: **dist**
- No environment variables needed
