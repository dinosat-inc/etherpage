// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @dev The parts of PageNFT this contract calls.
 */
interface IPageNFT is IERC721Like {
    function registerSubpageFor(string calldata label, uint256 parentId, address to)
        external
        returns (uint256);
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
    function normalize(string calldata label) external pure returns (string memory);
    function parentOf(uint256 tokenId) external view returns (uint256);
    function epochOf(uint256 tokenId) external view returns (uint64);
    function subpageMinterOf(uint256 parentId) external view returns (address);
}

/**
 * @title SubpageRegistrar
 * @notice Sells subpages of top level pages on terms set by their holders. A holder sets the terms here, picks
 * this contract as the subpage minter in PageNFT and keeps the page. PageNFT sees this contract as the caller of
 * every sale, so a receiving contract must accept ERC721 tokens, even when it is the buyer, unless it is an
 * EIP7702 account.
 * This software is provided as is, without warranty. Use at your own risk.
 * @dev This contract never transfers or approves a page and cannot receive one with safeTransferFrom. A page sent
 * here with a plain transferFrom can never be sent back, and leaves only when PageNFT burns it because that page
 * is registered or minted again.
 */
contract SubpageRegistrar is ReentrancyGuard {
    /**
     * @dev The shortest wait between a commitment and its reveal.
     */
    uint256 internal constant MIN_SUB_COMMITMENT_AGE = 20;

    /**
     * @dev The longest wait between a commitment and its reveal. After it the same commitment can be made again.
     */
    uint256 internal constant MAX_SUB_COMMITMENT_AGE = 86400;

    /**
     * @dev The sale terms of one top level page, packed into four storage slots. The first holds controller,
     * enabled and commitReveal, the second feeToken and price, the third gateToken and minGateBalance, and the
     * last payout and parentEpoch.
     * @param controller The holder that set the terms.
     * @param parentEpoch The epoch of the page when the terms were set. The terms stop selling once it changes.
     */
    struct Config {
        address controller;
        bool    enabled;
        bool    commitReveal;
        address feeToken;
        uint96  price;
        address gateToken;
        uint96  minGateBalance;
        address payout;
        uint64  parentEpoch;
    }

    /**
     * @notice The PageNFT contract whose subpages this contract sells.
     */
    IPageNFT public immutable registry;

    /**
     * @notice The sale terms of each top level page. They sell only while the account that set them holds the
     * page. A move away pauses them, and they stop for good once the page is registered again.
     */
    mapping(uint256 => Config)  public config;

    /**
     * @notice The ETH owed to each payout account, paid out by claimProceeds or claimProceedsFor.
     */
    mapping(address => uint256) public proceedsOf;

    /**
     * @notice The time each commitment was made.
     */
    mapping(bytes32 => uint256) public subCommitments;

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

    /**
     * @notice The full terms of a page, emitted by configure and by disable.
     */
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

    /**
     * @notice One sale. The label is exactly as the buyer sent it, so it may have capitals, while the name of the
     * subpage is lowercase.
     */
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

    /**
     * @param pageNFT The PageNFT contract, which must already be deployed.
     */
    constructor(IPageNFT pageNFT) {
        if (address(pageNFT).code.length == 0) revert InvalidAddress();
        registry = pageNFT;
    }

    /**
     * @notice Sets the subpage terms of a top level page the caller holds. They sell only while the caller keeps
     * the page, the page is live and paid, and this contract is its subpage minter. They stop for good once the
     * page is registered again.
     * @param payout Who gets paid, or zero for the caller. A token payment reaches it at once, while ETH waits
     * here until it is claimed.
     * @param feeToken The ERC20 token buyers pay with, or zero for ETH.
     * @param price The price of one subpage. It must fit in 96 bits, and so must minGateBalance.
     * @param gateToken A token buyers must hold, read with balanceOf, or zero for no gate.
     * @param minGateBalance How much of the gate token buyers must hold. It is above zero with a gate and zero
     * without one.
     * @param commitReveal Whether buyers must commit first and reveal later.
     */
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
        if (registry.ownerOf(parentId) != msg.sender) revert NotAuthorized();
        if (registry.parentOf(parentId) != 0) revert ParentNotTopLevel();
        uint64 epoch = registry.epochOf(parentId);
        if (payout == address(0)) payout = msg.sender;
        if (payout == address(this) || payout == address(registry)) revert NotAuthorized();
        if (feeToken == address(registry) || feeToken == address(this)) revert BadFeeToken();
        if (price > type(uint96).max || minGateBalance > type(uint96).max) revert ValueTooLarge();
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

    /**
     * @notice Stops subpage sales for a page. Only its holder may call it.
     */
    function disable(uint256 parentId) external nonReentrant {
        if (registry.ownerOf(parentId) != msg.sender) revert NotAuthorized();
        config[parentId].enabled = false;
        Config storage c = config[parentId];
        emit ParentConfigured(parentId, c.controller, c.payout, c.feeToken, c.price, c.gateToken, c.minGateBalance,
            c.enabled, c.commitReveal, c.parentEpoch);
    }

    /**
     * @notice The commitment to pass to commitSubpage. It binds the top level page, the normalized label, the
     * receiver and a secret, but not who reveals.
     */
    function makeSubpageCommitment(uint256 parentId, string calldata label, address to, bytes32 secret)
        external view returns (bytes32)
    {
        if (to == address(this)) revert NotAuthorized();
        return _subCommitmentHash(parentId, registry.normalize(label), to, secret);
    }

    /**
     * @notice Records the time of a commitment. The same commitment can be made again once it is used or more
     * than a day old.
     */
    function commitSubpage(bytes32 commitment) external {
        uint256 committedAt = subCommitments[commitment];
        if (committedAt != 0 && block.timestamp <= committedAt + MAX_SUB_COMMITMENT_AGE) revert AlreadyCommitted();
        subCommitments[commitment] = block.timestamp;
        emit Committed(commitment, msg.sender);
    }

    /**
     * @notice Buys a subpage for the caller, 20 seconds to one day after commitSubpage. maxPrice and
     * expectedFeeToken protect the buyer from terms changed in the meantime.
     */
    function revealSubpage(
        uint256 parentId, string calldata label, bytes32 secret, uint256 maxPrice, address expectedFeeToken
    ) external payable returns (uint256 subId) {
        return revealSubpageFor(parentId, label, msg.sender, secret, maxPrice, expectedFeeToken);
    }

    /**
     * @notice Same as revealSubpage, but for any receiver. The caller pays, gets back any ETH paid above the
     * price and must hold any gate token.
     * @param to The account that receives the subpage. It must be the one named in the commitment.
     */
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

    /**
     * @notice Buys a subpage for the caller at once, when the terms do not require commit and reveal. maxPrice
     * and expectedFeeToken protect the buyer from terms changed in the meantime.
     */
    function registerSubpage(uint256 parentId, string calldata label, uint256 maxPrice, address expectedFeeToken)
        external payable returns (uint256 subId)
    {
        return registerSubpageFor(parentId, label, msg.sender, maxPrice, expectedFeeToken);
    }

    /**
     * @notice Same as registerSubpage, but for any receiver. The caller pays, gets back any ETH paid above the
     * price and must hold any gate token.
     * @param to The account that receives the subpage.
     */
    function registerSubpageFor(
        uint256 parentId, string calldata label, address to, uint256 maxPrice, address expectedFeeToken
    ) public payable nonReentrant returns (uint256 subId) {
        return _sell(parentId, label, to, maxPrice, expectedFeeToken, false, bytes32(0));
    }

    /**
     * @dev Checks the terms and, for a reveal, the commitment, then that the terms still hold and the label is
     * free. The refund cannot underflow, since msg.value is at least the price by then.
     */
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
        Config memory c = config[parentId];
        if (!c.enabled) revert NotEnabled();
        if (c.feeToken != expectedFeeToken) revert UnexpectedFeeToken();
        if (uint256(c.price) > maxPrice) revert PriceTooHigh();
        if (!viaReveal) {
            if (c.commitReveal) revert CommitRequired();
        } else {
            bytes32 commitment = _subCommitmentHash(parentId, registry.normalize(label), to, secret);
            uint256 committedAt = subCommitments[commitment];
            if (committedAt == 0) revert CommitmentNotFound();
            if (block.timestamp < committedAt + MIN_SUB_COMMITMENT_AGE) revert CommitmentTooNew();
            if (block.timestamp > committedAt + MAX_SUB_COMMITMENT_AGE) revert CommitmentTooOld();
            delete subCommitments[commitment];
        }
        if (registry.parentOf(parentId) != 0) revert ParentNotTopLevel();
        if (registry.epochOf(parentId) != c.parentEpoch) revert StaleConfig();
        if (registry.ownerOf(parentId) != c.controller) revert StaleController();
        if (registry.subpageMinterOf(parentId) != address(this)) revert NotMinter();
        if (!registry.isAvailable(label, parentId)) revert NotAvailable();
        if (c.gateToken != address(0) && _gateBalance(c.gateToken, msg.sender) < uint256(c.minGateBalance)) revert GateFailed();
        uint256 price = uint256(c.price);
        if (c.feeToken == address(0)) {
            if (msg.value < price) revert InsufficientFee();
        } else {
            if (msg.value != 0) revert UnexpectedETH();
        }
        subId = registry.registerSubpageFor(label, parentId, to);
        if (price != 0) {
            if (c.feeToken == address(0)) proceedsOf[c.payout] += price;
            else SafeTransferLib.safeTransferFrom(c.feeToken, msg.sender, c.payout, price);
        }
        emit SubpageSold(parentId, subId, msg.sender, to, c.payout, c.feeToken, price, label);
        if (c.feeToken == address(0)) {
            uint256 refund;
            unchecked {
                refund = msg.value - price;
            }
            if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
        }
    }

    /**
     * @dev The gate token balance of the account, or zero when the call fails or returns less than 32 bytes.
     */
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

    /**
     * @notice Sends all the ETH proceeds of the caller.
     * @param to Where to send them, or zero for the caller.
     */
    function claimProceeds(address to) external nonReentrant returns (uint256 amount) {
        return _payProceeds(msg.sender, to);
    }

    /**
     * @notice Sends all the ETH proceeds of an account to that account. Anyone may call it.
     */
    function claimProceedsFor(address account) external nonReentrant returns (uint256 amount) {
        return _payProceeds(account, account);
    }

    function _payProceeds(address account, address to) internal returns (uint256 amount) {
        amount = proceedsOf[account];
        if (amount == 0) revert NothingToClaim();
        proceedsOf[account] = 0;
        if (to == address(0)) to = account;
        if (to == address(this)) revert NotAuthorized();
        emit ProceedsClaimed(account, to, amount);
        SafeTransferLib.safeTransferETH(to, amount);
    }
}
