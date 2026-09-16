// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TokenMetadata} from "../libraries/ZorpTypes.sol";

interface ILaunchToken {
    function creator() external view returns (address);
    function pairAsset() external view returns (address);
    function distributor() external view returns (address);
    function image() external view returns (string memory);
    function imageUri() external view returns (string memory);
    function description() external view returns (string memory);
    function twitter() external view returns (string memory);
    function telegram() external view returns (string memory);
    function website() external view returns (string memory);
    function metadataFrozen() external view returns (bool);
    function getTokenInfo()
        external
        view
        returns (
            address tokenCreator,
            string memory tokenName,
            string memory tokenSymbol,
            string memory tokenImage,
            string memory tokenDescription,
            string memory tokenTwitter,
            string memory tokenTelegram,
            string memory tokenWebsite
        );
    function setMetadata(TokenMetadata calldata metadata) external;
    function notifyReward(uint256 amount) external returns (uint256 applied);
    function claimRewards(address account) external returns (uint256);
    function pendingRewards(address account) external view returns (uint256);
    function setExcluded(address account, bool excluded) external;
    function burn(uint256 amount) external;
}
