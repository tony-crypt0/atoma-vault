# Atoma Vault

> Delta-neutral stablecoin yield vault on Arbitrum One. Captures perp funding-rate spreads across two perp DEX venues; yield is pushed into NAV by a trusted operator, withdrawals settle in epochs.

**Live on Arbitrum One:**

- Proxy: [`0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c`](https://arbiscan.io/address/0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c)
- Standard: ERC-4626 (deposit side only — see [Withdrawals](#epoch-based-withdrawals))
- Proxy pattern: OpenZeppelin UUPS, upgraded through V2–V5 (current implementation = `src/AtomaVault.sol`, reinitializer version 3)
- Asset: USDC (6 decimals), shares use `_decimalsOffset() = 6` (18-decimal shares)

## How it works

The vault holds USDC. The owner (a Gnosis Safe) moves idle USDC to the project's trading wallet, which runs a delta-neutral funding-spread strategy on two perpetual DEXs (long on one venue, equal short on the other). Trading PnL exists **off-chain**, so an operator EOA periodically reports it on-chain as a bounded NAV delta. Share price = `totalAssets() / totalSupply()`.

**This is an actively managed, custodial vault. The owner and operator are trusted roles. It is not, and does not claim to be, trustless.** The contract's job is to make the trusted flows *bounded, delayed, and observable* — not to eliminate them.

## Trust model — read before auditing

The following are **accepted design decisions**, not vulnerabilities. Findings that reduce to "owner/operator can rug" or "NAV is oracle-less" restate the documented trust model and are out of scope.

| # | Property | Why it's intentional | On-chain guard |
|---|---|---|---|
| 1 | Owner can move idle USDC out via `capitalWithdraw` | Capital must reach the off-chain trading venue; there is no trustless variant of off-chain custody | Destination must be whitelisted ≥ 24h in advance (`CAPITAL_WHITELIST_DELAY`); settled withdrawal liabilities (`settledUnclaimedAssets`) can never be swept |
| 2 | Operator reports NAV with no price oracle | PnL lives on off-chain venue accounts; no oracle exists for it | `updateTotalAssets(int256 pnlDelta)` is delta-based, capped at `maxUpdateDeltaBps` (default 2%) per call and rate-limited to one call per `minUpdateInterval` (default 30 min, max 1 day) |
| 3 | Owner can bypass NAV bounds via `resyncTotalAssets` | Recovery path after venue liquidation or long pause; a bounded path can't express a large real loss | `onlyOwner` + `whenPaused` only |
| 4 | Shares are non-transferable (`_update` reverts) | Blocks secondary markets on a share whose NAV is operator-reported; simplifies points/rewards attribution off-chain | Mint, burn, and escrow-to-vault (during `requestWithdrawal`) are the only allowed movements |
| 5 | Synchronous `withdraw`/`redeem` revert; `maxWithdraw`/`maxRedeem` return 0 | Assets are deployed off-chain; instant exit at current NAV is impossible by construction | Epoch-based request → settle → claim flow instead |
| 6 | UUPS upgradeable by owner | Product iterates (V1→V5 already); owner is a Gnosis Safe | `_authorizeUpgrade` is `onlyOwner`; upgrades executed via Safe |
| 7 | Operator can pause, only owner can unpause | Operator is the automated watchdog (fast trigger); unpausing is a governance decision | — |
| 8 | Settled-claim haircut (`shortfallIndexWad`) | If reported NAV drops below already-settled liabilities, remaining claimants are haircut pro-rata instead of first-come-first-served draining | Index only ratchets down; applied at claim time against the epoch's index snapshot |

Also intentional: **no timelock on upgrades or owner actions besides the 24h capital-destination delay** (pre-audit stage, soft TVL cap via `maxTotalAssets`), and **withdrawal fee (0.5%) and performance fee shares go to the operator address**.

## Roles

| Role | Held by | Powers |
|---|---|---|
| Owner | Gnosis Safe | Upgrade, unpause, `resyncTotalAssets` (paused only), capital whitelist/withdraw/deposit, set operator/cap/epoch duration/NAV bounds |
| Operator | EOA (automation) | `updateTotalAssets`, `settleEpoch`, `crystallizePerformanceFee`, `pause`; receives fee shares and withdrawal fees |
| User | anyone | `deposit`/`mint` (min 100 USDC), `requestWithdrawal`, `claimWithdrawal` |

## Accounting

- `_totalManagedAssets` — operator/owner-reported total (idle + off-chain).
- `settledUnclaimedAssets` — USDC owed to settled-but-unclaimed withdrawals; excluded from `totalAssets()`, so pending claims stop participating in PnL after settlement.
- `deposit`/`mint` increase `_totalManagedAssets` directly; `claimWithdrawal` decreases both counters.

### NAV updates

`updateTotalAssets(int256 pnlDelta)` — operator, delta-bounded and rate-limited (table row 2). If the new total falls below `settledUnclaimedAssets`, the shortfall index ratchets down and liabilities are marked to the new total (row 8).

### Performance fee

20% above a share-price high-water mark, two paths:

1. `_accrueFee()` — runs on every `deposit`/`mint` and on `crystallizePerformanceFee` (operator, at most every 7 days). Mints fee shares to the operator against the profit of the whole supply, then advances the HWM.
2. `settleEpoch` — if settlement NAV is above HWM, withdrawing shares pay their 20% of the above-HWM slice via fee shares minted to operator; settlement NAV recorded net of that fee. The global HWM is **not** advanced here (remaining holders' fee is charged later via path 1).

HWM starts at 1.0 share price and only moves up; no management fee.

## Epoch-based withdrawals

1. `requestWithdrawal(shares)` — shares escrow into the vault (the one allowed transfer), booked to settlement epoch `current + 1`. Shares deposited in the **current epoch are locked** (`lockedShares`/`depositEpoch`) — prevents same-epoch deposit→request sandwiching around NAV updates.
2. `settleEpoch(epochId)` — operator, after the epoch ends. Snapshots settlement NAV (net of performance fee), burns escrowed shares, adds owed USDC to `settledUnclaimedAssets`, snapshots the shortfall index.
3. `claimWithdrawal(epochId)` — permissionless per user, never expires. Pays `shares × settlementNav`, haircut by shortfall index ratio if the index dropped since settlement, minus 0.5% withdrawal fee to operator. Reverts if idle USDC is insufficient (owner tops up via `capitalDeposit`).

Epoch length is schedule-based (`EpochSchedule[]`): `setEpochDuration` (owner, 1 hour–30 days) takes effect at the **next** epoch boundary, so past epoch IDs and end times never re-map. A pending not-yet-active schedule entry is overwritten, not stacked.

## Upgrade history

| Version | Change |
|---|---|
| V1 | ERC-4626 + UUPS base, hourly epochs, absolute NAV set |
| V2 | Epoch schedule array (`initializeV2` backfills genesis schedule) |
| V3 | Delta-based NAV updates with bounds, weekly fee crystallization, capital-destination whitelist + 24h delay, `settledUnclaimedAssets` segregation (`initializeV3` seeds bounds) |
| V4 | Shortfall/haircut index for settled claims |
| V5 | Deposit-epoch share lock, escrow-gated transfers |

Storage layout is append-only with a `__gap`; upgrade scripts (`script/UpgradeV*.s.sol`) deploy the implementation and print `upgradeToAndCall` calldata for Safe execution.

## Build & test

```bash
forge install
forge build
forge test
```

Tests: `test/AtomaVault.t.sol` (core flows) and `test/AtomaVaultUpgradeV2.t.sol` (upgrade path).

### Deploy / upgrade

```bash
export ARBITRUM_RPC_URL=...
export DEPLOYER_PRIVATE_KEY=0x...
export PROXY_ADDRESS=0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c

forge script script/DeployMainnet.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
forge script script/UpgradeV5.s.sol --rpc-url $ARBITRUM_RPC_URL   # prints Safe calldata, does not broadcast the upgrade
```

## Audit status

Not audited yet. Deployed pre-audit with a soft TVL cap (`maxTotalAssets`). Formal audit planned before scaling TVL.

## License

MIT
