# zorp-contracts

Zorp launchpad contracts for Arc (5042) and Robinhood Chain (4663). Foundry, Solidity 0.8.26, viaIR, Cancun.

```bash
forge install
forge test
```

- Arc: `script/Deploy.s.sol` (USDC pair)
- Robinhood: `script/DeployRobinhood.s.sol` (official WETH pair)

Copy `.env.example` to `.env` — never commit keys. You broadcast; the scripts do not print keys.
