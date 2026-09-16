// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeOnTransfer is ERC20 {
    constructor() ERC20("Fee Token", "FOT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 1) {
            uint256 fee = value / 10;
            super._update(from, to, value - fee);
            super._update(from, address(0xFEE), fee);
            return;
        }
        super._update(from, to, value);
    }
}
