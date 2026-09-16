// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice 2-of-3 signer set. Instant calls for pair-asset allowlist; everything
///         else is meant to go through ZorpTimelock.
contract TwoOfThree {
    uint256 public constant THRESHOLD = 2;

    address[3] public signers;
    mapping(address signer => bool) public isSigner;

    uint256 public nonce;
    mapping(bytes32 hash => uint256 approvals) public approvals;
    mapping(bytes32 hash => mapping(address signer => bool)) public approved;
    mapping(bytes32 hash => bool) public executed;
    mapping(bytes32 hash => uint256) public cancelApprovals;
    mapping(bytes32 hash => mapping(address signer => bool)) public cancelApproved;
    mapping(bytes32 hash => bool) public cancelled;

    error NotSigner();
    error AlreadyApproved();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error InsufficientApprovals();
    error DuplicateSigner();
    error ZeroAddress();
    error NotSelf();
    error UnknownSigner();

    event Proposed(bytes32 indexed hash, address indexed target, bytes data, uint256 nonce);
    event Approved(bytes32 indexed hash, address indexed signer, uint256 approvals);
    event CancelApproved(bytes32 indexed hash, address indexed signer, uint256 approvals);
    event Cancelled(bytes32 indexed hash);
    event Executed(bytes32 indexed hash, address indexed target, bytes data);
    event SignerReplaced(address indexed previous, address indexed next);

    constructor(address a, address b, address c) {
        if (a == address(0) || b == address(0) || c == address(0)) revert ZeroAddress();
        if (a == b || a == c || b == c) revert DuplicateSigner();
        signers[0] = a;
        signers[1] = b;
        signers[2] = c;
        isSigner[a] = true;
        isSigner[b] = true;
        isSigner[c] = true;
    }

    function propose(address target, bytes calldata data) external returns (bytes32 hash) {
        if (!isSigner[msg.sender]) revert NotSigner();
        hash = keccak256(abi.encode(target, data, nonce));
        unchecked {
            ++nonce;
        }
        emit Proposed(hash, target, data, nonce - 1);
        _approve(hash);
    }

    function approve(bytes32 hash) external {
        if (!isSigner[msg.sender]) revert NotSigner();
        _approve(hash);
    }

    function cancel(bytes32 hash) external {
        if (!isSigner[msg.sender]) revert NotSigner();
        if (executed[hash]) revert AlreadyExecuted();
        if (cancelled[hash]) revert AlreadyCancelled();
        if (cancelApproved[hash][msg.sender]) revert AlreadyApproved();
        cancelApproved[hash][msg.sender] = true;
        uint256 count = cancelApprovals[hash] + 1;
        cancelApprovals[hash] = count;
        emit CancelApproved(hash, msg.sender, count);
        if (count >= THRESHOLD) {
            cancelled[hash] = true;
            emit Cancelled(hash);
        }
    }

    function execute(address target, bytes calldata data, uint256 proposalNonce) external {
        bytes32 hash = keccak256(abi.encode(target, data, proposalNonce));
        if (approvals[hash] < THRESHOLD) revert InsufficientApprovals();
        if (executed[hash]) revert AlreadyExecuted();
        if (cancelled[hash]) revert AlreadyCancelled();
        executed[hash] = true;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit Executed(hash, target, data);
    }

    /// @notice Replace one signer. Must be invoked via `execute` (2-of-3).
    function replaceSigner(address previous, address next) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (!isSigner[previous]) revert UnknownSigner();
        if (next == address(0)) revert ZeroAddress();
        if (isSigner[next]) revert DuplicateSigner();
        isSigner[previous] = false;
        isSigner[next] = true;
        for (uint256 i; i < 3; ++i) {
            if (signers[i] == previous) {
                signers[i] = next;
                break;
            }
        }
        emit SignerReplaced(previous, next);
    }

    function _approve(bytes32 hash) private {
        if (cancelled[hash]) revert AlreadyCancelled();
        if (approved[hash][msg.sender]) revert AlreadyApproved();
        approved[hash][msg.sender] = true;
        uint256 count = approvals[hash] + 1;
        approvals[hash] = count;
        emit Approved(hash, msg.sender, count);
    }
}
