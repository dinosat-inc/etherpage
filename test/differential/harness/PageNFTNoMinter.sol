// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// A PageNFT for tests only, kept as a reference for the minter gas test and the minter authority
// attack test. It has no subpage minter, no multicall, no trials, no rules for names without a
// deposit, no holder check on display names, no profile writer rule and no status view. A subpage
// held by DEAD is not free or deleted. It keeps the sender's display name when a name moves and asks
// every contract recipient to accept a minted name.
// It predates all six changes of the last round: it has no holderSince, no addressesUpdatedAt and no
// data records, no page held by DEAD is ever deleted, top level or subpage, the metadata of a
// subpage has no sentence about its parent's holder, and addr(node) is still the main address, with
// AddrChanged sent only for the main address. So the gas that MinterGas logs for src also counts the
// holderSince store, and MinterAuthority compares only refusals of the zero caller, which none of
// this changes. Like src, though, it calls render without the payee, and its tokenURI gives only a
// top level page a Length.

import {Base64} from "solady/utils/Base64.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

contract PageNFTNoMinter is ERC721, ReentrancyGuard {
    using LibString for uint256;

    function _refundExcess(uint256 required) internal {
        if (msg.value > required) SafeTransferLib.safeTransferETH(msg.sender, msg.value - required);
    }

    /// @dev keccak256("etherpage.root.v1"), the single root all top level names hang from.
    bytes32 public constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 internal constant MIN_LABEL_LENGTH = 1;
    uint256 internal constant MAX_LABEL_LENGTH = 63;
    uint256 internal constant MIN_COMMITMENT_AGE = 20;
    uint256 internal constant MAX_COMMITMENT_AGE = 86400;
    uint256 internal constant REGISTRATION_PERIOD = 365 days;
    uint256 internal constant GRACE_PERIOD = 90 days;
    uint256 internal constant MAX_EXPIRY_HORIZON = 3650 days;
    uint256 internal constant PREMIUM_DECAY_PERIOD = 21 days;
    uint256 internal constant MAX_PREMIUM = 10 ether;
    uint256 internal constant FEE_LEN1 = 0.01 ether;
    uint256 internal constant FEE_LEN2 = 0.01 ether;
    uint256 internal constant FEE_LEN3 = 0.001 ether;
    uint256 internal constant FEE_LEN4 = 0.001 ether;
    uint256 internal constant DEFAULT_FEE = 0.0001 ether;
    uint256 internal constant COIN_TYPE_ETH = 60;
    uint256 internal constant COIN_TYPE_OP = 0x8000000a;
    uint256 internal constant DEFAULT_EVM = 0x80000000;
    uint256 internal constant PREMIUM_REFERRER_BPS = 2500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct PageRecord {
        string label;        // lowercase a to z, 0 to 9 and the hyphen
        uint256 parent;      // 0 for a top level name, the parent id for a subpage
        uint64 expiresAt;    // unix seconds, 0 for a subpage
        uint64 epoch;        // bumped on every registration of this id
        uint64 parentEpoch;  // the parent's epoch at mint time, 0 for a top level name
    }

    /// @dev An address on one chain and the account that saved it.
    struct ChainAddress {
        address saver;
        bytes value;
    }

    mapping(uint256 => PageRecord) public records;
    mapping(uint256 => uint256) public recordVersion;
    mapping(bytes32 => uint256) public commitments;
    mapping(address => uint256) public primaryPage;
    mapping(uint256 => uint256) public referrerOf;

    // the two ledgers
    mapping(uint256 => uint256) public depositOf;
    mapping(address => uint256) public owed;

    // versioned resolver data, a saved address counts only while its saver owns the name
    mapping(uint256 => mapping(uint256 => address)) internal _resolvedAddress;
    mapping(uint256 => mapping(uint256 => bytes)) internal _contenthash;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => ChainAddress))) internal _coinAddr;
    mapping(uint256 => mapping(uint256 => mapping(string => string))) internal _text;
    mapping(uint256 => mapping(uint256 => address)) internal _addrSaver;

    /// @dev Stateless certificate renderer, pinned forever at deployment
    PageCard public immutable card;

    function _recordExists(uint256 tokenId) internal view returns (bool) {
        return bytes(records[tokenId].label).length != 0;
    }

    event PageRegistered(uint256 indexed tokenId, string label, address indexed owner, uint256 expiresAt);
    event SubpageRegistered(uint256 indexed tokenId, uint256 indexed parentId, string label);
    event PageRenewed(uint256 indexed tokenId, uint256 newExpiresAt);
    event PrimaryPageSet(address indexed addr, uint256 indexed tokenId);
    event Committed(bytes32 indexed commitment, address indexed committer);
    event ReferrerSet(uint256 indexed tokenId, uint256 indexed referrerId);

    event DepositAdded(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 newTotal);
    event DepositBoughtOut(uint256 indexed tokenId, address indexed to, uint256 amount);
    event DepositReleased(uint256 indexed tokenId, address indexed to, uint256 amount);
    event ReferrerPremiumCredited(
        uint256 indexed tokenId, uint256 indexed referrerId, address indexed to, uint256 amount
    );
    event OwnerPremiumCredited(uint256 indexed tokenId, address indexed to, uint256 amount);
    event Withdrawn(address indexed account, address indexed caller, uint256 amount);

    /// @notice Carries the main address, which is the OP address, not the Ethereum one.
    ///         Ethereum apps must call addr(node, 60) and should not rely on events alone, since some answers
    ///         change with no event, for example on expiry.
    event AddrChanged(bytes32 indexed node, address addr);
    event ContenthashChanged(bytes32 indexed node, bytes contenthash);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes addr);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);
    event VersionChanged(bytes32 indexed node, uint64 newVersion);

    /// @dev ERC4906. Parameters are unindexed exactly as the EIP declares them.
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    error Expired();
    error EmptyLabel();
    error InvalidLabel();
    error Unauthorized();
    error InvalidLength();
    error InvalidRecipient();
    error UnexpectedValue();
    error NotParentOwner();
    error NotTopLevel();
    error InsufficientFee();
    error AlreadyCommitted();
    error CommitmentTooNew();
    error CommitmentTooOld();
    error AlreadyRegistered();
    error CommitmentNotFound();
    error InvalidRenderer();
    error SelfReferral();
    error NotReleasable();
    error NothingToRelease();
    error NothingToWithdraw();
    error RenewalTooFar();

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0x3b3b57de   // addr(bytes32)
            || interfaceId == 0xf1cb7e06   // addr(bytes32,uint256)
            || interfaceId == 0x59d1d43c   // text(bytes32,string)
            || interfaceId == 0xbc1c58d1   // contenthash(bytes32)
            || interfaceId == 0x49064906   // ERC4906 metadata update
            || super.supportsInterface(interfaceId);
    }

    function name() public pure override(ERC721) returns (string memory) {
        return "Etherpage";
    }

    function symbol() public pure override(ERC721) returns (string memory) {
        return "ETHERPAGE";
    }

    constructor(PageCard pageCard) {
        if (address(pageCard) == address(0)) revert InvalidRenderer();
        // a wrong renderer address fails the deployment here, not every tokenURI call later
        if (
            bytes(
                pageCard.render("a", "", bytes32(0), PageCard.Status.Active, 0)
            ).length < 100
        ) revert InvalidRenderer();
        card = pageCard;
    }

    function parentOf(uint256 tokenId) external view returns (uint256) {
        return records[tokenId].parent;
    }

    function epochOf(uint256 tokenId) external view returns (uint64) {
        return records[tokenId].epoch;
    }

    function computeNamehash(string calldata fullName) public pure returns (bytes32 node) {
        bytes memory b = bytes(fullName);
        uint256 len = b.length;
        if (len == 0) return ROOT;
        if (b[0] == 0x2e || b[len - 1] == 0x2e) revert EmptyLabel();
        uint256 dots;
        for (uint256 i = 1; i < len; ++i) {
            if (b[i] == 0x2e) {
                if (b[i - 1] == 0x2e) revert EmptyLabel();
                ++dots;
            }
        }
        if (dots > 1) revert InvalidLabel();
        node = ROOT;
        uint256 labelEnd = len;
        for (uint256 i = len; i > 0; --i) {
            if (b[i - 1] == 0x2e) {
                node = keccak256(abi.encodePacked(node, keccak256(_toLowerSlice(b, i, labelEnd))));
                labelEnd = i - 1;
            }
        }
        node = keccak256(abi.encodePacked(node, keccak256(_toLowerSlice(b, 0, labelEnd))));
    }

    function computeId(string calldata fullName) public pure returns (uint256) {
        return uint256(computeNamehash(fullName));
    }

    function _toLowerSlice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        unchecked {
            for (uint256 i = start; i < end; ++i) {
                bytes1 c = b[i];
                out[i - start] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
            }
        }
    }

    function _validateAndNormalize(bytes memory b) internal pure returns (bytes memory out) {
        uint256 err;
        (err, out) = _tryNormalize(b);
        if (err == 1) revert InvalidLength();
        if (err != 0) revert InvalidLabel();
    }

    function normalize(string calldata label) public pure returns (string memory) {
        return string(_validateAndNormalize(bytes(label)));
    }

    function _tryNormalize(bytes memory b) internal pure returns (uint256 err, bytes memory out) {
        uint256 n = b.length;
        if (n < MIN_LABEL_LENGTH || n > MAX_LABEL_LENGTH) return (1, "");
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5a) {
                // A to Z, lowercased
                out[i] = bytes1(c + 32);
            } else if ((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d) {
                // a to z, 0 to 9 and the hyphen, kept as they are
                out[i] = b[i];
            } else {
                // every other byte, 0x80 to 0xff included
                return (2, "");
            }
        }
        // hyphens as in .com: not first, not last, not in both the 3rd and 4th position
        if (out[0] == 0x2d || out[n - 1] == 0x2d) return (2, "");
        if (n >= 4 && out[2] == 0x2d && out[3] == 0x2d) return (2, "");
        // 0x and then exactly 40 characters from 0 to 9 and a to f reads as an Ethereum address, so it is refused
        if (n == 42 && out[0] == 0x30 && out[1] == 0x78) {
            uint256 j = 2;
            while (j < 42) {
                uint8 h = uint8(out[j]);
                if ((h < 0x30 || h > 0x39) && (h < 0x61 || h > 0x66)) break;
                ++j;
            }
            if (j == 42) return (2, "");
        }
    }

    function getFee(uint256 length) public pure returns (uint256) {
        if (length == 1) return FEE_LEN1;
        if (length == 2) return FEE_LEN2;
        if (length == 3) return FEE_LEN3;
        if (length == 4) return FEE_LEN4;
        return DEFAULT_FEE;
    }

    function getPremium(uint256 tokenId) public view returns (uint256) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return 0;
        uint256 graceEnd = records[tokenId].expiresAt + GRACE_PERIOD;
        if (block.timestamp <= graceEnd) return 0;
        uint256 elapsed = block.timestamp - graceEnd;
        if (elapsed >= PREMIUM_DECAY_PERIOD) return 0;
        return MAX_PREMIUM * (PREMIUM_DECAY_PERIOD - elapsed) / PREMIUM_DECAY_PERIOD;
    }

    function quote(string calldata label)
        external view
        returns (uint256 fee, uint256 carried, uint256 premium, uint256 total)
    {
        (uint256 err, bytes memory normalized) = _tryNormalize(bytes(label)); if (err != 0) return (0, 0, 0, 0);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
        fee = getFee(normalized.length);
        bool inAuction = block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD && block.timestamp <= _auctionEnd(id);
        carried = (_recordExists(id) && inAuction) ? depositOf[id] : 0;
        premium = getPremium(id);
        total = fee + carried + premium;
    }

    function isAvailable(string calldata label, uint256 parentId) public view returns (bool) {
        (uint256 err, bytes memory normalized) = _tryNormalize(bytes(label)); if (err != 0) return false;
        if (parentId == 0) {
            uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
            if (!_recordExists(id)) return true;
            return block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD;
        } else {
            if (!_recordExists(parentId)) return false;
            PageRecord storage p = records[parentId];
            if (p.parent != 0) return false;
            if (!_isActive(parentId)) return false;
            uint256 id = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(normalized))));
            if (!_recordExists(id)) return true;
            return records[id].parentEpoch != p.epoch;
        }
    }

    function commit(bytes32 commitment) external {
        uint256 committedAt = commitments[commitment];
        if (committedAt != 0 && block.timestamp <= committedAt + MAX_COMMITMENT_AGE) revert AlreadyCommitted();
        commitments[commitment] = block.timestamp;
        emit Committed(commitment, msg.sender);
    }

    function _commitmentHash(bytes memory normalized, address owner, uint256 referrerId, bytes32 secret)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(normalized, owner, referrerId, secret));
    }

    function makeCommitment(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        public pure returns (bytes32)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        if (referrerId == uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))))) {
            revert SelfReferral();
        }
        return _commitmentHash(normalized, owner, referrerId, secret);
    }

    function reveal(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external payable nonReentrant returns (uint256 tokenId)
    {
        return _registerTopLevel(label, owner, referrerId, secret);
    }

    function _registerTopLevel(string calldata label, address to, uint256 referrerId, bytes32 secret)
        internal returns (uint256 tokenId)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        uint256 fee = getFee(normalized.length);
        tokenId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
        if (referrerId == tokenId) revert SelfReferral();
        if (depositOf[tokenId] != 0 && block.timestamp > _auctionEnd(tokenId)) _releaseDeposit(tokenId);
        uint256 carried = depositOf[tokenId];
        uint256 premium = getPremium(tokenId);
        uint256 total = fee + carried + premium;
        if (msg.value < total) revert InsufficientFee();
        bytes32 c = _commitmentHash(normalized, to, referrerId, secret); uint256 committedAt = commitments[c]; if (committedAt == 0) revert CommitmentNotFound(); if (block.timestamp < committedAt + MIN_COMMITMENT_AGE) revert CommitmentTooNew(); if (block.timestamp > committedAt + MAX_COMMITMENT_AGE) revert CommitmentTooOld();
        delete commitments[c];
        bool existed = _recordExists(tokenId); if (existed && block.timestamp <= uint256(records[tokenId].expiresAt) + GRACE_PERIOD) revert AlreadyRegistered();
        uint256 oldReferrer = referrerOf[tokenId];
        address oldPayee = _payee(tokenId);
        address refPayee = _referrerPayee(oldReferrer);
        address t1 = _credit(oldPayee, carried); if (t1 != address(0)) emit DepositBoughtOut(tokenId, t1, carried);
        uint256 refShare = premium * PREMIUM_REFERRER_BPS / BPS_DENOMINATOR; uint256 ownerShare = premium - refShare; address t2 = _credit(refPayee, refShare); if (t2 != address(0)) emit ReferrerPremiumCredited(tokenId, oldReferrer, t2, refShare); address t3 = _credit(oldPayee, ownerShare); if (t3 != address(0)) emit OwnerPremiumCredited(tokenId, t3, ownerShare);
        uint64 newEpoch = existed ? records[tokenId].epoch + 1 : 1;
        if (existed) {
            address oldOwner = _ownerOf(tokenId); if (primaryPage[oldOwner] == tokenId) { delete primaryPage[oldOwner]; emit PrimaryPageSet(oldOwner, 0); }
            _burn(tokenId);
            uint256 newVersion = ++recordVersion[tokenId]; emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        }
        records[tokenId] = PageRecord({label: string(normalized), parent: 0, expiresAt: uint64(block.timestamp + REGISTRATION_PERIOD), epoch: newEpoch, parentEpoch: 0});
        referrerOf[tokenId] = referrerId; emit ReferrerSet(tokenId, referrerId);
        depositOf[tokenId] += fee; emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId]);
        _safeMint(to, tokenId);
        emit PageRegistered(tokenId, string(normalized), to, records[tokenId].expiresAt); emit MetadataUpdate(tokenId);
        _refundExcess(total);
    }

    function renew(uint256 tokenId) external payable nonReentrant {
        PageRecord storage record = records[tokenId];
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        if (record.parent != 0) revert NotTopLevel();
        if (block.timestamp > uint256(record.expiresAt) + GRACE_PERIOD) revert Expired();
        uint256 fee = getFee(bytes(record.label).length);
        if (msg.value < fee) revert InsufficientFee();
        uint256 newExpiry = uint256(record.expiresAt) + REGISTRATION_PERIOD; if (newExpiry > block.timestamp + MAX_EXPIRY_HORIZON) revert RenewalTooFar();
        record.expiresAt = uint64(newExpiry);
        depositOf[tokenId] += fee;
        emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId]); emit PageRenewed(tokenId, record.expiresAt); emit MetadataUpdate(tokenId);
        _refundExcess(fee);
    }

    function registerSubpage(string calldata label, uint256 parentId)
        external nonReentrant returns (uint256 tokenId)
    {
        return _registerSubpage(label, parentId, msg.sender);
    }

    function registerSubpageFor(string calldata label, uint256 parentId, address to)
        external nonReentrant returns (uint256 tokenId)
    {
        return _registerSubpage(label, parentId, to);
    }

    function _registerSubpage(string calldata label, uint256 parentId, address to)
        internal returns (uint256 tokenId)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        if (parentId == 0) revert TokenDoesNotExist();
        if (!_recordExists(parentId)) revert TokenDoesNotExist(); PageRecord storage p = records[parentId];
        if (p.parent != 0) revert NotTopLevel();
        if (block.timestamp > p.expiresAt) revert Expired();
        if (_ownerOf(parentId) != msg.sender) revert NotParentOwner();
        tokenId = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(normalized))));
        uint64 newEpoch = 1;
        if (_recordExists(tokenId)) {
            newEpoch = records[tokenId].epoch + 1;
            address oldOwner = _ownerOf(tokenId);
            if (primaryPage[oldOwner] == tokenId) { delete primaryPage[oldOwner]; emit PrimaryPageSet(oldOwner, 0); }
            _burn(tokenId);
            uint256 newVersion = ++recordVersion[tokenId]; emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        }
        records[tokenId] = PageRecord({label: string(normalized), parent: parentId, expiresAt: 0, epoch: newEpoch, parentEpoch: p.epoch});
        _safeMint(to, tokenId);
        emit SubpageRegistered(tokenId, parentId, string(normalized));
    }

    function _referrerPayee(uint256 refId) internal view returns (address) {
        if (refId == 0) return DEAD;                          // no referrer recorded
        if (!_recordExists(refId)) return DEAD;               // referrer record missing
        if (records[refId].parent != 0) return DEAD;          // referrer is a subpage
        return _payee(refId);                                 // sanitizes 0 and address(this)
    }

    function _credit(address account, uint256 amount) internal returns (address to) {
        if (amount == 0) return address(0);
        to = account;
        if (to == address(0) || to == address(this)) to = DEAD;
        owed[to] += amount;
    }

    function _auctionEnd(uint256 tokenId) internal view returns (uint256) {
        return uint256(records[tokenId].expiresAt) + GRACE_PERIOD + PREMIUM_DECAY_PERIOD;
    }

    function _releaseDeposit(uint256 tokenId) internal {
        uint256 amount = depositOf[tokenId];
        address p = _payee(tokenId);
        depositOf[tokenId] = 0;
        address to = _credit(p, amount);
        emit DepositReleased(tokenId, to, amount);
    }

    function release(uint256 tokenId) external nonReentrant {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        PageRecord storage r = records[tokenId];
        if (r.parent != 0) revert NotTopLevel();
        if (block.timestamp <= _auctionEnd(tokenId)) revert NotReleasable();
        if (depositOf[tokenId] == 0) revert NothingToRelease();
        _releaseDeposit(tokenId);
        emit MetadataUpdate(tokenId);
    }

    function isReleasable(uint256 tokenId) external view returns (bool) {
        if (!_recordExists(tokenId)) return false;
        PageRecord storage r = records[tokenId];
        if (r.parent != 0) return false;
        if (block.timestamp <= _auctionEnd(tokenId)) return false;
        return depositOf[tokenId] != 0;
    }

    function withdraw(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingToWithdraw();
        owed[account] = 0;
        emit Withdrawn(account, msg.sender, amount);
        SafeTransferLib.safeTransferETH(account, amount);
    }

    function approve(address account, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.approve(account, id);
    }

    function transferFrom(address from, address to, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.transferFrom(from, to, id);
    }

    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (!_recordExists(tokenId)) return false;
        PageRecord storage r = records[tokenId];
        if (r.parent == 0) return block.timestamp <= r.expiresAt;
        PageRecord storage p = records[r.parent];
        if (r.parentEpoch != p.epoch) return false;
        return block.timestamp <= p.expiresAt;
    }

    function isExpired(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        return block.timestamp > uint256(records[tokenId].expiresAt) + GRACE_PERIOD;
    }

    function inGracePeriod(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        uint256 e = records[tokenId].expiresAt;
        return block.timestamp > e && block.timestamp <= e + GRACE_PERIOD;
    }

    function expiresAt(uint256 tokenId) public view returns (uint256) {
        return records[tokenId].expiresAt;
    }

    function _pointee(uint256 tokenId, address owner) internal view returns (address) {
        uint256 v = recordVersion[tokenId];
        address a = _resolvedAddress[tokenId][v];
        return (a != address(0) && _addrSaver[tokenId][v] == owner) ? a : owner;
    }

    function setAddr(uint256 tokenId, address a) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _saveAddr(tokenId, a);
    }

    function _saveAddr(uint256 tokenId, address a) internal {
        // this contract can move no tokens, so it is never a main address
        if (a == address(this)) revert InvalidRecipient();
        uint256 v = recordVersion[tokenId];
        _resolvedAddress[tokenId][v] = a;
        _addrSaver[tokenId][v] = msg.sender;
        // zero clears it, and the name then points at its owner
        address main = a == address(0) ? msg.sender : a;
        _emitAddr(tokenId, main);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    function setAddrForCoin(uint256 tokenId, uint256 coinType, bytes calldata a) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        bool evm = _isEvm(coinType);
        if (evm && a.length != 20 && a.length != 0) revert InvalidLength();
        if (coinType == COIN_TYPE_OP) return _saveAddr(tokenId, address(bytes20(a)));

        ChainAddress storage c = _coinAddr[tokenId][recordVersion[tokenId]][coinType];
        c.saver = msg.sender;
        c.value = evm && bytes20(a) == 0 ? bytes("") : a;
        emit AddressChanged(bytes32(tokenId), coinType, addr(tokenId, coinType));
        if (coinType == DEFAULT_EVM) emit AddressChanged(bytes32(tokenId), COIN_TYPE_ETH, addr(tokenId, COIN_TYPE_ETH));
    }

    function _emitAddr(uint256 tokenId, address a) internal {
        _emitCoin(tokenId, COIN_TYPE_OP, a);
        emit AddrChanged(bytes32(tokenId), a);
    }

    function _emitCoin(uint256 tokenId, uint256 coinType, address a) internal {
        emit AddressChanged(bytes32(tokenId), coinType, _encode(a));
    }

    // zero goes out as empty bytes, the standard way of saying no address
    function _encode(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function _isEvm(uint256 coinType) internal pure returns (bool) {
        return coinType == COIN_TYPE_ETH || (coinType >= DEFAULT_EVM && coinType <= 0xffffffff);
    }

    function addr(uint256 tokenId, uint256 coinType) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        address owner = ownerOf(tokenId);
        address main = _pointee(tokenId, owner);
        if (coinType == COIN_TYPE_OP) return _encode(main);
        if (_isEvm(coinType)) return _encode(_evmAnswer(tokenId, coinType, owner));
        ChainAddress storage c = _coinAddr[tokenId][recordVersion[tokenId]][coinType];
        return c.saver == owner ? c.value : bytes("");
    }

    function _evmAnswer(uint256 tokenId, uint256 coinType, address owner)
        internal
        view
        returns (address a)
    {
        mapping(uint256 => ChainAddress) storage saved = _coinAddr[tokenId][recordVersion[tokenId]];
        ChainAddress storage c = saved[coinType];
        if (c.saver == owner) a = address(bytes20(c.value));
        if (a == address(0)) {
            c = saved[DEFAULT_EVM];
            if (c.saver == owner) a = address(bytes20(c.value));
        }
    }

    function _isKeyWallet(address a) internal view returns (bool yes) {
        assembly ("memory-safe") {
            let size := extcodesize(a)
            yes := iszero(size)
            if eq(size, 23) {
                extcodecopy(a, 0x00, 0x00, 0x03)
                yes := eq(shr(232, mload(0x00)), 0xef0100)
            }
        }
    }

    function clearRecords(uint256 tokenId) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        uint256 newVersion = ++recordVersion[tokenId];
        emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        // with nothing saved the name points at its owner
        _emitAddr(tokenId, msg.sender);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    function setText(uint256 tokenId, string calldata key, string calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _text[tokenId][recordVersion[tokenId]][key] = value;
        emit TextChanged(bytes32(tokenId), key, key, value);
    }

    function setContenthash(uint256 tokenId, bytes calldata hash) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _contenthash[tokenId][recordVersion[tokenId]] = hash;
        emit ContenthashChanged(bytes32(tokenId), hash);
    }

    function resolve(uint256 tokenId) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, ownerOf(tokenId));
    }

    function resolveAs(uint256 tokenId, address account) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, account);
    }

    function text(uint256 tokenId, string calldata key) public view returns (string memory) {
        if (!_isActive(tokenId)) return "";
        return _text[tokenId][recordVersion[tokenId]][key];
    }

    function contenthash(uint256 tokenId) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        return _contenthash[tokenId][recordVersion[tokenId]];
    }

    /// @notice The main address, which is the OP address. Ethereum apps must call addr(node, 60).
    function addr(bytes32 node) public view returns (address) {
        return resolve(uint256(node));
    }

    function addr(bytes32 node, uint256 coinType) public view returns (bytes memory) {
        return addr(uint256(node), coinType);
    }

    function text(bytes32 node, string calldata key) public view returns (string memory) {
        return text(uint256(node), key);
    }

    function contenthash(bytes32 node) public view returns (bytes memory) {
        return contenthash(uint256(node));
    }

    function payee(uint256 tokenId) public view returns (address) {
        return _payee(tokenId);
    }

    function _payee(uint256 tokenId) internal view returns (address p) {
        p = _pointee(tokenId, _ownerOf(tokenId));
        if (p == address(0) || p == address(this)) p = DEAD;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721)
    {
        if (to == address(this)) revert InvalidRecipient();
        if (from != address(0) && to != address(0)) {
            if (!_isActive(tokenId)) revert Expired();
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721)
    {
        if (from == to) return;
        address was;
        address ethWas;
        if (from != address(0)) {
            was = _pointee(tokenId, from);
            ethWas = _evmAnswer(tokenId, COIN_TYPE_ETH, from);
        }
        address main;
        address eth;
        if (to != address(0)) {
            main = _pointee(tokenId, to);
            eth = _evmAnswer(tokenId, COIN_TYPE_ETH, to);
        }
        if (was != main) _emitAddr(tokenId, main);
        if (was != main || ethWas != eth || to == address(0)) {
            _emitCoin(tokenId, COIN_TYPE_ETH, eth);
        }
        if (from != address(0) && to != address(0)) emit MetadataUpdate(tokenId);
    }

    function setPrimaryPage(uint256 tokenId) public {
        if (tokenId == 0) { delete primaryPage[msg.sender]; emit PrimaryPageSet(msg.sender, 0); return; }
        if (!_isActive(tokenId)) revert Expired();
        if (msg.sender != ownerOf(tokenId) && msg.sender != resolve(tokenId)) revert Unauthorized();
        primaryPage[msg.sender] = tokenId;
        emit PrimaryPageSet(msg.sender, tokenId);
    }

    function reverseResolve(address a) public view returns (string memory) {
        uint256 tokenId = primaryPage[a];
        if (tokenId == 0 || !_isActive(tokenId) || resolve(tokenId) != a) return "";
        return _buildPageName(tokenId);
    }

    function getPageName(uint256 tokenId) public view returns (string memory) {
        return _buildPageName(tokenId);
    }

    function _buildPageName(uint256 tokenId) internal view returns (string memory) {
        if (!_recordExists(tokenId)) return "";
        PageRecord storage r = records[tokenId];
        if (r.parent == 0) return r.label;
        PageRecord storage p = records[r.parent];
        if (r.parentEpoch != p.epoch) return "";
        return string.concat(r.label, ".", p.label);
    }

    function _cardState(uint256 tokenId)
        internal
        view
        returns (PageCard.Status status, uint256 expiry, string memory parentLabel)
    {
        PageRecord storage r = records[tokenId];
        uint256 E;
        if (r.parent == 0) {
            E = r.expiresAt;
        } else {
            PageRecord storage p = records[r.parent];
            if (r.parentEpoch != p.epoch) return (PageCard.Status.Invalid, 0, p.label);
            parentLabel = p.label;
            E = p.expiresAt;
        }
        expiry = E;
        if (block.timestamp <= E) status = PageCard.Status.Active;
        else if (block.timestamp <= E + GRACE_PERIOD) status = PageCard.Status.Grace;
        else status = PageCard.Status.Expired;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        (PageCard.Status status, uint256 expiry, string memory parentLabel) = _cardState(tokenId);
        string memory label = records[tokenId].label;
        string memory displayName = bytes(parentLabel).length == 0 ? label : string.concat(label, ".", parentLabel);
        address p = _payee(tokenId);
        string memory shortPayee = card.shortAddress(p);
        string memory image = Base64.encode(bytes(card.render(label, parentLabel, bytes32(tokenId), status, expiry)));
        string memory n = _escapeJSON(displayName);
        string[4] memory statusNames = ["Active","Grace","Expired","Invalid"];
        bool top = records[tokenId].parent == 0;
        string memory attrs = string.concat(
            '[{"trait_type":"Type","value":"', top ? "Page" : "Subpage",
            '"},{"trait_type":"Status","value":"', statusNames[uint256(status)], '"}'
        );
        if (top) {
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Length","display_type":"number","value":', bytes(label).length.toString(),
                '},{"trait_type":"Expires","display_type":"date","value":', uint256(records[tokenId].expiresAt).toString(),
                '},{"trait_type":"Deposit","display_type":"number","value":', _formatEther(depositOf[tokenId]), "}"
            );
        }
        string memory json = string.concat(
            '{"name":"', n, '","description":"Etherpage: ', n, " (", shortPayee,
            ')","image":"data:image/svg+xml;base64,', image, '","attributes":', attrs, "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _escapeJSON(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        uint256 j;
        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x22 || c == 0x5c) { out[j++] = 0x5c; out[j++] = c; }
                else if (c == 0x09) { out[j++] = 0x5c; out[j++] = "t"; }
                else if (c == 0x0a) { out[j++] = 0x5c; out[j++] = "n"; }
                else if (c == 0x0d) { out[j++] = 0x5c; out[j++] = "r"; }
                else if (uint8(c) >= 0x20) out[j++] = c;
            }
        }
        assembly ("memory-safe") { mstore(out, j) }
        return string(out);
    }

    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e14;        // 0 to 9999
        if (frac == 0) return LibString.toString(whole);
        bytes memory digits = bytes(LibString.toString(frac));
        bytes memory padded = new bytes(4);
        uint256 pad = 4 - digits.length;
        for (uint256 i; i < pad; ++i) padded[i] = "0";
        for (uint256 i; i < digits.length; ++i) padded[pad + i] = digits[i];
        uint256 end = 4;
        while (padded[end - 1] == "0") --end;            // frac is not zero, so this loop ends
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) out[i] = padded[i];
        return string.concat(LibString.toString(whole), ".", string(out));
    }
}
