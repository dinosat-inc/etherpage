// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// A SubpageRegistrar for tests only, built against PageNFTNoRecycle. Every sale mints as the parent's
// subpage minter straight to the receiver, and this contract never transfers or approves a name.

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

// the parts of PageNFT this contract uses
interface IERC721LikeNoRecycle {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPageNFTNoRecycle is IERC721LikeNoRecycle {
    function registerSubpageFor(string calldata label, uint256 parentId, address to)
        external
        returns (uint256);
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
    function normalize(string calldata label) external pure returns (string memory);
    function parentOf(uint256 tokenId) external view returns (uint256);
    function epochOf(uint256 tokenId) external view returns (uint64);
    function subpageMinterOf(uint256 parentId) external view returns (address);
}

contract SubpageRegistrarNoRecycle is ReentrancyGuard {
    uint256 internal constant MIN_SUB_COMMITMENT_AGE = 20;
    uint256 internal constant MAX_SUB_COMMITMENT_AGE = 86400;

    struct Config {
        address controller;     // slot 0, bytes 0 to 19
        bool    enabled;        // slot 0, byte 20
        bool    commitReveal;   // slot 0, byte 21
        address feeToken;       // slot 1, bytes 0 to 19, zero for ETH
        uint96  price;          // slot 1, bytes 20 to 31
        address gateToken;      // slot 2, bytes 0 to 19
        uint96  minGateBalance; // slot 2, bytes 20 to 31
        address payout;         // slot 3, bytes 0 to 19
        uint64  parentEpoch;    // slot 3, bytes 20 to 27
    }

    IPageNFTNoRecycle public immutable name;

    mapping(uint256 => Config)  public config;
    mapping(address => uint256) public proceedsOf;         // ETH owed to each payout, collected with a claim
    mapping(bytes32 => uint256) public subCommitments;     // the time each commitment was made

    error NotAuthorized();
    error NotEnabled();
    error NotAvailable();
    error GateFailed();
    error BadGateConfig();
    error BadFeeToken();
    error InsufficientFee();
    error UnexpectedETH();
    error UnexpectedFeeToken();
    error PriceTooHigh();
    error ValueTooLarge();
    error StaleController();
    error NotMinter();
    error StaleConfig();
    error ParentNotTopLevel();
    error CommitRequired();
    error AlreadyCommitted();
    error CommitmentNotFound();
    error CommitmentTooNew();
    error CommitmentTooOld();
    error NothingToClaim();
    error ETHTransferFailed();
    error TransferFromFailed();
    error InvalidAddress();

    event ParentConfigured(
        uint256 indexed parentId,
        address indexed controller,
        address indexed payout,
        address feeToken,
        uint256 price,
        address gateToken,
        uint256 minGateBalance,
        bool enabled,
        bool commitReveal,
        uint64 parentEpoch
    );
    event Committed(bytes32 indexed commitment, address indexed committer);
    event SubpageSold(
        uint256 indexed parentId,
        uint256 indexed subpageId,
        address indexed buyer,
        address to,
        address payout,
        address feeToken,
        uint256 price,
        string label
    );
    event ProceedsClaimed(address indexed account, address indexed to, uint256 amount);

    constructor(IPageNFTNoRecycle pageNFT) {
        if (address(pageNFT).code.length == 0) revert InvalidAddress();
        name = pageNFT;
    }

    function configure(
        uint256 parentId,
        address payout,
        address feeToken,
        uint256 price,
        bool enabled,
        address gateToken,
        uint256 minGateBalance,
        bool commitReveal
    ) external nonReentrant {
        // only the holder of the name may set its terms
        if (name.ownerOf(parentId) != msg.sender) revert NotAuthorized();
        if (name.parentOf(parentId) != 0) revert ParentNotTopLevel(); uint64 epoch =
        name.epochOf(parentId);
        if (payout == address(0)) payout = msg.sender;
        if (payout == address(this) || payout == address(name)) revert NotAuthorized();
        if (feeToken == address(name) || feeToken == address(this)) revert BadFeeToken();
        if (price > type(uint96).max || minGateBalance > type(uint96).max) revert ValueTooLarge();
        // a gate token and its minimum balance are set together or not at all
        if ((gateToken != address(0)) != (minGateBalance != 0)) revert BadGateConfig();
        config[parentId] = Config({
            controller: msg.sender,
            enabled: enabled,
            commitReveal: commitReveal,
            feeToken: feeToken,
            price: uint96(price),
            gateToken: gateToken,
            minGateBalance: uint96(minGateBalance),
            payout: payout,
            parentEpoch: epoch
        });
        emit ParentConfigured(parentId, msg.sender, payout, feeToken, price, gateToken, minGateBalance, enabled,
        commitReveal, epoch);
    }

    function disable(uint256 parentId) external nonReentrant {
        // only the holder of the name may stop its sales
        if (name.ownerOf(parentId) != msg.sender) revert NotAuthorized();
        config[parentId].enabled = false;
        Config storage c = config[parentId];
        emit ParentConfigured(parentId, c.controller, c.payout, c.feeToken, c.price, c.gateToken, c.minGateBalance,
            c.enabled, c.commitReveal, c.parentEpoch);
    }

    function makeSubpageCommitment(uint256 parentId, string calldata label, address to, bytes32 secret)
        external view returns (bytes32)
    {
        if (to == address(this)) revert NotAuthorized();
        return _subCommitmentHash(parentId, name.normalize(label), to, secret);
    }

    function commitSubpage(bytes32 commitment) external {
        uint256 committedAt = subCommitments[commitment];
        if (committedAt != 0 && block.timestamp <= committedAt + MAX_SUB_COMMITMENT_AGE) revert AlreadyCommitted();
        subCommitments[commitment] = block.timestamp;
        emit Committed(commitment, msg.sender);
    }

    function revealSubpage(
        uint256 parentId, string calldata label, bytes32 secret, uint256 maxPrice, address expectedFeeToken
    ) external payable returns (uint256 subId) {
        return revealSubpageFor(parentId, label, msg.sender, secret, maxPrice, expectedFeeToken);
    }

    function revealSubpageFor(
        uint256 parentId, string calldata label, address to, bytes32 secret, uint256 maxPrice,
        address expectedFeeToken
    ) public payable nonReentrant returns (uint256 subId) {
        return _sell(parentId, label, to, maxPrice, expectedFeeToken, true, secret);
    }

    function _subCommitmentHash(uint256 parentId, string memory normalized, address to, bytes32 secret)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(parentId, normalized, to, secret));
    }

    function registerSubpage(uint256 parentId, string calldata label, uint256 maxPrice, address expectedFeeToken)
        external payable returns (uint256 subId)
    {
        return registerSubpageFor(parentId, label, msg.sender, maxPrice, expectedFeeToken);
    }

    function registerSubpageFor(
        uint256 parentId, string calldata label, address to, uint256 maxPrice, address expectedFeeToken
    ) public payable nonReentrant returns (uint256 subId) {
        return _sell(parentId, label, to, maxPrice, expectedFeeToken, false, bytes32(0));
    }

    function _sell(
        uint256 parentId,
        string calldata label,
        address to,
        uint256 maxPrice,
        address expectedFeeToken,
        bool viaReveal,
        bytes32 secret
    ) internal returns (uint256 subId) {
        if (to == address(this)) revert NotAuthorized();
        Config memory c = config[parentId]; if (!c.enabled) revert NotEnabled();
        if (c.feeToken != expectedFeeToken) revert UnexpectedFeeToken();
        if (uint256(c.price) > maxPrice) revert PriceTooHigh();
        if (!viaReveal) {
            if (c.commitReveal) revert CommitRequired();
        } else {
            bytes32 commitment = _subCommitmentHash(parentId, name.normalize(label), to, secret);
            uint256 committedAt = subCommitments[commitment];
            if (committedAt == 0) revert CommitmentNotFound();
            if (block.timestamp < committedAt + MIN_SUB_COMMITMENT_AGE) revert CommitmentTooNew();
            if (block.timestamp > committedAt + MAX_SUB_COMMITMENT_AGE) revert CommitmentTooOld();
            delete subCommitments[commitment];
        }
        if (name.parentOf(parentId) != 0) revert ParentNotTopLevel(); if (name.epochOf(parentId) != c.parentEpoch) revert StaleConfig();
        // terms sell only for the holder that set them, and only while this contract is its subpage minter
        if (name.ownerOf(parentId) != c.controller) revert StaleController();
        if (name.subpageMinterOf(parentId) != address(this)) revert NotMinter();
        if (!name.isAvailable(label, parentId)) revert NotAvailable();
        if (c.gateToken != address(0) && _gateBalance(c.gateToken, msg.sender) < uint256(c.minGateBalance)) revert GateFailed();
        uint256 price = uint256(c.price);
        if (c.feeToken == address(0)) {
            if (msg.value < price) revert InsufficientFee();
        } else {
            if (msg.value != 0) revert UnexpectedETH();
        }
        subId = name.registerSubpageFor(label, parentId, to);
        if (price != 0) {
            if (c.feeToken == address(0)) proceedsOf[c.payout] += price;
            else SafeTransferLib.safeTransferFrom(c.feeToken, msg.sender, c.payout, price);
        }
        emit SubpageSold(parentId, subId, msg.sender, to, c.payout, c.feeToken, price, label);
        if (c.feeToken == address(0)) {
            uint256 refund; unchecked { refund = msg.value - price; } if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
        }
    }

    function _gateBalance(address token, address account) internal view returns (uint256 amount) {
        assembly ("memory-safe") {
            mstore(0x14, account)
            mstore(0x00, 0x70a08231000000000000000000000000)
            amount := mul(
                mload(0x20),
                and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
            )
        }
    }

    function claimProceeds(address to) external nonReentrant returns (uint256 amount) {
        return _payProceeds(msg.sender, to);
    }

    function claimProceedsFor(address account) external nonReentrant returns (uint256 amount) {
        return _payProceeds(account, account);
    }

    function _payProceeds(address account, address to) internal returns (uint256 amount) {
        amount = proceedsOf[account]; if (amount == 0) revert NothingToClaim();
        proceedsOf[account] = 0;
        if (to == address(0)) to = account;
        if (to == address(this)) revert NotAuthorized();
        emit ProceedsClaimed(account, to, amount);
        SafeTransferLib.safeTransferETH(to, amount);
    }
}
