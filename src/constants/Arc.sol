// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Arc mainnet (5042). Filled from official Uniswap deployments
///         (Arc / 5042) and eth_getCode on a live 5042 RPC.
///         https://developers.uniswap.org/deployments.json
///         https://developers.uniswap.org/docs/protocols/v4/deployments
library Arc {
    uint256 internal constant CHAIN_ID = 5042;

    /// @notice Arc USDC predeploy (6 decimals). Not a Uniswap contract.
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint8 internal constant USDC_DECIMALS = 6;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant V4_UNIVERSAL_ROUTER = 0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1;

    address internal constant V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant V3_NPM = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address internal constant V3_QUOTER = 0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468;
    address internal constant SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
}
