# Crux Protocol

Yield tokenization and rate market protocol on Sui. Crux splits yield-bearing assets into **Principal Tokens (PT)** and **Yield Tokens (YT)**, enabling fixed-rate products, leveraged yield exposure, and on-chain rate discovery.

Built for the [Sui Foundation Moonshots Program](https://sui.io/).

## The Problem

- No fixed-rate yield products on Sui — rates are entirely variable
- $1.7B+ locked in lending protocols earning only single-layer yield
- No on-chain yield curve or institutional-grade rate infrastructure
- Complex multi-step DeFi transactions with MEV risk

## How It Works

Crux decomposes yield-bearing assets into two tradeable components:

- **PT (Principal Token)** — A fixed-rate bond redeemable at maturity (e.g., buy 0.966 SY → get 1 SY in 6 months = 7.04% APY)
- **YT (Yield Token)** — Captures all variable yield until maturity (~29x leveraged exposure without liquidation risk)

Users deposit underlying tokens (e.g., SUI, haSUI) directly — the protocol handles SY conversion internally — and receive PT + YT in a single atomic transaction via Sui PTBs.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Frontend (Next.js)                       │
│   Dashboard · Trade · Mint · Earn · Portfolio · Tranches        │
├─────────────────────────────────────────────────────────────────┤
│                     Off-Chain Services                          │
│              Indexer (events) · Keeper (rates/settlement)       │
├─────────────────────────────────────────────────────────────────┤
│                    Move Smart Contracts                         │
│                                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌──────────────┐  │
│  │   Core   │  │  Markets  │  │ Routing  │  │  Governance  │  │
│  │ SY Vault │  │ Rate AMM  │  │  Router  │  │  veStaking   │  │
│  │Tokenizer │  │ Rate Swap │  │FlashMint │  │ Gauge Voting │  │
│  │          │  │ Orderbook │  │          │  │  Governor    │  │
│  │          │  │ Permless  │  │          │  │ Fee Collect  │  │
│  │          │  │           │  │          │  │  Multisig    │  │
│  └────┬─────┘  └─────┬─────┘  └────┬─────┘  └──────────────┘  │
│       │              │             │                            │
│  ┌────┴─────┐  ┌─────┴─────┐  ┌───┴────────┐  ┌───────────┐  │
│  │ Adapters │  │Structured │  │ Collateral │  │   Math    │  │
│  │  Haedal  │  │  Tranche  │  │PT Lending  │  │FixedPoint │  │
│  │ Suilend  │  │  Engine   │  │            │  │ AMM Math  │  │
│  │   NAVI   │  │           │  │            │  │           │  │
│  │ Scallop  │  └───────────┘  └────────────┘  └───────────┘  │
│  │  Cetus   │                                                  │
│  └──────────┘                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Smart Contracts (Move)

| Layer | Modules | Description |
|---|---|---|
| **Core** | `standardized_yield`, `yield_tokenizer`, `maturity_vault` | SY wrapping, PT/YT minting with real `Balance<T>` reserves |
| **Market** | `rate_market`, `rate_swap`, `orderbook_adapter`, `permissionless_market` | LogitNormal AMM, interest rate swaps, DeepBook integration |
| **Adapters** | `haedal`, `suilend`, `navi`, `scallop`, `cetus` | Yield source connectors with rate syncing |
| **Routing** | `router`, `flash_mint` | Multi-hop routing, flash mint/redeem for capital-efficient arb |
| **Structured** | `tranche_engine` | Senior/junior tranches with waterfall distribution |
| **Collateral** | `pt_collateral` | Borrow against PT positions with LTV-based lending |
| **Governance** | `crux_token`, `ve_staking`, `gauge_voting`, `governor`, `fee_collector`, `multisig_admin` | veCRUX staking, gauge-directed emissions, on-chain governance, multisig admin |
| **Oracle** | `rate_oracle`, `pyth_adapter` | TWAP rate feeds, Pyth price integration |
| **Math** | `amm_math`, `fixed_point` | WAD-scaled arithmetic with overflow protection |

### Security Features

- **AdminCap** access control on market creation and privileged operations
- **Real `Balance<T>` reserves** — PT/YT minting backed by actual underlying tokens, not virtual accounting
- **Overflow-checked math** — all WAD operations assert results fit in u128
- **Emission caps** — governance enforces max total emissions (100M CRUX)
- **Double-vote prevention** — per-epoch tracking prevents veCRUX vote manipulation
- **Position limits** — DoS protection with max position caps on collateral
- **Keeper timeout fallback** — permissionless settlement if keeper is offline >2 hours post-maturity
- **Package-internal access** — adapter rate updates and gauge creation restricted to internal calls
- **API rate limiting** — per-endpoint IP-based rate limits on all web routes

### Off-Chain Services

| Service | Description |
|---|---|
| **Web Frontend** | Next.js 14 dashboard with trading, minting, portfolio tracking, yield curve, and protocol metrics charts |
| **Indexer** | Event indexing and state syncing from Sui RPC |
| **Keeper** | Automated rate updates, maturity settlement, and analytics snapshots |

## Tech Stack

- **Contracts**: Move (Sui framework, edition 2024.beta)
- **Frontend**: Next.js 14, React 18, TypeScript, TailwindCSS, Recharts, Framer Motion
- **Wallet**: @mysten/dapp-kit
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
npm run dev                  # runs on port 3000
```

### Indexer

```bash
cd indexer
cp .env.example .env
npm install
npm run dev
```

### Keeper

```bash
cd keeper
cp .env.example .env
npm install
npm run dev
```

## Supported Yield Sources

| Protocol | Asset | Adapter | Type |
|---|---|---|---|
| Haedal | haSUI (staked SUI) | `haedal_adapter` | Liquid Staking |
| Suilend | Lending deposits | `suilend_adapter` | Lending |
| NAVI | Lending deposits | `navi_adapter` | Lending |
| Scallop | sCoins | `scallop_adapter` | Lending |
| Cetus | CLMM LP positions | `cetus_adapter` | DEX LP |

## Key Features

- **Fixed-Rate Yield** — Lock in guaranteed returns for any duration
- **Leveraged Yield** — 10-30x yield exposure without liquidation risk
- **Yield Curve** — First on-chain implied rate discovery on Sui
- **Atomic Execution** — Entire strategies in one transaction via Sui PTBs
- **Structured Tranches** — Senior (protected) and Junior (leveraged) tiers
- **Rate Swaps** — Pay-fixed / receive-variable interest rate derivatives
- **Permissionless Markets** — Anyone can create yield markets for compatible assets
- **PT Collateral** — Borrow against principal tokens with automated liquidation
- **Flash Mint** — Capital-efficient arbitrage via mint-and-repay in one transaction
- **Governance** — Vote-escrowed CRUX staking with gauge-directed emissions and multisig admin

## Project Structure

```
moonshot/
├── sources/              # Move smart contracts
│   ├── adapters/         # Yield source adapters (Haedal, Suilend, etc.)
│   ├── collateral/       # PT-backed lending
│   ├── core/             # SY vault, yield tokenizer, maturity vault
│   ├── governance/       # veCRUX, gauges, governor, fee collector, multisig
│   ├── market/           # Rate AMM, swaps, orderbook, permissionless markets
│   ├── math/             # Fixed-point WAD arithmetic, AMM math
│   ├── oracle/           # Rate oracle, Pyth adapter
│   ├── routing/          # Router, flash mint
│   └── structured/       # Tranche engine
├── tests/                # Move test suite
├── web/                  # Next.js frontend
├── indexer/              # Event indexer service
└── keeper/               # Keeper bot service
```

## License

Part of the Sui Foundation's Moonshots Program.
