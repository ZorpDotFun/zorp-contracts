// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeConfig} from "../libraries/ZorpTypes.sol";

interface IFeeDistributor {
    function registerLaunch(
        address token,
        address pairAsset,
        address creator,
        address tributeRecipient,
        FeeConfig calldata fees
    ) external;

    function accrue(address token, uint256 splitQuote, uint256 protocolQuote) external;

    function claim(address token) external returns (uint256);
    function claimToken(address asset) external returns (uint256);

    function distribute(address token, uint256 minBuybackOut, uint256 minAutoLpOut) external;
}
