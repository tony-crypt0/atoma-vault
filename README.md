# Atoma Vault

> Delta-neutral stablecoin yield vault on Arbitrum One. Captures perp funding-rate spreads across Nado and Extended, distributes exchange points to depositors weekly.

**Live on Arbitrum One:**

- Vault contract: [`0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c`](https://arbiscan.io/address/0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c)
- Standard: ERC-4626
- Proxy pattern: OpenZeppelin UUPS

## Overview

Atoma Vault is a stablecoin yield product that captures funding-rate spreads between perpetual DEXs. The vault opens a long position on one perp DEX (Nado) and an equal short on another (Extended), neutralizing price exposure. The funding-rate spread between the two venues becomes pure USDC yield, paid into NAV every hour. Exchange points from both venues are distributed back to depositors on a weekly cadence by their AVS share.

### Why it's different

- Productizes a yield source most retail depositors can't access on their own (cross-venue funding capture).
- Distributes exchange points back to depositors rather than retaining them entirely at the operator level.
- Honest on-chain pricing: NAV is pushed every hour with a hard 0.2% sanity bound to block manipulation.
- HWM-gated performance fee — operator only earns on new high-water marks, never on principal.

## Contract architecture

### Vault (`src/AtomaVault.sol`)

- ERC-4626-compliant share accounting (1 share = pro-rata claim on NAV).
- Upgradeable via OpenZeppelin UUPS proxy.
- Epoch-based withdrawals: depositors request withdrawal → wait until the next weekly epoch settles → claim USDC.
- Withdrawal claims persist indefinitely — users can never lose claim rights to a settled epoch.
- 0% management fee, 20% performance fee gated by per-vault high-water mark, 0.5% withdrawal fee.

### Key safety properties

| Property | Where enforced |
|---|---|
| Operator cannot push NAV by more than ±0.2% per update | `_enforce_nav_sanity` |
| Performance fee only paid above high-water mark | `_compute_performance_fee` |
| No admin function can confiscate user shares | `capitalWithdraw` moves only vault idle USDC |
| Settled withdrawal claims never expire | `claim` reads from `epochWithdrawals` mapping with no time gate |
| Epoch settlement bounded by an `EPOCH_LENGTH` constant | `_currentEpoch` |

### NAV flow

```
1. Operator computes off-chain NAV from
   exchange equities + idle USDC
2. Operator calls updateTotalAssets(newNav)
3. Contract checks |newNav - prevNav| ≤ 0.2%
4. If above HWM: mint performance-fee shares to operator
5. Update HWM, emit NavUpdated event
```

NAV is pushed hourly via a cron-driven operator service. Each push is a single on-chain transaction visible on Arbiscan.

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)

### Build

```bash
forge install
forge build
```

### Test

```bash
forge test
forge test --gas-report
```

The test suite covers deposit/withdraw flows, epoch settlement, NAV sanity bound, performance fee accounting, high-water mark behavior, withdrawal claim persistence, and upgradeability paths.

### Deploy

Set environment variables:

```bash
export ARBITRUM_RPC_URL="https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY"
export DEPLOYER_PRIVATE_KEY="0x..."
```

Deploy to Arbitrum One:

```bash
forge script script/DeployMainnet.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast --verify
```

## Audit status

Not audited yet. Pre-audit deployment for hackathon submission with a soft TVL cap. Formal audit by a recognized firm is planned before scaling TVL beyond $1M.

## Team

Built by the FlowBot team — operators of an automated cross-exchange trading platform with ~$12B in volume processed to date. Atoma productizes that battle-tested execution layer as a depositor-facing vault.

## License

MIT
