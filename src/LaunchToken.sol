// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {TokenMetadata} from "./libraries/ZorpTypes.sol";

/// @notice Fixed 1B-supply ERC-20. No owner, mint, or tax. Diamond Hands reward
///         debt is tracked here because the hook never sees wallet transfers.
contract LaunchToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant PRECISION = 1e18;

    address public immutable factory;
    address public immutable distributor;
    address public immutable creator;
    address public immutable pairAsset;

    string public image;
    string public description;
    string public twitter;
    string public telegram;
    string public website;
    bool public metadataFrozen;

    uint256 public accRewardPerShare;
    mapping(address account => uint256) public rewardDebt;
    mapping(address account => uint256) public unclaimed;
    mapping(address account => bool) public excluded;

    address[] private _excludedAccounts;
    mapping(address account => bool) private _inExcludedList;

    error NotFactory();
    error NotDistributor();
    error ZeroAddress();
    error MetadataFrozen();

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyDistributor() {
        if (msg.sender != distributor) revert NotDistributor();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_,
        address distributor_,
        address creator_,
        address pairAsset_
    ) ERC20(name_, symbol_) {
        if (factory_ == address(0) || distributor_ == address(0) || creator_ == address(0) || pairAsset_ == address(0))
        {
            revert ZeroAddress();
        }
        factory = factory_;
        distributor = distributor_;
        creator = creator_;
        pairAsset = pairAsset_;
        _mint(factory_, TOTAL_SUPPLY);
    }

    /// @notice One-shot write from the factory during `launchToken`. CREATE2
    ///         stays independent of image/socials so salt mining is stable.
    function setMetadata(TokenMetadata calldata metadata) external onlyFactory {
        if (metadataFrozen) revert MetadataFrozen();
        metadataFrozen = true;
        image = metadata.image;
        description = metadata.description;
        twitter = metadata.twitter;
        telegram = metadata.telegram;
        website = metadata.website;
    }

    /// @notice Argus / Telegram / Dexscreener alias. Same string as `image`.
    function imageUri() external view returns (string memory) {
        return image;
    }

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
        )
    {
        return (creator, name(), symbol(), image, description, twitter, telegram, website);
    }

    function setExcluded(address account, bool value) external onlyFactory {
        if (excluded[account] == value) return;
        _sync(account);
        excluded[account] = value;
        if (value && !_inExcludedList[account]) {
            _inExcludedList[account] = true;
            _excludedAccounts.push(account);
        }
        rewardDebt[account] = excluded[account] ? 0 : (balanceOf(account) * accRewardPerShare) / PRECISION;
    }

    function notifyReward(uint256 amount) external onlyDistributor returns (uint256 applied) {
        if (amount == 0) return 0;
        uint256 eligible = _eligibleSupply();
        if (eligible == 0) return 0;
        accRewardPerShare += (amount * PRECISION) / eligible;
        return amount;
    }

    function claimRewards(address account) external onlyDistributor returns (uint256 amount) {
        _sync(account);
        amount = unclaimed[account];
        unclaimed[account] = 0;
        if (!excluded[account]) {
            rewardDebt[account] = (balanceOf(account) * accRewardPerShare) / PRECISION;
        }
    }

    function pendingRewards(address account) external view returns (uint256) {
        if (excluded[account]) return unclaimed[account];
        uint256 accumulated = (balanceOf(account) * accRewardPerShare) / PRECISION;
        uint256 pending = unclaimed[account];
        if (accumulated > rewardDebt[account]) pending += accumulated - rewardDebt[account];
        return pending;
    }

    function excludedCount() external view returns (uint256) {
        return _excludedAccounts.length;
    }

    function _update(address from, address to, uint256 value) internal override {
        _sync(from);
        _sync(to);
        super._update(from, to, value);
        if (from != address(0) && !excluded[from]) {
            rewardDebt[from] = (balanceOf(from) * accRewardPerShare) / PRECISION;
        }
        if (to != address(0) && !excluded[to]) {
            rewardDebt[to] = (balanceOf(to) * accRewardPerShare) / PRECISION;
        }
    }

    function _sync(address account) private {
        if (account == address(0) || excluded[account]) return;
        uint256 accumulated = (balanceOf(account) * accRewardPerShare) / PRECISION;
        if (accumulated > rewardDebt[account]) {
            unclaimed[account] += accumulated - rewardDebt[account];
        }
    }

    function _eligibleSupply() private view returns (uint256 supply) {
        supply = totalSupply();
        uint256 length = _excludedAccounts.length;
        for (uint256 i; i < length; ++i) {
            address account = _excludedAccounts[i];
            if (!excluded[account]) continue;
            uint256 bal = balanceOf(account);
            if (supply <= bal) return 0;
            unchecked {
                supply -= bal;
            }
        }
    }
}
