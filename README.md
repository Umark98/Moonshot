# Crux Protocol

Yield tokenization and intent-based execution protocol for the Sui blockchain. Crux splits yield-bearing tokens into **Principal Tokens (PT)** and **Yield Tokens (YT)**, enabling fixed-rate products, leveraged yield exposure, and on-chain rate discovery.

## The Problem

- No fixed-rate yield products on Sui — rates are entirely variable
- $1.7B locked in lending protocols earning only single-layer yield
- Complex multi-step DeFi transactions with MEV risk
- No on-chain yield curve or institutional-grade rate infrastructure

## How It Works

Crux decomposes yield-bearing assets into two tradeable components:

- **PT (Principal Token)** — A fixed-rate bond redeemable at maturity (e.g., buy 0.966 SY → get 1 SY in 6 months = 7.04% APY)
- **YT (Yield Token)** — Captures all variable yield until maturity (~29x leveraged exposure without liquidation risk)

## Architecture

### Smart Contracts (Move)

| Layer | Modules |
|---|---|
| **Core** | `standardized_yield`, `yield_tokenizer`, `maturity_vault` |
| **Market** | `rate_market` (LogitNormal AMM), `orderbook_adapter` (DeepBook), `rate_swap`, `permissionless_market` |
| **Adapters** | `haedal`, `suilend`, `navi`, `scallop`, `cetus` |
| **Routing** | `router`, `flash_mint` |
| **Structured** | `tranche_engine` (senior/junior tranches) |
| **Governance** | `crux_token`, `ve_staking`, `gauge_voting`, `governor`, `fee_collector` |
| **Oracle** | `rate_oracle`, `pyth_adapter` |
| **Math** | `amm_math`, `fixed_point` |

### Off-Chain Services

- **Web Frontend** — Next.js 14 dashboard with trading UI, portfolio tracking, and yield curve visualization
- **Indexer** — Event indexing and state syncing from Sui
- **Keeper** — Automated rate updates, maturity settlement, and analytics snapshots

## Tech Stack

- **Contracts**: Move (Sui framework)
- **Frontend**: Next.js 14, React 18, TypeScript, TailwindCSS, Recharts
- **Database**: Prisma ORM + PostgreSQL
- **Blockchain SDK**: @mysten/sui

## Getting Started

### Prerequisites

- [Sui CLI](https://docs.sui.io/build/install)
- Node.js 18+
- PostgreSQL (or Supabase)

### Smart Contracts

```bash
sui move build
sui move test
```

### Web Frontend

```bash
cd web
cp .env.example .env.local  # fill in your values
npm install
npm run dev
```

### Indexer

```bash
cd indexer
cp .env.example .env  # fill in your values
npm install
npm run dev
```

### Keeper

```bash
cd keeper
cp .env.example .env  # fill in your values
npm install
npm run dev
```

## Supported Yield Sources

| Protocol | Asset | Adapter |
|---|---|---|
| Haedal | haSUI (staked SUI) | `haedal_adapter` |
| Suilend | Lending deposits | `suilend_adapter` |
| NAVI | Lending deposits | `navi_adapter` |
| Scallop | sCoins | `scallop_adapter` |
| Cetus | CLMM LP positions | `cetus_adapter` |

## Key Features

- **Fixed-Rate Yield** — Lock in guaranteed returns for any duration
- **Leveraged Yield** — 10-30x yield exposure without liquidation risk
- **Yield Curve** — First on-chain implied rate discovery on Sui
- **Atomic Execution** — Entire strategies in one transaction via Sui PTBs
- **Structured Tranches** — Senior (protected) and Junior (leveraged) tiers
- **Rate Swaps** — Pay-fixed / receive-variable interest rate derivatives
- **Permissionless Markets** — Anyone can create yield markets for compatible assets
- **Governance** — Vote-escrowed CRUX staking with gauge-directed emissions

## License

Part of the Sui Foundation's Moonshots Program.
