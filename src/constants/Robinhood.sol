// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Robinhood Chain mainnet (4663). Official Uniswap deployments
///         plus `eth_getCode` on https://rpc.mainnet.chain.robinhood.com
///         https://developers.uniswap.org/deployments.json
library Robinhood {
    uint256 internal constant CHAIN_ID = 4663;

    /// @notice Canonical WETH (18 decimals). Verified `symbol()` / `decimals()`.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint8 internal constant WETH_DECIMALS = 18;

    /// @notice Seed ETH/USD (6dp) so launches open at $3,000 FDV before a live
    ///         WETH/USD pool is wired. Council can update via `setPairUsdPrice6`.
    uint256 internal constant WETH_USD_6 = 3_000e6;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant V4_UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;

    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
}
