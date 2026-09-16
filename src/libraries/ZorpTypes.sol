// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct FeeConfig {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint16 creatorBps;
    uint16 dividendBps;
    uint16 buybackBps;
    uint16 autoLpBps;
    uint16 tributeBps;
    /// @notice Share of the *user* buy/sell tax sent to the protocol treasury.
    ///         The separate swap protocol fee is `ZorpBuyback.protocolFeeBps` (default 50), not this field.
    uint16 protocolBps;
}

struct LaunchConfig {
    address pairAsset;
    FeeConfig fees;
    uint256 firstBuyCap;
}

/// @notice Display fields collected at launch. Frontend prefixes X as `x.com/`
///         and Telegram as `t.me/` before submit. Image is an `ipfs://` CID
///         (https gateway URLs are also accepted).
struct TokenMetadata {
    string image;
    string description;
    string twitter;
    string telegram;
    string website;
}

struct LaunchParams {
    string name;
    string symbol;
    TokenMetadata metadata;
    address creator;
    address tributeRecipient;
    bytes32 salt;
    LaunchConfig config;
}

library TokenMetadataLib {
    uint256 internal constant MAX_NAME_LENGTH = 64;
    uint256 internal constant MAX_SYMBOL_LENGTH = 16;
    uint256 internal constant MAX_IMAGE_LENGTH = 512;
    uint256 internal constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 internal constant MAX_SOCIAL_LENGTH = 256;

    error MetadataTooLong();

    function validate(string memory name, string memory symbol, TokenMetadata memory metadata) internal pure {
        if (
            bytes(name).length > MAX_NAME_LENGTH || bytes(symbol).length > MAX_SYMBOL_LENGTH
                || bytes(metadata.image).length > MAX_IMAGE_LENGTH
                || bytes(metadata.description).length > MAX_DESCRIPTION_LENGTH
                || bytes(metadata.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(metadata.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(metadata.website).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}

library FeeConfigLib {
    uint16 internal constant BPS = 10_000;
    uint16 internal constant MIN_TAX_BPS = 0;
    uint16 internal constant MAX_TAX_BPS = 1_000;
    uint16 internal constant DEFAULT_PROTOCOL_FEE_BPS = 50;
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 1_000;

    error InvalidTax();
    error InvalidSplit();

    function validate(FeeConfig memory fees) internal pure {
        if (fees.buyTaxBps < MIN_TAX_BPS || fees.buyTaxBps > MAX_TAX_BPS) revert InvalidTax();
        if (fees.sellTaxBps < MIN_TAX_BPS || fees.sellTaxBps > MAX_TAX_BPS) revert InvalidTax();
        uint256 split = uint256(fees.creatorBps) + fees.dividendBps + fees.buybackBps + fees.autoLpBps
            + fees.tributeBps + fees.protocolBps;
        if (split != BPS) revert InvalidSplit();
    }
}
