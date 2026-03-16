# Crux Protocol — The Complete Story

## Written so anyone can understand it. Even a 5-year-old.

---

## PART 1 — THE PROBLEM (What's broken today?)

### Imagine you have a piggy bank...

You put $100 into your piggy bank at a bank. The bank says: "We'll give you some extra money for letting us hold yours." That extra money is called **yield** — it's like a thank-you gift.

But here's the problem:

**Problem 1: You never know how much you'll get.**

The bank keeps changing how much they give you. Monday it's 7 cents. Tuesday it's 3 cents. Friday it's 9 cents. You can never plan ahead. You can never say "I'll have exactly $107 at the end of the year." It changes every single day.

In the real crypto world, this is what happens on Sui blockchain right now. There are big "piggy banks" called **lending protocols** — Suilend ($745 million), NAVI ($723 million), and Scallop ($244 million). Together they hold over **$1.7 billion** of people's money. And every single person earning yield on these protocols has the same problem: the rate changes every day. Nobody can plan. Nobody can lock in a guaranteed rate.

**Problem 2: Your money just sits there doing nothing extra.**

When you put money in a piggy bank, that's ALL it does. It sits there. It earns that one thank-you gift. Nothing else.

But what if your piggy bank could ALSO be used as proof that you have money? Like a permission slip that says "I have $100 in the bank" — and you could use that permission slip to do OTHER things at the same time?

Right now on Sui, $1.7 billion is sitting in lending protocols doing ONE thing. Just earning that one variable rate. That money could be working 3-4 times harder if the right tools existed.

**Problem 3: Doing anything smart with your money is way too hard.**

Imagine you want to:
1. Take your coins
2. Put them in a piggy bank
3. Get a receipt
4. Use that receipt to do something else
5. And maybe one more thing

On Ethereum (another blockchain), each of those steps is a SEPARATE trip to the bank. You walk to the bank, do step 1, walk home, walk back, do step 2, walk home again... And between each trip, someone might steal your candy (that's called MEV — other people sniping your transaction).

On Sui, there's a magic ability called **PTBs (Programmable Transaction Blocks)** that lets you do ALL of those steps in ONE trip. ONE transaction. Nobody can steal anything in between because it all happens at once. Like blinking — it's that fast.

But here's the thing: **nobody has built the tools to actually USE this superpower.** Sui has the best engine in the world, but nobody built a car for it yet.

**Problem 4: You need a PhD to use DeFi.**

If you're a normal person and you hear "swap your SY tokens to PT on the LogitNormal AMM with 0.5% slippage" — your brain melts. That's how DeFi talks to people right now.

What you ACTUALLY want to say is: **"Make my money grow. Safely. Tell me exactly how much I'll get."**

Nobody on Sui lets you say that. Every app asks you WHAT FUNCTION to call. Nobody asks you WHAT YOU WANT.

---

## PART 2 — WHAT CRUX IS (Our Solution)

### The Simple Version

Crux is like a **super-smart financial assistant for the Sui blockchain.**

It does two things:

**Thing 1: It splits your yield into two pieces.**

Remember that "thank you" money the bank gives you? Crux takes your deposit and splits it into two special tokens:

- **PT (Principal Token)** — This is your "I'll definitely get my money back" token. It's like a coupon that says "trade this in on June 1st and get $100." If you buy it for $96 today, you KNOW you'll make $4. Guaranteed. No surprises. No "maybe." $4.

- **YT (Yield Token)** — This is your "I get all the thank-you gifts" token. It collects ALL the variable yield until maturity. If rates go up, you make a LOT. If rates go down, you make less. It's the exciting, risky one.

Right now, your deposit is stuck as ONE thing. Crux SPLITS it. Now you can:
- Keep the safe part (PT) and sell the risky part (YT) to someone who wants it
- Keep the risky part and sell the safe part
- Keep both
- Use the safe part as collateral to borrow more

**Thing 2: It lets you just say what you want.**

Instead of "swap my SY tokens on pool 0x3f2a..." you just say:

- "Earn me 7% fixed for 6 months"
- "Get the best yield for my 10,000 haSUI"
- "Exit all my positions that expire next month"

Crux's **intent engine** figures out the best way to do it, builds one atomic transaction, and you just click "confirm." Done.

### The Real-World Analogy

Think of Crux like **a kitchen that takes raw ingredients and makes two dishes:**

- Your raw ingredient = a yield-bearing token (like haSUI from staking)
- Dish 1 (PT) = a guaranteed fixed-rate bond. Safe. Predictable. Like a savings account.
- Dish 2 (YT) = a leveraged yield bet. Exciting. Variable. Like a stock option.

And the kitchen also has a **waiter** (intent engine) who just asks: "What would you like tonight?" instead of making you walk into the kitchen and cook it yourself.

---

## PART 3 — WHY WE CHOSE THIS PRODUCT (And Not the Others)

We evaluated 8 possible products for the Sui Moonshots Program. Here's why Crux won:

### The Candidates

| # | Product Idea | What It Does |
|---|-------------|-------------|
| 1 | **Yield Tokenization + Intent Engine (Crux)** | Split yield into PT/YT tokens, intent-based execution |
| 2 | Intent-Based DeFi Execution Engine (standalone) | Users say what they want, protocol finds best route |
| 3 | DeFi Insurance Marketplace | Buy/sell protection against smart contract hacks |
| 4 | Liquidity Leasing Protocol | Rent liquidity instead of locking capital |
| 5 | On-Chain Structured Products | Hedge fund strategies packaged as tokens |
| 6 | DeFi Credit Score Layer | Reputation-based undercollateralized lending |
| 7 | Cross-Margin Engine | Shared margin across protocols |
| 8 | Programmable Vaults (Yearn-style) | Auto-compounding yield vaults |

### Why Each Alternative Was Rejected

**Option 2 — Intent Execution Engine (standalone):**
Rejected as standalone because: an intent engine without a unique underlying product is just a routing layer. CoW Protocol on Ethereum proved this — routers become commodities. Anyone can copy a router. But if the intent engine routes INTO your own unique yield infrastructure (PT/YT, tranches, rate swaps) that nobody else has, THEN it becomes a moat. That's why we MERGED intents into Crux instead of building them separately.

**Option 3 — DeFi Insurance Marketplace:**
Rejected because: insurance requires actuarial expertise (pricing risk correctly), massive capital reserves, and has proven difficult in crypto. Nexus Mutual on Ethereum has struggled despite years of operation. The market is real but: (a) not a small-team project, (b) no Sui-specific advantage, (c) unproven product-market fit in crypto.

**Option 4 — Liquidity Leasing Protocol:**
Rejected because: completely unproven model. Nobody has successfully launched this in DeFi. While the idea is interesting, the Moonshots Program values "proven PMF" — and yield tokenization has $8.9B of proof on Ethereum. Liquidity leasing has $0. Too risky for a program application.

**Option 5 — On-Chain Structured Products:**
Not rejected — **absorbed into Crux.** Our tranche engine IS structured products. Senior tranche = fixed rate + protection. Junior tranche = leveraged yield. This is literally "hedge fund strategies packaged as tokens" — but integrated into the yield tokenization infrastructure instead of built standalone.

**Option 6 — DeFi Credit Score Layer:**
Rejected because: (a) massive Sybil attack surface (people create fake wallets with good history), (b) requires enormous data infrastructure, (c) regulatory risk, (d) no Sui-specific advantage, (e) fundamentally hard problem that nobody has solved despite many attempts (Spectral, Arcx, etc.).

**Option 7 — Cross-Margin Engine:**
Rejected because: requires coordination with existing lending/perps protocols who have no incentive to share margin. Political problem, not technical. Not feasible for a small team.

**Option 8 — Programmable Vaults:**
Rejected because: Yearn Finance already proved this model, and it's been replicated hundreds of times. Not novel. Not a "moonshot." Would not qualify as a new financial primitive.

### The Scorecard

| Criterion | Crux | Intents Only | Insurance | Leasing | Structured | Credit | Margin | Vaults |
|-----------|---------|-------------|-----------|---------|-----------|--------|--------|--------|
| Novel Primitive | ★★★★★ | ★★★ | ★★★ | ★★★★ | ★★★ | ★★★ | ★★ | ★ |
| Proven PMF | ★★★★★ | ★★★ | ★★ | ★ | ★★★ | ★ | ★★ | ★★★★ |
| Small Team OK | ★★★★★ | ★★★★ | ★★ | ★★★ | ★★★ | ★ | ★ | ★★★★ |
| Sui Advantage | ★★★★★ | ★★★ | ★★ | ★★★ | ★★★ | ★ | ★★ | ★★ |
| Capital Efficiency | ★★★★★ | ★★ | ★ | ★★★ | ★★★ | ★★★★ | ★★★★ | ★★ |
| **Total** | **25/25** | **16/25** | **12/25** | **14/25** | **15/25** | **10/25** | **11/25** | **13/25** |

### The Winning Formula

Crux didn't just pick ONE idea. It **combined the three strongest concepts:**

1. **Yield Tokenization** (proven $8.9B market) — the core primitive
2. **Structured Products** (tranches) — absorbed as a feature
3. **Intent Execution** (UX breakthrough) — absorbed as the interface layer

This combination is why Crux scores 25/25. No other single idea can match it.

---

## PART 4 — WHAT ISSUES DOES CRUX RESOLVE?

### Issue 1: "I can't get a fixed rate on Sui" → RESOLVED

**Before Crux:** Every yield on Sui is variable. If you stake SUI to get haSUI, you might earn 7% today and 3% tomorrow. You can NEVER plan ahead. Institutions won't touch this — they need predictable returns.

**After Crux:** Buy PT-haSUI at a discount. If 6-month PT costs 0.966 SY, you're locking in 7.04% APY. Guaranteed. No matter what happens to rates. It's like a bond — you know exactly what you'll get at maturity.

**Who benefits:** Conservative investors, institutions, treasuries, anyone who needs predictable income.

### Issue 2: "I can't get leveraged yield exposure" → RESOLVED

**Before Crux:** If you want more yield exposure, your only option is to borrow and re-deposit (looping). This creates liquidation risk and is capital-inefficient.

**After Crux:** Buy YT tokens. If YT costs 0.034 SY, you're getting ~29x leveraged exposure to variable yield. No borrowing. No liquidation risk. If rates go up, you make 29x the gains.

**Who benefits:** Yield speculators, active traders, degens who want leverage without liquidation.

### Issue 3: "$1.7B sits idle in single-layer yield" → RESOLVED

**Before Crux:** Money in Suilend earns Suilend rate. That's it. One layer. One activity.

**After Crux:** That same money earns underlying yield (layer 1), creates a tradeable yield market (layer 2), PT gets used as collateral elsewhere (layer 3), and LP positions earn trading fees (layer 4). **3-4x more productive per dollar.**

**Who benefits:** Every LP, every protocol, the entire Sui ecosystem.

### Issue 4: "No rate discovery on Sui" → RESOLVED

**Before Crux:** Each lending protocol shows its own rate. Nobody knows the "real" market rate for haSUI yield. There's no yield curve. Institutions can't price duration risk.

**After Crux:** Crux's AMM creates a live yield curve — the price of PT at different maturities reveals what the market thinks rates will be in 1 month, 3 months, 6 months, 1 year. This is the first on-chain rate discovery mechanism on Sui. Every other protocol can reference it.

**Who benefits:** Institutional capital, protocol risk managers, rate traders, the entire DeFi ecosystem.

### Issue 5: "DeFi UX is terrible — too many steps" → RESOLVED

**Before Crux:** To get leveraged yield exposure, a user must: understand 4 protocols, execute 3-5 transactions, manage slippage at each step, compare rates manually, and monitor positions across multiple dashboards.

**After Crux:** User says "maximize my yield on haSUI with medium risk." Crux's intent engine evaluates all options, builds one atomic PTB, user clicks confirm. Done.

**Who benefits:** New DeFi users, mainstream crypto users, anyone who doesn't want to be a "DeFi expert."

### Issue 6: "Yield strategies require 5+ transactions with MEV risk" → RESOLVED

**Before Crux (on Ethereum):** Each step is a separate transaction. Between steps, MEV bots can front-run you, sandwich you, or manipulate prices.

**After Crux (on Sui):** PTBs make the entire strategy ONE atomic transaction. All-or-nothing. No MEV between steps. No partial execution. Like snapping your fingers — either everything happens or nothing does.

**Who benefits:** Everyone. This is a Sui-specific superpower that Crux fully utilizes.

### Issue 7: "No risk-adjusted yield products on Sui" → RESOLVED

**Before Crux:** Every yield product treats all users the same. Want lower risk? Tough luck, you get the same variable rate as everyone else.

**After Crux:** Structured tranches let you choose your risk profile:
- **Senior tranche**: You get paid first. Lower rate (5%) but protected. Junior absorbs losses before you're affected.
- **Junior tranche**: You get the leftovers after senior is paid. Higher potential returns (18%+) but first-loss risk. Up to 4x leverage on yield.

**Who benefits:** Risk-conscious investors (senior), yield-hungry traders (junior), institutions who need risk-adjusted products.

### Issue 8: "No unified view of my Sui DeFi positions" → RESOLVED

**Before Crux:** Positions scattered across Suilend, NAVI, Scallop, Cetus. No single dashboard shows total exposure, total yield, or upcoming maturities.

**After Crux:** Portfolio page shows ALL positions (PT, YT, LP, tranches, collateral) in one view with P&L tracking, maturity timeline, and projected earnings.

**Who benefits:** Active DeFi users who use multiple protocols.

### Issue 9: "Liquidity is fragmented across Sui DEXes" → RESOLVED

**Before Crux:** $700M+ DEX liquidity split across Cetus, DeepBook, Aftermath, Turbos. Users manually compare prices.

**After Crux:** The router automatically splits orders across AMM + DeepBook for best execution. Intent engine aggregates all yield sources. One interface, optimal routing.

**Who benefits:** Traders who want best execution without comparing 4+ DEXes.

### Issue 10: "AMMs aren't designed for rate trading" → RESOLVED

**Before Crux:** Standard AMMs (constant product, x*y=k) are designed for token prices, not interest rates. They suffer high slippage on rate trades, especially near maturity.

**After Crux:** LogitNormal AMM is purpose-built for rates. It concentrates liquidity around the current implied rate, automatically tightens as maturity approaches, and delivers **5x better execution** than constant-product AMMs for equivalent trade sizes.

**Who benefits:** Rate traders, LPs (tighter spreads = more volume = more fees), large traders.

---

## PART 5 — WHAT ARE WE COVERING? (The Full Product Suite)

### Layer 1: Yield Infrastructure (The Engine)

| Product | What It Does | For Whom |
|---------|-------------|----------|
| **Standardized Yield (SY)** | Wraps any yield-bearing token (haSUI, sTokens, etc.) into a standard format | Developers, protocol integrators |
| **PT/YT Tokenization** | Splits SY into fixed-rate (PT) and variable-rate (YT) tokens | All users |
| **Rate AMM** | Purpose-built AMM for trading PT/SY, creating the yield curve | Traders, LPs |
| **DeepBook Integration** | CLOB limit orders for institutional-grade PT/YT trading | Institutions, large traders |
| **Flash Mint** | Atomically mint PT+YT for arbitrage or leverage without upfront capital | Arbitrageurs, advanced traders |

### Layer 2: Advanced Products (The Products)

| Product | What It Does | For Whom |
|---------|-------------|----------|
| **Fixed-Rate Earn** | One-click deposit → guaranteed fixed yield via PT purchase | Conservative investors |
| **Leveraged Yield** | Buy YT for ~10-30x yield exposure without liquidation risk | Yield speculators |
| **Structured Tranches** | Senior (protected) + Junior (leveraged) yield tranching | Risk-adjusted investors |
| **Interest Rate Swaps** | Pay-fixed/receive-variable or vice versa | Institutional hedging |
| **PT as Collateral** | Use PT tokens as collateral in lending, with time-dependent LTV (70%→95%) | Capital-efficient users |

### Layer 3: Execution & Access (The Interface)

| Product | What It Does | For Whom |
|---------|-------------|----------|
| **Intent Engine** | "What do you want?" → protocol finds optimal path → one-click execution | Everyone, especially beginners |
| **Router** | Atomic multi-step strategies in a single PTB | Power users, programs |
| **Rate Oracle** | TWAP-based implied rate oracle — public good for Sui ecosystem | Other protocols |
| **Permissionless Markets** | Anyone can create a yield market for any SY-compatible asset | Ecosystem builders |

### Layer 4: Governance & Token (The Ecosystem)

| Product | What It Does | For Whom |
|---------|-------------|----------|
| **CRUX Token** | Governance, fee sharing, emission boosting | Protocol participants |
| **veCRUX Staking** | Lock 1-4 years → share of protocol fees + boosted emissions | Long-term supporters |
| **Gauge Voting** | Direct CRUX emissions to specific pools | Protocols competing for liquidity |
| **On-Chain Governor** | Proposals, voting, timelock execution | DAO participants |

### Protocol Adapters (Sui Ecosystem Integration)

| Adapter | Connects To | What It Wraps |
|---------|------------|---------------|
| Haedal | haSUI staking | Staked SUI → SY |
| Suilend | Suilend lending | Lending deposits → SY |
| NAVI | NAVI lending | Lending deposits → SY |
| Scallop | Scallop lending | sCoins → SY |
| Cetus | Cetus CLMM | LP positions → SY |

**Total coverage: 5 yield sources, 4 product layers, 25 smart contract modules, 130 tests.**

---

## PART 6 — WHAT ARE THE EXPECTATIONS?

### For the Moonshots Program

| Milestone | When | What We Deliver | Success Metric |
|-----------|------|----------------|----------------|
| Application | Now | Working testnet + 25 modules + full frontend | Accepted into program |
| Testnet Live | Month 2 | haSUI yield tokenization, Earn page, basic intents | 500+ testnet users |
| Security Audit #1 | Month 3-4 | Core modules (SY, Tokenizer, AMM) audited by OtterSec/MoveBit | Clean audit report |
| Mainnet Launch | Month 5 | Guarded launch with $1M TVL cap, 3 adapters | $10M TVL within 30 days |
| Multi-Asset | Month 6 | All 5 adapters live, 4 maturity options | $25M TVL |
| Tranches + Token | Month 8 | Structured products, CRUX TGE, veCRUX | $50M TVL |
| Intent Engine | Month 10 | Full intent-based interface, Strategy Builder | 30% of txs via intents |
| Revenue Positive | Month 12 | Fee revenue > emission value | $100M TVL, $1.47M annual rev |

### What We Need From Moonshots

| Ask | Why |
|-----|-----|
| $500K growth incentives | Bootstrap liquidity mining for first 6 months |
| Audit credits (2 cycles) | Security is non-negotiable for yield infrastructure |
| DeepBook engineering support | PT/YT order book integration requires DeepBook team collaboration |
| Protocol introductions | Adapter validation with Suilend, NAVI, Scallop, Haedal teams |
| Co-marketing | Mainnet launch amplification |

### What Sui Ecosystem Gets

| Benefit | Impact |
|---------|--------|
| **First yield curve on Sui** | Every protocol can reference market-discovered rates |
| **Fixed-rate products** | Unlocks conservative/institutional capital ($100B+ addressable market) |
| **3-4x capital efficiency** | $1.7B in lending becomes 3-4x more productive |
| **New TVL** | Yield markets create net-new TVL, not just TVL migration |
| **Intent execution showcase** | Demonstrates Sui's PTB advantage over all other chains |
| **Rate oracle (public good)** | Free rate feed for any Sui protocol to use |
| **Yield Wars flywheel** | Protocols buy veCRUX to direct emissions → creates sticky demand for CRUX |

### Financial Projections (Conservative)

| Metric | Month 6 | Month 12 | Month 24 |
|--------|---------|----------|----------|
| TVL | $25M | $100M | $250M |
| Monthly Volume | $15M | $80M | $200M |
| Monthly Revenue | $40K | $120K | $300K |
| Annual Revenue Run Rate | $480K | $1.47M | $3.6M |
| Active Users (monthly) | 2,000 | 8,000 | 25,000 |
| Yield Markets Created | 8 | 20 | 50+ |

### Long-Term Vision (2+ Years)

**Year 1:** Crux becomes Sui's yield infrastructure — the Pendle of Sui. Fixed rates, yield curve, tranches.

**Year 2:** Crux becomes Sui's yield EXECUTION layer — intent engine routes all yield-seeking capital. Rate oracle becomes the reference standard. Permissionless markets enable any protocol to create PT/YT for their tokens.

**Year 3:** Crux becomes DeFi's cross-chain rate market — bridging yield curves across Sui, Ethereum, and other chains. Interest rate derivatives (futures, options) build on top. Institutional API serves hedge funds and treasuries.

**The end state:** Every dollar on Sui that earns yield flows through Crux. Not because users are forced to — but because Crux gives them better rates, better execution, and better UX than any alternative.

---

## PART 7 — THE ONE-PARAGRAPH SUMMARY

**Crux Protocol splits yield-bearing Sui assets into tradeable Principal (PT) and Yield (YT) tokens — creating fixed-rate products, leveraged yield, structured tranches, and Sui's first on-chain yield curve. Combined with an intent-based execution engine ("tell us what you want, we'll build the transaction"), Crux transforms $1.7B of static lending deposits into 3-4x more productive capital. Built on Sui's PTBs for atomic multi-step execution impossible on any other chain, backed by a LogitNormal AMM purpose-built for rate trading, and integrated with Suilend, NAVI, Scallop, Haedal, and Cetus. 25 Move smart contracts. 130 tests. Full Next.js frontend. Ready for testnet.**

---

## PART 8 — GLOSSARY (Because DeFi Loves Jargon)

| Term | Simple Explanation |
|------|-------------------|
| **PT (Principal Token)** | A coupon that guarantees you get your money back at a specific date. Buy it cheap now, get full price later = your profit is the difference. |
| **YT (Yield Token)** | A ticket that collects all the "thank you" gifts (variable yield) until a specific date. If yields go up, your ticket is worth more. |
| **SY (Standardized Yield)** | A wrapper that makes different yield-bearing tokens (haSUI, Suilend deposits, etc.) all look the same so Crux can work with any of them. |
| **PTB (Programmable Transaction Block)** | Sui's superpower. Lets you do 5 things in 1 transaction. Like a combo meal instead of ordering each item separately. |
| **AMM (Automated Market Maker)** | A robot that lets people trade tokens with each other using a math formula instead of finding a human to trade with. |
| **LogitNormal** | The specific math formula Crux's AMM uses. It's designed for interest rates, not token prices — so it gives better prices for yield trades. |
| **TVL (Total Value Locked)** | How much money is deposited in a protocol. More TVL = more trust. |
| **Tranche** | A "slice" of risk. Senior tranche = safe slice. Junior tranche = risky slice. Same cake, different pieces. |
| **veCRUX** | Vote-escrowed CRUX. You lock your CRUX tokens for 1-4 years and get voting power + share of fees. Longer lock = more power. |
| **Intent** | What you WANT to happen ("earn 7% fixed"), not HOW to do it ("call function swap_sy_to_pt on pool 0x3f..."). |
| **Maturity** | The date when a PT becomes redeemable for full value. Like the expiration date on a coupon. |
| **Yield Curve** | A chart showing what rates are at different time periods (1 month, 3 months, 6 months, 1 year). Every major financial market has one — Sui doesn't, until Crux. |
| **Flash Mint** | Borrow-mint-sell-repay all in one atomic transaction. No money needed upfront. Like a magic trick that only works because Sui is fast enough. |
| **MEV** | Maximum Extractable Value. Bad actors who steal your money between transactions by front-running or sandwiching your trades. Crux eliminates this with atomic PTBs. |
| **Gauge Voting** | CRUX holders vote on which pools get the most token emissions. This creates "Yield Wars" — protocols compete to get their pools more rewards. |
| **Hot Potato Pattern** | A Move programming pattern where an object MUST be consumed in the same transaction. It's like a hot potato — you can't put it down, you have to pass it. This makes flash mints safe. |

---

*Document version: March 2026*
*Protocol: Crux — Yield Orchestration & Intent Execution Layer for Sui*
*Target: DeFi Moonshots Program*
