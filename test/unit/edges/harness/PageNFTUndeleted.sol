// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Base64} from "solady/utils/Base64.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PageCard} from "../../../../src/PageCard.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

// For gas comparisons only: src/PageNFT.sol without the _deleted function and its three uses.
/// @title Etherpage reference build for gas, without the deleted state
/// @notice Names on OP Mainnet. Each name is an ERC721 token with addresses for any chain, a profile and a website.
///         Every yearly fee paid for a top level name is added to a deposit the name keeps. Whoever registers the
///         name in its premium period pays that deposit to the last payee, and after that period it goes back to
///         the payee.
contract PageNFTUndeleted is ERC721, ReentrancyGuard {
    using LibString for uint256;

    // sends back what the caller paid above the price
    function _refundExcess(uint256 required) internal {
        if (msg.value > required) SafeTransferLib.safeTransferETH(msg.sender, msg.value - required);
    }

    // keccak256("etherpage.root.v1"), the root every top level name hangs from
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
    uint256 internal constant TRIAL_PERIOD = 14 days;
    uint256 internal constant TRIAL_DIVISOR = 10;
    uint256 internal constant TRIAL_PAUSE = 14 days;
    uint256 internal constant COIN_TYPE_ETH = 60;
    uint256 internal constant COIN_TYPE_OP = 0x8000000a;
    // the coin type of the default address for every EVM chain, always computed and never stored
    uint256 internal constant DEFAULT_EVM = 0x80000000;
    // the old referrer's share of a premium, 25 percent
    uint256 internal constant PREMIUM_REFERRER_BPS = 2500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct PageRecord {
        string label;        // lowercase a to z, 0 to 9 and the hyphen
        uint256 parent;      // 0 for a top level name
        uint64 expiresAt;    // 0 for a subpage, which follows its parent
        uint64 epoch;        // counts the registrations of this id
        uint64 parentEpoch;  // the parent's epoch when this subpage was made, 0 for a top level name
    }

    // an address on one chain and the account that saved it
    struct ChainAddress {
        address saver;
        bytes value;
    }

    // the price of a trial and the account that paid it, held until it is credited back
    struct TrialPayment {
        address payer;
        uint96 amount;
    }

    // the account whose text and website count, and a counter that moves to an empty profile
    // when another account writes
    struct Profile {
        address writer;
        uint96 version;
    }

    // the account allowed to mint subpages, the parent's epoch and the holder that picked it
    struct SubpageMinter {
        address minter;
        uint64 epoch;
        address setter;
    }

    // a data record and the account that saved it
    struct DataRecord {
        address saver;
        bytes value;
    }

    mapping(uint256 => PageRecord) public records;
    // bumped when a name is registered again or cleared, so every older record reads empty
    mapping(uint256 => uint256) public recordVersion;
    // the time each commitment was made
    mapping(bytes32 => uint256) public commitments;
    // the token id each account chose as its display name, which can be out of date, so reverseResolve checks it
    mapping(address => uint256) public primaryPage;
    // the referrer named at the last registration. When it is a top level name with a record, its payee gets 25
    // percent of any premium paid by the next registration, otherwise the dead address gets that share
    mapping(uint256 => uint256) public referrerOf;

    // the money a name holds: every yearly fee paid for it since its last release
    mapping(uint256 => uint256) public depositOf;
    // money credited to an account, collected with withdraw
    mapping(address => uint256) public owed;

    // records are kept per record version, and a saved address counts only while its saver holds the name
    mapping(uint256 => mapping(uint256 => address)) internal _resolvedAddress;
    mapping(uint256 => mapping(uint256 => bytes)) internal _contenthash;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => ChainAddress))) internal _coinAddr;
    mapping(uint256 => mapping(uint256 => mapping(string => string))) internal _text;
    mapping(uint256 => mapping(uint256 => address)) internal _addrSaver;

    // the minter counts only while the account that picked it holds the parent in the same registration
    mapping(uint256 => SubpageMinter) internal _subpageMinter;

    // the account that held the name when each account chose it as its display name
    mapping(address => address) internal _primaryHolder;

    // trial money held for its payer, never part of depositOf, zero once it is credited back
    mapping(uint256 => TrialPayment) public trialPaymentOf;

    // text and website count only while the profile's writer holds the name
    mapping(uint256 => Profile) internal _profile;

    // when the current holder got the name: the time of its latest mint, or of its latest transfer to another account
    mapping(uint256 => uint256) public holderSince;

    // when the addresses of the name were last saved or cleared, by setAddr, setAddrForCoin or clearRecords
    mapping(uint256 => uint256) public addressesUpdatedAt;

    // data records per record version and key, each counted only while the account that saved it holds the name
    mapping(uint256 => mapping(uint256 => mapping(string => DataRecord))) internal _data;

    // the card renderer, fixed at deployment
    PageCard public immutable card;

    function _recordExists(uint256 tokenId) internal view returns (bool) {
        return bytes(records[tokenId].label).length != 0;
    }

    // no grace period for a top level name with no deposit, which is a trial or a released name
    function _graceEnd(uint256 tokenId) internal view returns (uint256) {
        uint256 e = records[tokenId].expiresAt;
        return depositOf[tokenId] == 0 ? e : e + GRACE_PERIOD;
    }

    event PageRegistered(uint256 indexed tokenId, string label, address indexed owner, uint256 expiresAt);
    event SubpageRegistered(uint256 indexed tokenId, uint256 indexed parentId, string label);
    event PageRenewed(uint256 indexed tokenId, uint256 newExpiresAt);
    event PrimaryPageSet(address indexed addr, uint256 indexed tokenId);
    event Committed(bytes32 indexed commitment, address indexed committer);
    event ReferrerSet(uint256 indexed tokenId, uint256 indexed referrerId);
    event SubpageMinterSet(uint256 indexed parentId, address indexed account, address indexed minter, uint64 epoch);

    event DepositAdded(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 newTotal);
    event DepositBoughtOut(uint256 indexed tokenId, address indexed to, uint256 amount);
    event DepositReleased(uint256 indexed tokenId, address indexed to, uint256 amount);
    event ReferrerPremiumCredited(
        uint256 indexed tokenId, uint256 indexed referrerId, address indexed to, uint256 amount
    );
    event OwnerPremiumCredited(uint256 indexed tokenId, address indexed to, uint256 amount);
    event Withdrawn(address indexed account, address indexed caller, uint256 amount);
    event TrialStarted(uint256 indexed tokenId, address indexed payer, uint256 price);
    event TrialRefunded(uint256 indexed tokenId, address indexed payer, uint256 amount);

    /// @notice Carries the answer of addr with coin type 60 and always comes with AddressChanged for coin type 60.
    ///         The main address comes with AddressChanged for the OP coin type. Apps should not rely on events alone,
    ///         since some answers change with no event, for example on expiry.
    event AddrChanged(bytes32 indexed node, address addr);
    event ContenthashChanged(bytes32 indexed node, bytes contenthash);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes addr);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);
    // the value is indexed, so apps read it with data
    event DataChanged(bytes32 indexed node, string indexed indexedKey, string key, bytes indexed indexedData);
    event VersionChanged(bytes32 indexed node, uint64 newVersion);
    // fresh is true when the profile starts empty, false when the holder keeps the one it found
    event ProfileWriterChanged(bytes32 indexed node, address writer, bool fresh);

    // ERC4906, with the parameters unindexed as the standard declares them
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
    error Unpaid();
    error TrialNotAllowed();
    error AlreadyKept();

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0x3b3b57de   // addr(bytes32)
            || interfaceId == 0xf1cb7e06   // addr(bytes32,uint256)
            || interfaceId == 0x59d1d43c   // text(bytes32,string)
            || interfaceId == 0xbc1c58d1   // contenthash(bytes32)
            || interfaceId == 0x49064906   // ERC4906 metadata update
            || interfaceId == 0xecbfada3   // data(bytes32,string)
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

    /// @notice Runs each call on this contract in order, as the same caller and with its own checks.
    ///         Not payable, so no call can reuse a payment. The first failure reverts them all with its revert data.
    function multicall(bytes[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(this).delegatecall(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    function parentOf(uint256 tokenId) external view returns (uint256) {
        return records[tokenId].parent;
    }

    function epochOf(uint256 tokenId) external view returns (uint64) {
        return records[tokenId].epoch;
    }

    /// @notice The namehash of a name such as alice, or of a subpage such as bob.alice. The empty string gives ROOT.
    ///         A to Z are lowercased and an empty or third label reverts, but labels are not checked in any other way.
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

    /// @notice The label in lowercase. Reverts when it is not a valid label.
    function normalize(string calldata label) public pure returns (string memory) {
        return string(_validateAndNormalize(bytes(label)));
    }

    // err is 1 for a wrong length and 2 for any other invalid label
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

    /// @notice The yearly fee for a label of this length.
    function getFee(uint256 length) public pure returns (uint256) {
        if (length == 1) return FEE_LEN1;
        if (length == 2) return FEE_LEN2;
        if (length == 3) return FEE_LEN3;
        if (length == 4) return FEE_LEN4;
        return DEFAULT_FEE;
    }

    /// @notice The extra price of a paid name whose grace period has ended. It falls from 10 ETH to zero
    ///         over 21 days. The last payee gets 75 percent and the payee of the last referrer 25 percent, which
    ///         goes to the dead address when there is no top level referrer.
    function getPremium(uint256 tokenId) public view returns (uint256) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0 || depositOf[tokenId] == 0) return 0;
        uint256 graceEnd = records[tokenId].expiresAt + GRACE_PERIOD;
        if (block.timestamp <= graceEnd) return 0;
        uint256 elapsed = block.timestamp - graceEnd;
        if (elapsed >= PREMIUM_DECAY_PERIOD) return 0;
        return MAX_PREMIUM * (PREMIUM_DECAY_PERIOD - elapsed) / PREMIUM_DECAY_PERIOD;
    }

    /// @notice What reveal costs now: the yearly fee, plus in the premium period the deposit taken over from the
    ///         last registration and the premium. All zero for an invalid label. It does not check that the name
    ///         is free, and revealTrial costs only a tenth of the fee.
    function quote(string calldata label)
        external view
        returns (uint256 fee, uint256 carried, uint256 premium, uint256 total)
    {
        (uint256 err, bytes memory normalized) = _tryNormalize(bytes(label));
        if (err != 0) return (0, 0, 0, 0);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
        fee = getFee(normalized.length);
        bool inAuction = block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD && block.timestamp <= _auctionEnd(id);
        carried = (_recordExists(id) && inAuction) ? depositOf[id] : 0;
        premium = getPremium(id);
        total = fee + carried + premium;
    }

    /// @notice Whether the label is free now, as a top level name when parentId is 0, else as a subpage of parentId,
    ///         which must be live and paid. A subpage held by the dead address counts as free. revealTrial has further
    ///         limits.
    function isAvailable(string calldata label, uint256 parentId) public view returns (bool) {
        (uint256 err, bytes memory normalized) = _tryNormalize(bytes(label));
        if (err != 0) return false;
        if (parentId == 0) {
            uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
            if (!_recordExists(id)) return true;
            return block.timestamp > _graceEnd(id);
        } else {
            if (!_recordExists(parentId)) return false;
            PageRecord storage p = records[parentId];
            if (p.parent != 0) return false;
            if (!_isActive(parentId) || depositOf[parentId] == 0) return false;
            uint256 id = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(normalized))));
            if (!_recordExists(id)) return true;
            // a live subpage held by DEAD counts as free
            return records[id].parentEpoch != p.epoch || _ownerOf(id) == DEAD;
        }
    }

    /// @notice Records the time of a commitment. The same commitment can be made again once it is used or more
    ///         than a day old.
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

    /// @notice The commitment to pass to commit before reveal. revealTrial takes its own commitment instead:
    ///         keccak256(abi.encode(label in lowercase, owner, referrerId, secret, true)).
    function makeCommitment(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        public pure returns (bytes32)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        if (referrerId == uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))))) {
            revert SelfReferral();
        }
        return _commitmentHash(normalized, owner, referrerId, secret);
    }

    /// @notice Registers the label for owner for one year, paid by the caller, 20 seconds to one day after commit.
    ///         The price is the quote: the yearly fee, which is added to the name's deposit, plus any deposit taken
    ///         over and any premium. After the premium period a deposit still in the name first goes back to its
    ///         payee. Anything paid above it is sent back.
    function reveal(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external payable nonReentrant returns (uint256 tokenId)
    {
        return _registerTopLevel(label, owner, referrerId, secret);
    }

    /// @notice Registers the label for owner as a 14 day trial for a tenth of the yearly fee, 20 seconds to one day
    ///         after committing its trial commitment (see makeCommitment). That money is held and later credited
    ///         back to the caller. Until someone renews it before it ends, the name has no grace period, no subpages
    ///         and moves only to the dead address. Refused while a paid name is live, in grace or in its premium
    ///         period, or until 14 days after its last registration ended. After the premium period a deposit
    ///         still in the name first goes back to its payee.
    function revealTrial(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external payable nonReentrant returns (uint256 tokenId)
    {
        return _registerTopLevel(label, owner, referrerId, secret);
    }

    function _registerTopLevel(string calldata label, address to, uint256 referrerId, bytes32 secret)
        internal returns (uint256 tokenId)
    {
        // read at run time, as a constant argument would make the compiler copy the whole body
        bool trial = msg.sig == this.revealTrial.selector;
        bytes memory normalized = _validateAndNormalize(bytes(label));
        uint256 fee = getFee(normalized.length);
        if (trial) fee /= TRIAL_DIVISOR;
        tokenId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
        if (referrerId == tokenId) revert SelfReferral();
        // after the premium period a deposit still in the name goes back to its payee first
        if (depositOf[tokenId] != 0 && block.timestamp > _auctionEnd(tokenId)) _releaseDeposit(tokenId);
        // the deposit of the last registration, which this one buys out and keeps
        uint256 carried = depositOf[tokenId];
        // a trial never takes over a deposit
        if (trial && carried != 0) revert TrialNotAllowed();
        uint256 premium = getPremium(tokenId);
        uint256 total = fee + carried + premium;
        if (msg.value < total) revert InsufficientFee();
        // a trial has its own commitment, which only the full values give, so a paid commitment never serves a trial
        // and cannot be turned into one by anyone who only saw it
        bytes32 c = _commitmentHash(normalized, to, referrerId, secret);
        if (trial) c = keccak256(abi.encode(normalized, to, referrerId, secret, true));
        uint256 committedAt = commitments[c];
        if (committedAt == 0) revert CommitmentNotFound();
        if (block.timestamp < committedAt + MIN_COMMITMENT_AGE) revert CommitmentTooNew();
        if (block.timestamp > committedAt + MAX_COMMITMENT_AGE) revert CommitmentTooOld();
        delete commitments[c];
        // free after the grace period, or as soon as an unpaid trial ends
        bool existed = _recordExists(tokenId);
        if (existed && block.timestamp <= _graceEnd(tokenId)) revert AlreadyRegistered();
        // no new trial until fourteen days after the last registration ended
        if (trial && existed && block.timestamp <= uint256(records[tokenId].expiresAt) + TRIAL_PAUSE) revert TrialNotAllowed();
        uint256 oldReferrer = referrerOf[tokenId];
        address oldPayee = _payee(tokenId);
        address refPayee = _referrerPayee(oldReferrer);
        // the last payee gets the deposit taken over and 75 percent of the premium, the last referrer 25 percent
        address t1 = _credit(oldPayee, carried);
        if (t1 != address(0)) emit DepositBoughtOut(tokenId, t1, carried);
        uint256 refShare = premium * PREMIUM_REFERRER_BPS / BPS_DENOMINATOR;
        uint256 ownerShare = premium - refShare;
        address t2 = _credit(refPayee, refShare);
        if (t2 != address(0)) emit ReferrerPremiumCredited(tokenId, oldReferrer, t2, refShare);
        address t3 = _credit(oldPayee, ownerShare);
        if (t3 != address(0)) emit OwnerPremiumCredited(tokenId, t3, ownerShare);
        // money still held for an ended trial goes back to its payer
        _refundTrial(tokenId);
        uint64 newEpoch = existed ? records[tokenId].epoch + 1 : 1;
        if (existed) {
            // the last holder loses the name and stops showing it as its display name, and every address, text and
            // website saved before stops counting
            address oldOwner = _ownerOf(tokenId);
            if (primaryPage[oldOwner] == tokenId) {
                delete primaryPage[oldOwner];
                emit PrimaryPageSet(oldOwner, 0);
            }
            _burn(tokenId);
            uint256 newVersion = ++recordVersion[tokenId];
            emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        }
        records[tokenId] = PageRecord({
            label: string(normalized),
            parent: 0,
            expiresAt: uint64(block.timestamp + (trial ? TRIAL_PERIOD : REGISTRATION_PERIOD)),
            epoch: newEpoch,
            parentEpoch: 0
        });
        referrerOf[tokenId] = referrerId;
        emit ReferrerSet(tokenId, referrerId);
        if (trial) {
            // trial money is held for the payer outside the deposit.
            // It is at most a tenth of the largest fee, so it fits in 96 bits.
            trialPaymentOf[tokenId] = TrialPayment(msg.sender, uint96(fee));
            emit TrialStarted(tokenId, msg.sender, fee);
        } else {
            depositOf[tokenId] += fee;
            emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId]);
        }
        _mintTo(to, tokenId);
        emit PageRegistered(tokenId, string(normalized), to, records[tokenId].expiresAt);
        emit MetadataUpdate(tokenId);
        _refundExcess(total);
    }

    // skips the ERC721 receiver check when the caller takes the name itself, or when the receiver is a key wallet,
    // which can always move it. Any other receiver with code must accept ERC721 tokens.
    function _mintTo(address to, uint256 tokenId) internal {
        if (to == msg.sender || _isKeyWallet(to)) _mint(to, tokenId);
        else _safeMint(to, tokenId);
    }

    /// @notice Anyone may add a year to a top level name before its grace period ends, paying the yearly fee into its
    ///         deposit. The new expiry may be at most 3650 days ahead. Renewing a trial before it ends makes it a
    ///         normal name and credits the trial money back to its payer.
    function renew(uint256 tokenId) external payable nonReentrant {
        PageRecord storage record = records[tokenId];
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        if (record.parent != 0) revert NotTopLevel();
        if (block.timestamp > _graceEnd(tokenId)) revert Expired();
        uint256 fee = getFee(bytes(record.label).length);
        if (msg.value < fee) revert InsufficientFee();
        uint256 newExpiry = uint256(record.expiresAt) + REGISTRATION_PERIOD;
        if (newExpiry > block.timestamp + MAX_EXPIRY_HORIZON) revert RenewalTooFar();
        record.expiresAt = uint64(newExpiry);
        _refundTrial(tokenId);
        depositOf[tokenId] += fee;
        emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId]);
        emit PageRenewed(tokenId, record.expiresAt);
        emit MetadataUpdate(tokenId);
        _refundExcess(fee);
    }

    /// @notice Creates a subpage for the caller under a live, paid top level name. Only the parent's holder or its
    ///         subpage minter may call. The holder may also replace a live subpage, while the minter only creates
    ///         free ones.
    function registerSubpage(string calldata label, uint256 parentId)
        external nonReentrant returns (uint256 tokenId)
    {
        return _registerSubpage(label, parentId, msg.sender);
    }

    /// @notice Same as registerSubpage, but the subpage goes to the account to.
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
        if (!_recordExists(parentId)) revert TokenDoesNotExist();
        PageRecord storage p = records[parentId];
        if (p.parent != 0) revert NotTopLevel();
        if (block.timestamp > p.expiresAt) revert Expired();
        // no subpages under a trial
        if (depositOf[parentId] == 0) revert Unpaid();
        // the parent's holder, or the minter it picked
        address owner = _ownerOf(parentId);
        bool byMinter = owner != msg.sender;
        if (byMinter && (msg.sender == address(0) || _minterFor(parentId, owner) != msg.sender)) revert NotParentOwner();
        tokenId = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(normalized))));
        uint64 newEpoch = 1;
        if (_recordExists(tokenId)) {
            // a minter only creates, it never overwrites a live subpage unless DEAD holds it
            if (byMinter && records[tokenId].parentEpoch == p.epoch && _ownerOf(tokenId) != DEAD) {
                revert AlreadyRegistered();
            }
            // the last holder loses the subpage and stops showing it as its display name, and every address, text and
            // website saved before stops counting
            newEpoch = records[tokenId].epoch + 1;
            address oldOwner = _ownerOf(tokenId);
            if (primaryPage[oldOwner] == tokenId) {
                delete primaryPage[oldOwner];
                emit PrimaryPageSet(oldOwner, 0);
            }
            _burn(tokenId);
            uint256 newVersion = ++recordVersion[tokenId];
            emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        }
        records[tokenId] = PageRecord({
            label: string(normalized),
            parent: parentId,
            expiresAt: 0,
            epoch: newEpoch,
            parentEpoch: p.epoch
        });
        _mintTo(to, tokenId);
        emit SubpageRegistered(tokenId, parentId, string(normalized));
    }

    /// @notice The holder picks one account that may also mint subpages of a top level name, and may replace
    ///         or clear it. Picking one needs the name to be live. After the name has moved, the account that picked
    ///         it may only clear it.
    function setSubpageMinter(uint256 parentId, address minter) external {
        if (!_recordExists(parentId)) revert TokenDoesNotExist();
        PageRecord storage p = records[parentId];
        if (p.parent != 0) revert NotTopLevel();
        if (minter != address(0) && block.timestamp > p.expiresAt) revert Expired();
        // approved accounts and operators cannot pick a minter
        if (_ownerOf(parentId) != msg.sender) {
            if (minter != address(0) || _subpageMinter[parentId].setter != msg.sender) revert Unauthorized();
        }
        uint64 epoch = p.epoch;
        _subpageMinter[parentId] = SubpageMinter(minter, epoch, msg.sender);
        emit SubpageMinterSet(parentId, msg.sender, minter, epoch);
    }

    /// @notice The minter that counts now, or zero unless the account that picked it holds the name in the
    ///         same registration. Never reverts and ignores expiry.
    function subpageMinterOf(uint256 parentId) external view returns (address) {
        return _minterFor(parentId, _ownerOf(parentId));
    }

    function _minterFor(uint256 parentId, address owner) internal view returns (address) {
        SubpageMinter storage m = _subpageMinter[parentId];
        if (m.setter != owner || m.epoch != records[parentId].epoch) return address(0);
        return m.minter;
    }

    // the referrer's payee, or DEAD when there is no top level referrer
    function _referrerPayee(uint256 refId) internal view returns (address) {
        if (refId == 0) return DEAD;
        if (!_recordExists(refId)) return DEAD;
        if (records[refId].parent != 0) return DEAD;
        return _payee(refId);
    }

    // credits an account, with zero and this contract replaced by DEAD; returns who got it, or zero for nothing
    function _credit(address account, uint256 amount) internal returns (address to) {
        if (amount == 0) return address(0);
        to = account;
        if (to == address(0) || to == address(this)) to = DEAD;
        owed[to] += amount;
    }

    // credits the money still held for a trial, if any, back to the account that paid it
    function _refundTrial(uint256 tokenId) internal {
        TrialPayment memory t = trialPaymentOf[tokenId];
        if (t.amount == 0) return;
        delete trialPaymentOf[tokenId];
        address to = _credit(t.payer, t.amount);
        emit TrialRefunded(tokenId, to, t.amount);
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

    /// @notice After a name's grace and premium periods, credits its deposit to its payee. A new registration after
    ///         those periods does this by itself. For an unpaid trial that has ended, credits the trial money back
    ///         to its payer instead. Anyone may call it.
    function release(uint256 tokenId) external nonReentrant {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        PageRecord storage r = records[tokenId];
        if (r.parent != 0) revert NotTopLevel();
        if (trialPaymentOf[tokenId].amount != 0) {
            if (block.timestamp <= r.expiresAt) revert NotReleasable();
            _refundTrial(tokenId);
            return;
        }
        if (block.timestamp <= _auctionEnd(tokenId)) revert NotReleasable();
        if (depositOf[tokenId] == 0) revert NothingToRelease();
        _releaseDeposit(tokenId);
        emit MetadataUpdate(tokenId);
    }

    function isReleasable(uint256 tokenId) external view returns (bool) {
        if (!_recordExists(tokenId)) return false;
        PageRecord storage r = records[tokenId];
        if (r.parent != 0) return false;
        if (trialPaymentOf[tokenId].amount != 0) return block.timestamp > r.expiresAt;
        if (block.timestamp <= _auctionEnd(tokenId)) return false;
        return depositOf[tokenId] != 0;
    }

    /// @notice Sends an account all the money credited to it. Anyone may call it for any account.
    function withdraw(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingToWithdraw();
        owed[account] = 0;
        emit Withdrawn(account, msg.sender, amount);
        SafeTransferLib.safeTransferETH(account, amount);
    }

    /// @notice Refuses ETH.
    function approve(address account, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.approve(account, id);
    }

    /// @notice Refuses ETH. Both forms of safeTransferFrom go through this function.
    function transferFrom(address from, address to, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.transferFrom(from, to, id);
    }

    // a top level name is active until it expires, not during its grace period. A subpage is active while its parent
    // is, in the registration it was made in.
    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (!_recordExists(tokenId)) return false;
        PageRecord storage r = records[tokenId];
        if (r.parent == 0) return block.timestamp <= r.expiresAt;
        PageRecord storage p = records[r.parent];
        if (r.parentEpoch != p.epoch) return false;
        return block.timestamp <= p.expiresAt;
    }

    /// @notice True once a top level name is past its grace period, or an unpaid trial has ended.
    ///         Always false for a subpage.
    function isExpired(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        return block.timestamp > _graceEnd(tokenId);
    }

    function inGracePeriod(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        uint256 e = records[tokenId].expiresAt;
        return block.timestamp > e && block.timestamp <= _graceEnd(tokenId);
    }

    function expiresAt(uint256 tokenId) public view returns (uint256) {
        return records[tokenId].expiresAt;
    }

    // the saved main address while its saver holds the name, else the holder
    function _pointee(uint256 tokenId, address owner) internal view returns (address) {
        uint256 v = recordVersion[tokenId];
        address a = _resolvedAddress[tokenId][v];
        return (a != address(0) && _addrSaver[tokenId][v] == owner) ? a : owner;
    }

    /// @notice Sets the main address, which is the OP address. It counts only while the caller holds the name,
    ///         and zero points the name back at its holder.
    function setAddr(uint256 tokenId, address a) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _saveAddr(tokenId, a);
    }

    function _saveAddr(uint256 tokenId, address a) internal {
        // tokens sent to this contract could never leave it, so it is never a main address
        if (a == address(this)) revert InvalidRecipient();
        uint256 v = recordVersion[tokenId];
        _resolvedAddress[tokenId][v] = a;
        _addrSaver[tokenId][v] = msg.sender;
        addressesUpdatedAt[tokenId] = block.timestamp;
        // zero clears it, and the name then points at its owner
        address main = a == address(0) ? msg.sender : a;
        _emitCoin(tokenId, COIN_TYPE_OP, main);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets the address for one chain. It counts only while the caller holds the name. The OP coin type
    ///         sets the main address and the default EVM coin type cannot be set. An EVM address must be 20 bytes or
    ///         empty, and empty or zero clears it.
    function setAddrForCoin(uint256 tokenId, uint256 coinType, bytes calldata a) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        bool evm = _isEvm(coinType);
        if (evm && a.length != 20 && a.length != 0) revert InvalidLength();
        if (coinType == COIN_TYPE_OP) return _saveAddr(tokenId, address(bytes20(a)));

        ChainAddress storage c = _coinAddr[tokenId][recordVersion[tokenId]][coinType];
        c.saver = msg.sender;
        c.value = evm && bytes20(a) == 0 ? bytes("") : a;
        addressesUpdatedAt[tokenId] = block.timestamp;
        if (coinType != COIN_TYPE_ETH) emit AddressChanged(bytes32(tokenId), coinType, addr(tokenId, coinType));
        if (coinType == COIN_TYPE_ETH || coinType == DEFAULT_EVM) {
            _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        }
    }

    // announces the address of one EVM chain, and the address of coin type 60 also as AddrChanged
    function _emitCoin(uint256 tokenId, uint256 coinType, address a) internal {
        emit AddressChanged(bytes32(tokenId), coinType, _encode(a));
        if (coinType == COIN_TYPE_ETH) emit AddrChanged(bytes32(tokenId), a);
    }

    // zero goes out as empty bytes, the standard way of saying no address
    function _encode(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    // Ethereum, or any coin type from 0x80000000 to 0xffffffff
    function _isEvm(uint256 coinType) internal pure returns (bool) {
        return coinType == COIN_TYPE_ETH || (coinType >= DEFAULT_EVM && coinType <= 0xffffffff);
    }

    /// @notice The address on one chain, empty when the name is not active. The OP coin type always answers the main
    ///         address. Any other EVM chain with no address saved by the holder answers the main address only when it
    ///         is a key wallet.
    function addr(uint256 tokenId, uint256 coinType) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        address owner = ownerOf(tokenId);
        address main = _pointee(tokenId, owner);
        if (coinType == COIN_TYPE_OP) return _encode(main);
        if (_isEvm(coinType)) return _encode(_evmAnswer(tokenId, coinType, owner));
        ChainAddress storage c = _coinAddr[tokenId][recordVersion[tokenId]][coinType];
        return c.saver == owner ? c.value : bytes("");
    }

    // the address the holder saved for this chain, else nothing.
    // which has the same address on every EVM chain
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

    // a best guess at an account run by a key: no code, or the 23 byte EIP7702 delegation that starts with 0xef0100.
    // An undeployed contract account, or a contract still in its constructor, has no code and counts too.
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

    /// @notice Clears every address, text, website and data record of the name at once.
    function clearRecords(uint256 tokenId) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        uint256 newVersion = ++recordVersion[tokenId];
        emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        addressesUpdatedAt[tokenId] = block.timestamp;
        // with nothing saved the name points at its owner
        _emitCoin(tokenId, COIN_TYPE_OP, msg.sender);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets a text record. Writing over a profile left by another holder starts an empty profile.
    function setText(uint256 tokenId, string calldata key, string calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _text[tokenId][_writeSlot(tokenId)][key] = value;
        emit TextChanged(bytes32(tokenId), key, key, value);
    }

    /// @notice Sets the website. Writing over a profile left by another holder starts an empty profile.
    function setContenthash(uint256 tokenId, bytes calldata hash) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _contenthash[tokenId][_writeSlot(tokenId)] = hash;
        emit ContenthashChanged(bytes32(tokenId), hash);
    }

    /// @notice Sets a data record. Like an address, it counts only while the caller holds the name, so it never
    ///         carries over to a new holder, and keepProfile does not bring it back.
    function setData(uint256 tokenId, string calldata key, bytes calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key];
        d.saver = msg.sender;
        d.value = value;
        emit DataChanged(bytes32(tokenId), key, key, value);
    }

    /// @notice The holder takes the profile it found as its own, so its text and website count again.
    ///         It cannot bring back what clearRecords or a new registration emptied, and data records never come
    ///         back with it.
    function keepProfile(uint256 tokenId) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        Profile storage p = _profile[tokenId];
        if (p.writer == msg.sender) revert AlreadyKept();
        p.writer = msg.sender;
        emit ProfileWriterChanged(bytes32(tokenId), msg.sender, false);
    }

    // the storage key of a profile: the record version above the profile counter
    function _slot(uint256 tokenId, uint256 version) internal view returns (uint256) {
        return recordVersion[tokenId] << 96 | version;
    }

    // a holder writing over someone else's profile starts an empty one
    function _writeSlot(uint256 tokenId) internal returns (uint256) {
        Profile storage p = _profile[tokenId];
        if (p.writer != msg.sender) {
            if (p.writer != address(0)) ++p.version;
            p.writer = msg.sender;
            emit ProfileWriterChanged(bytes32(tokenId), msg.sender, true);
        }
        return _slot(tokenId, p.version);
    }

    // the slot to read, with ok false when the name is not active or the profile's writer does not hold it
    function _readSlot(uint256 tokenId) internal view returns (bool ok, uint256 slot) {
        Profile storage p = _profile[tokenId];
        ok = _isActive(tokenId) && p.writer == _ownerOf(tokenId);
        slot = _slot(tokenId, p.version);
    }

    /// @notice The account whose text and website count while it holds the name.
    function profileWriter(uint256 tokenId) external view returns (address) {
        return _profile[tokenId].writer;
    }

    /// @notice The main address: the saved one while its saver holds the name, else the holder.
    ///         Zero when the name is not active.
    function resolve(uint256 tokenId) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, ownerOf(tokenId));
    }

    /// @notice What resolve would answer if account held the name.
    function resolveAs(uint256 tokenId, address account) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, account);
    }

    /// @notice Empty unless the name is active and the profile's writer holds it.
    function text(uint256 tokenId, string calldata key) public view returns (string memory) {
        (bool ok, uint256 slot) = _readSlot(tokenId);
        return ok ? _text[tokenId][slot][key] : "";
    }

    /// @notice Empty unless the name is active and the profile's writer holds it.
    function contenthash(uint256 tokenId) public view returns (bytes memory) {
        (bool ok, uint256 slot) = _readSlot(tokenId);
        return ok ? _contenthash[tokenId][slot] : bytes("");
    }

    /// @notice A data record. Empty unless the name is active and the account that saved the record holds it.
    function data(bytes32 node, string calldata key) external view returns (bytes memory) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return "";
        DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key];
        return d.saver == _ownerOf(tokenId) ? d.value : bytes("");
    }

    /// @notice The same answer as addr with coin type 60: the address saved for it, else the holder's default for
    ///         every EVM chain, else zero. The main address is resolve.
    function addr(bytes32 node) public view returns (address) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return address(0);
        return _evmAnswer(tokenId, COIN_TYPE_ETH, ownerOf(tokenId));
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

    /// @notice The account this contract pays for the name, also after it expires. It is the saved main address while
    ///         its saver holds the name, else the holder, with zero and this contract replaced by the dead address.
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
            // a trial moves only once it is paid, or to the dead address
            if (records[tokenId].parent == 0 && depositOf[tokenId] == 0 && to != DEAD) revert Unpaid();
        }
    }

    // records when the new holder got the name, on a mint or a transfer to another account. Announces the main and
    // Ethereum addresses when a mint, transfer or burn changes them, while answers for other chains can change with
    // the holder too but get no event
    function _afterTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721)
    {
        if (from == to) return;
        if (to != address(0)) holderSince[tokenId] = block.timestamp;
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
        if (was != main) _emitCoin(tokenId, COIN_TYPE_OP, main);
        if (was != main || ethWas != eth || to == address(0)) {
            _emitCoin(tokenId, COIN_TYPE_ETH, eth);
        }
        if (from != address(0) && to != address(0)) {
            // the sender stops showing this name as its display name
            if (primaryPage[from] == tokenId) {
                delete primaryPage[from];
                emit PrimaryPageSet(from, 0);
            }
            emit MetadataUpdate(tokenId);
        }
    }

    /// @notice Chooses the caller's display name; 0 clears it. The caller must hold the name or be its main address.
    function setPrimaryPage(uint256 tokenId) public {
        if (tokenId == 0) {
            delete primaryPage[msg.sender];
            emit PrimaryPageSet(msg.sender, 0);
            return;
        }
        if (!_isActive(tokenId)) revert Expired();
        address holder = ownerOf(tokenId);
        if (msg.sender != holder && msg.sender != resolve(tokenId)) revert Unauthorized();
        primaryPage[msg.sender] = tokenId;
        _primaryHolder[msg.sender] = holder;
        emit PrimaryPageSet(msg.sender, tokenId);
    }

    /// @notice The display name of an address. Shown only while the name is active, still held by the account
    ///         that held it when it was chosen, and still points at the address.
    function reverseResolve(address a) public view returns (string memory) {
        uint256 tokenId = primaryPage[a];
        if (tokenId == 0 || !_isActive(tokenId) || _ownerOf(tokenId) != _primaryHolder[a] || resolve(tokenId) != a) {
            return "";
        }
        return _buildPageName(tokenId);
    }

    /// @notice The name, or sub.parent for a subpage. Empty for an unknown id, or for a subpage of an earlier
    ///         registration of its parent.
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

    // a subpage follows its parent's expiry and grace, and is Invalid when its parent was registered again
    function _cardState(uint256 tokenId)
        internal
        view
        returns (PageCard.Status st, uint256 expiry, string memory parentLabel)
    {
        PageRecord storage r = records[tokenId];
        uint256 E;
        uint256 graceEnd;
        if (r.parent == 0) {
            E = r.expiresAt;
            graceEnd = _graceEnd(tokenId);
        } else {
            PageRecord storage p = records[r.parent];
            parentLabel = p.label;
            if (r.parentEpoch != p.epoch) return (PageCard.Status.Invalid, 0, parentLabel);
            E = p.expiresAt;
            graceEnd = E + GRACE_PERIOD;
        }
        expiry = E;
        if (block.timestamp <= E) {
            // a live top level name with no deposit is a trial
            st = r.parent == 0 && depositOf[tokenId] == 0 ? PageCard.Status.Trial : PageCard.Status.Active;
        } else if (block.timestamp <= graceEnd) {
            st = PageCard.Status.Grace;
        } else {
            st = PageCard.Status.Expired;
        }
    }

    /// @notice The status the metadata shows, for apps that need only that.
    function status(uint256 tokenId) external view returns (PageCard.Status s) {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        (s,,) = _cardState(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();
        (PageCard.Status st, uint256 expiry, string memory parentLabel) = _cardState(tokenId);
        string memory label = records[tokenId].label;
        string memory displayName = bytes(parentLabel).length == 0 ? label : string.concat(label, ".", parentLabel);
        address p = _payee(tokenId);
        string memory shortPayee = card.shortAddress(p);
        string memory image = Base64.encode(bytes(card.render(label, parentLabel, bytes32(tokenId), st, expiry)));
        string memory n = _escapeJSON(displayName);
        string[5] memory statusNames = ["Active","Grace","Expired","Invalid","Trial"];
        bool top = records[tokenId].parent == 0;
        string memory attrs = string.concat(
            '[{"trait_type":"Type","value":"', top ? "Page" : "Subpage",
            '"},{"trait_type":"Status","value":"', statusNames[uint256(st)], '"}'
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
            top ? ")" : string.concat("). This subpage relies on ", parentLabel, "'s holder, who can take it away."),
            '","image":"data:image/svg+xml;base64,', image, '","attributes":', attrs, "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // escapes double quotes, backslashes, tabs and line breaks, and drops every other byte below 0x20
    function _escapeJSON(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        uint256 j;
        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x22 || c == 0x5c) {
                    out[j++] = 0x5c;
                    out[j++] = c;
                } else if (c == 0x09) {
                    out[j++] = 0x5c;
                    out[j++] = "t";
                } else if (c == 0x0a) {
                    out[j++] = 0x5c;
                    out[j++] = "n";
                } else if (c == 0x0d) {
                    out[j++] = 0x5c;
                    out[j++] = "r";
                } else if (uint8(c) >= 0x20) out[j++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(out, j)
        }
        return string(out);
    }

    // ETH with up to four decimals, cut rather than rounded, and no trailing zeros. The fraction runs from 1 to
    // 9999 after the first return. Adding 10000 to it keeps its leading zeros behind a 1, and that 1 then becomes the
    // point. The loop that drops zeros stops at the fraction's last nonzero digit, so a decimal always follows it.
    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e14;
        if (frac == 0) return LibString.toString(whole);
        uint256 shifted = frac + 1e4;
        while (shifted % 10 == 0) shifted /= 10;
        bytes memory decimals = bytes(LibString.toString(shifted));
        decimals[0] = ".";
        return string.concat(LibString.toString(whole), string(decimals));
    }
}
