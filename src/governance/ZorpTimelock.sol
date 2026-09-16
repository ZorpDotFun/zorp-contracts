// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Delay for hook / swap-logic changes. Minimum 4 hours, extendable to
///         30 days, never reducible.
contract ZorpTimelock {
    uint256 public constant MIN_DELAY = 4 hours;
    uint256 public constant MAX_DELAY = 30 days;

    address public immutable proposer;

    uint256 public delay = MIN_DELAY;
    mapping(bytes32 id => uint256 readyAt) public eta;
    mapping(bytes32 id => bool) public executed;
    mapping(bytes32 id => bool) public cancelled;

    error NotProposer();
    error DelayTooLow();
    error DelayTooHigh();
    error AlreadyQueued();
    error NotQueued();
    error NotReady();
    error AlreadyDone();

    event DelayExtended(uint256 previous, uint256 next);
    event Queued(bytes32 indexed id, address target, bytes data, uint256 readyAt);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id, address target, bytes data);

    constructor(address proposer_) {
        proposer = proposer_;
    }

    modifier onlyProposer() {
        if (msg.sender != proposer) revert NotProposer();
        _;
    }

    function extendDelay(uint256 newDelay) external onlyProposer {
        if (newDelay < delay) revert DelayTooLow();
        if (newDelay < MIN_DELAY) revert DelayTooLow();
        if (newDelay > MAX_DELAY) revert DelayTooHigh();
        emit DelayExtended(delay, newDelay);
        delay = newDelay;
    }

    function _id(address target, bytes calldata data) private pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    function queue(address target, bytes calldata data) external onlyProposer returns (bytes32 id) {
        id = _id(target, data);
        if (eta[id] != 0 && !executed[id] && !cancelled[id]) revert AlreadyQueued();
        executed[id] = false;
        cancelled[id] = false;
        uint256 readyAt = block.timestamp + delay;
        eta[id] = readyAt;
        emit Queued(id, target, data, readyAt);
    }

    function cancel(bytes32 id) external onlyProposer {
        if (eta[id] == 0) revert NotQueued();
        if (executed[id]) revert AlreadyDone();
        cancelled[id] = true;
        emit Cancelled(id);
    }

    function execute(address target, bytes calldata data) external onlyProposer {
        bytes32 id = _id(target, data);
        if (eta[id] == 0 || cancelled[id]) revert NotQueued();
        if (executed[id]) revert AlreadyDone();
        if (block.timestamp < eta[id]) revert NotReady();
        executed[id] = true;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit Executed(id, target, data);
    }
}
