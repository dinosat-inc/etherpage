// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Base64} from "solady/utils/Base64.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PageCard} from "./PageCard.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

/**
 * @title Etherpage
 * @notice Etherpage gives people, projects and apps simple onchain pages. Each page is an NFT that holds addresses for
 * any chain, a profile and a website. Every yearly fee goes into a deposit that stays with the page. After the grace
 * period the deposit always goes back to the payee, when the page is registered again or released.
 * This software is provided as is, without warranty. Use at your own risk.
 */
contract PageNFT is ERC721, ReentrancyGuard {
    using LibString for uint256;

    /**
     * @dev Sends back what the caller paid above the price.
     */
    function _refundExcess(uint256 required) internal {
        if (msg.value > required) SafeTransferLib.safeTransferETH(msg.sender, msg.value - required);
    }

    /**
     * @notice The keccak256 hash of the text etherpage.root.v1, the root every top level page hangs from.
     */
    bytes32 public constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 internal constant MIN_LABEL_LENGTH = 1;
    uint256 internal constant MAX_LABEL_LENGTH = 63;
    /**
     * @dev The shortest wait between a commitment and its reveal.
     */
    uint256 internal constant MIN_COMMITMENT_AGE = 20;

    /**
     * @dev The longest wait between a commitment and its reveal. After it the same commitment can be made again.
     */
    uint256 internal constant MAX_COMMITMENT_AGE = 86400;
    uint256 internal constant REGISTRATION_PERIOD = 365 days;
    uint256 internal constant GRACE_PERIOD = 90 days;

    /**
     * @dev A renewal may not push the expiry further ahead than this.
     */
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

    /**
     * @dev No new trial of a page until this long after its last registration ended.
     */
    uint256 internal constant TRIAL_PAUSE = 14 days;

    uint256 internal constant COIN_TYPE_ETH = 60;

    /**
     * @dev The coin type of the home chain, chain id 10. The address saved for it is the main address.
     */
    uint256 internal constant COIN_TYPE_OP = 0x8000000a;

    /**
     * @dev The coin type of the holder's default for every EVM chain but the home chain that has no entry of its own.
     */
    uint256 internal constant DEFAULT_EVM = 0x80000000;

    /**
     * @dev The share of a premium that goes to the payee of the last referrer, 25 percent.
     */
    uint256 internal constant PREMIUM_REFERRER_BPS = 2500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /**
     * @dev The dead address. Money credited to it can only be burned, and a page it holds is deleted.
     */
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /**
     * @dev The record of a top level page or a subpage.
     * @param label Lowercase a to z, 0 to 9 and the hyphen.
     * @param parent The parent id, or 0 for a top level page.
     * @param expiresAt When a top level page expires, before any grace period, or 0 for a subpage, which follows its
     * parent.
     * @param epoch Counts the registrations of this id.
     * @param parentEpoch The epoch of the parent when this subpage was made, or 0 for a top level page.
     */
    struct PageRecord {
        string label;
        uint256 parent;
        uint64 expiresAt;
        uint64 epoch;
        uint64 parentEpoch;
    }

    /**
     * @dev An address on one chain and the account that saved it.
     */
    struct ChainAddress {
        address saver;
        bytes value;
    }

    /**
     * @dev The price of a trial and the account that paid it, held until it is credited back. It is at most a tenth of
     * the largest fee, so 96 bits hold it.
     */
    struct TrialPayment {
        address payer;
        uint96 amount;
    }

    /**
     * @dev The account whose text and website count, and a counter that moves to an empty profile when another account
     * writes.
     */
    struct Profile {
        address writer;
        uint96 version;
    }

    /**
     * @dev The account allowed to mint subpages, the epoch of the parent when it was picked and the holder that picked
     * it.
     */
    struct SubpageMinter {
        address minter;
        uint64 epoch;
        address setter;
    }

    /**
     * @dev A data record and the account that saved it.
     */
    struct DataRecord {
        address saver;
        bytes value;
    }

    mapping(uint256 => PageRecord) public records;

    /**
     * @notice Goes up when a page is registered again, a subpage is minted again or clearRecords is called, so every
     * address, text, website and data record saved before stops counting for good.
     */
    mapping(uint256 => uint256) public recordVersion;

    /**
     * @notice The time each commitment was made.
     */
    mapping(bytes32 => uint256) public commitments;

    /**
     * @notice The token id each account chose as its display page. It can be out of date, so apps should read
     * reverseResolve, which checks it.
     */
    mapping(address => uint256) public primaryPage;

    /**
     * @notice The referrer named at the last registration. When it is a top level page with a record, its payee gets 25
     * percent of any premium paid by the next registration. Otherwise that share is burned.
     */
    mapping(uint256 => uint256) public referrerOf;

    /**
     * @notice The money a page holds, which is every yearly fee paid for it since its last release.
     */
    mapping(uint256 => uint256) public depositOf;

    /**
     * @notice Money credited to each account, collected with withdraw.
     */
    mapping(address => uint256) public owed;

    /**
     * @dev Addresses are kept per record version, and text and websites per profile slot, which holds the record
     * version above the profile counter. A saved address counts only while its saver holds the page.
     */
    mapping(uint256 => mapping(uint256 => address)) internal _resolvedAddress;
    mapping(uint256 => mapping(uint256 => bytes)) internal _contenthash;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => ChainAddress))) internal _coinAddr;
    mapping(uint256 => mapping(uint256 => mapping(string => string))) internal _text;
    mapping(uint256 => mapping(uint256 => address)) internal _addrSaver;

    /**
     * @dev The minter counts only while the account that picked it holds the parent in the same registration.
     */
    mapping(uint256 => SubpageMinter) internal _subpageMinter;

    /**
     * @dev The account that held the page when each account chose it as its display page.
     */
    mapping(address => address) internal _primaryHolder;

    /**
     * @notice Trial money held for its payer. It is never part of depositOf and is zero once it is credited back.
     */
    mapping(uint256 => TrialPayment) public trialPaymentOf;

    /**
     * @dev Text and website count only while the writer of the profile holds the page.
     */
    mapping(uint256 => Profile) internal _profile;

    /**
     * @notice When the current holder got the page: the time of its latest mint, or of its latest transfer to another
     * account. Zero for a page that was never minted. For a subpage it stays as it was when its parent is registered
     * again, so read it only while the page is active.
     */
    mapping(uint256 => uint256) public holderSince;

    /**
     * @notice When the addresses of the page were last saved or cleared, by setAddr, setAddrForCoin or clearRecords,
     * or zero. A time before holderSince was written before the current holder last got the page.
     */
    mapping(uint256 => uint256) public addressesUpdatedAt;

    /**
     * @dev Data records per record version and key. A data record counts only while the account that saved it holds
     * the page.
     */
    mapping(uint256 => mapping(uint256 => mapping(string => DataRecord))) internal _data;

    /**
     * @notice The card renderer, fixed at deployment.
     */
    PageCard public immutable card;

    /**
     * @dev A label is never empty, so a stored label means the record exists.
     */
    function _recordExists(uint256 tokenId) internal view returns (bool) {
        return bytes(records[tokenId].label).length != 0;
    }

    /**
     * @dev The end of the grace period. A top level page with no deposit, which is a trial or a released page, has no
     * grace period.
     */
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

    /**
     * @notice Carries the answer of addr with coin type 60 and always comes with AddressChanged for coin type 60. The
     * main address comes with AddressChanged for the home chain coin type. Apps should not rely on events alone, since
     * some answers change with no event, for example on expiry.
     */
    event AddrChanged(bytes32 indexed node, address addr);
    event ContenthashChanged(bytes32 indexed node, bytes contenthash);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes addr);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);

    /**
     * @dev The value is indexed, so apps read it with data.
     */
    event DataChanged(bytes32 indexed node, string indexed indexedKey, string key, bytes indexed indexedData);
    event VersionChanged(bytes32 indexed node, uint64 newVersion);

    /**
     * @param fresh True when the profile starts empty, false when the holder keeps the one it found.
     */
    event ProfileWriterChanged(bytes32 indexed node, address writer, bool fresh);

    /**
     * @dev ERC4906, with its parameter unindexed as the standard declares it.
     */
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

    /**
     * @notice True for ERC165, the ERC721 interfaces, the resolver interfaces for addr, addr with a coin type, text,
     * contenthash and data, and the metadata update of ERC4906.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0x3b3b57de
            || interfaceId == 0xf1cb7e06
            || interfaceId == 0x59d1d43c
            || interfaceId == 0xbc1c58d1
            || interfaceId == 0x49064906
            || interfaceId == 0xecbfada3
            || super.supportsInterface(interfaceId);
    }

    function name() public pure override(ERC721) returns (string memory) {
        return "Etherpage";
    }

    function symbol() public pure override(ERC721) returns (string memory) {
        return "ETHERPAGE";
    }

    /**
     * @dev A wrong renderer address fails the deployment here, not every tokenURI call later.
     * @param pageCard The PageCard contract, which must already be deployed.
     */
    constructor(PageCard pageCard) {
        if (address(pageCard) == address(0)) revert InvalidRenderer();
        if (
            bytes(
                pageCard.render("a", "", bytes32(0), PageCard.Status.Active, 0)
            ).length < 100
        ) revert InvalidRenderer();
        card = pageCard;
    }

    /**
     * @notice Runs each call on this contract in order, as the same caller and with its own checks. Not payable, so no
     * call can reuse a payment. The first failure reverts them all with its revert data.
     */
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

    /**
     * @notice The epoch of a page, which goes up each time it is registered or minted again.
     */
    function epochOf(uint256 tokenId) external view returns (uint64) {
        return records[tokenId].epoch;
    }

    /**
     * @notice The namehash of the name of a page, such as alice or the subpage bob.alice. The empty string gives ROOT.
     * A to Z are lowercased, and an empty or third label reverts, but labels are not checked in any other way.
     */
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

    /**
     * @notice The token id of a page, which is the namehash of its name as a number.
     */
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

    /**
     * @notice The label in lowercase. Reverts when it is not a valid label.
     */
    function normalize(string calldata label) public pure returns (string memory) {
        return string(_validateAndNormalize(bytes(label)));
    }

    /**
     * @dev Lowercases A to Z and keeps a to z, 0 to 9 and the hyphen. Every other byte, 0x80 to 0xff included, makes
     * the label invalid. Hyphens follow the rules of .com names, so one cannot come first or last or fill both the
     * third and fourth place. A label of 0x and then exactly 40 characters from 0 to 9 and a to f reads as an EVM
     * address, so it is refused. err is 1 for a wrong length and 2 for any other invalid label.
     */
    function _tryNormalize(bytes memory b) internal pure returns (uint256 err, bytes memory out) {
        uint256 n = b.length;
        if (n < MIN_LABEL_LENGTH || n > MAX_LABEL_LENGTH) return (1, "");
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5a) {
                out[i] = bytes1(c + 32);
            } else if ((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d) {
                out[i] = b[i];
            } else {
                return (2, "");
            }
        }
        if (out[0] == 0x2d || out[n - 1] == 0x2d) return (2, "");
        if (n >= 4 && out[2] == 0x2d && out[3] == 0x2d) return (2, "");
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

    /**
     * @notice The yearly fee for a label of this length.
     */
    function getFee(uint256 length) public pure returns (uint256) {
        if (length == 1) return FEE_LEN1;
        if (length == 2) return FEE_LEN2;
        if (length == 3) return FEE_LEN3;
        if (length == 4) return FEE_LEN4;
        return DEFAULT_FEE;
    }

    /**
     * @notice The extra price of a paid page whose grace period has ended. It falls from 10 ETH to zero over 21 days.
     * The last payee gets 75 percent and the payee of the last referrer 25 percent, which is burned when there is no
     * top level referrer.
     */
    function getPremium(uint256 tokenId) public view returns (uint256) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0 || depositOf[tokenId] == 0) return 0;
        uint256 graceEnd = records[tokenId].expiresAt + GRACE_PERIOD;
        if (block.timestamp <= graceEnd) return 0;
        uint256 elapsed = block.timestamp - graceEnd;
        if (elapsed >= PREMIUM_DECAY_PERIOD) return 0;
        return MAX_PREMIUM * (PREMIUM_DECAY_PERIOD - elapsed) / PREMIUM_DECAY_PERIOD;
    }

    /**
     * @notice What reveal costs now, which is the yearly fee, plus during the premium period the deposit taken over
     * from the last registration and the premium. After the premium period the old deposit goes back to its payee
     * instead, so the price is the fee alone. All zero for an invalid label. It does not check that the page is free.
     * revealTrial costs only a tenth of the fee.
     */
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

    /**
     * @notice Whether the label is free now, as a top level page when parentId is 0, else as a subpage of parentId,
     * which must be live, paid and not held by the dead address. A subpage held by the dead address counts as free.
     * revealTrial has further limits.
     */
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
            return records[id].parentEpoch != p.epoch || _ownerOf(id) == DEAD;
        }
    }

    /**
     * @notice Records the time of a commitment. The same commitment can be made again once it is used or more than a
     * day old.
     */
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

    /**
     * @notice The commitment to pass to commit before reveal. revealTrial takes its own commitment instead, which is
     * keccak256 of abi.encode of the lowercase label, owner, referrerId, secret and true.
     */
    function makeCommitment(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        public pure returns (bytes32)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        if (referrerId == uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))))) {
            revert SelfReferral();
        }
        return _commitmentHash(normalized, owner, referrerId, secret);
    }

    /**
     * @notice Registers the label for owner for one year, paid by the caller, 20 seconds to one day after commit. The
     * price is the yearly fee plus any deposit taken over and any premium, as quote shows. After the premium period a
     * deposit still in the page first goes back to its payee. The fee goes into the deposit of the page, and anything
     * paid above the price is sent back. An owner with code must accept ERC721 tokens unless it is the caller or an
     * EIP7702 account.
     */
    function reveal(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external payable nonReentrant returns (uint256 tokenId)
    {
        return _registerTopLevel(label, owner, referrerId, secret);
    }

    /**
     * @notice Registers the label for owner as a 14 day trial for a tenth of the yearly fee, 20 seconds to one day
     * after commit with the trial commitment that makeCommitment describes. That money is held and later credited back
     * to the caller, and anything paid above it is sent back. Until it is renewed, which must happen before it ends,
     * the page has no grace period, no subpages and moves only to the dead address. Refused while a paid page is live,
     * in grace or in its premium period, and until 14 days after its last registration ended. After the premium period
     * a deposit still in the page first goes back to its payee. An owner with code must accept ERC721 tokens unless it
     * is the caller or an EIP7702 account.
     */
    function revealTrial(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external payable nonReentrant returns (uint256 tokenId)
    {
        return _registerTopLevel(label, owner, referrerId, secret);
    }

    /**
     * @dev Shared by reveal and revealTrial and told apart by msg.sig, since a constant argument would make the
     * compiler copy the whole body. A trial uses a different hash of the same values, so a commitment made for reveal
     * can never start a trial. After the premium period a deposit still in the page first goes back to its payee, as
     * release would do. During the premium period a paid registration buys out the deposit of the last one and keeps
     * it. The last payee gets that deposit and 75 percent of any premium. The other 25 percent goes to the payee of the
     * last referrer, or to the dead address when there was no top level referrer, and money still held for an ended
     * trial goes back to its payer. The last holder loses the page and stops showing it as its display page, and every
     * address, text, website and data record saved before stops counting for good. Trial money stays outside the
     * deposit.
     */
    function _registerTopLevel(string calldata label, address to, uint256 referrerId, bytes32 secret)
        internal returns (uint256 tokenId)
    {
        bool trial = msg.sig == this.revealTrial.selector;
        bytes memory normalized = _validateAndNormalize(bytes(label));
        uint256 fee = getFee(normalized.length);
        if (trial) fee /= TRIAL_DIVISOR;
        tokenId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(normalized))));
        if (referrerId == tokenId) revert SelfReferral();
        if (depositOf[tokenId] != 0 && block.timestamp > _auctionEnd(tokenId)) _releaseDeposit(tokenId);
        uint256 carried = depositOf[tokenId];
        if (trial && carried != 0) revert TrialNotAllowed();
        uint256 premium = getPremium(tokenId);
        uint256 total = fee + carried + premium;
        if (msg.value < total) revert InsufficientFee();
        bytes32 c = _commitmentHash(normalized, to, referrerId, secret);
        if (trial) c = keccak256(abi.encode(normalized, to, referrerId, secret, true));
        uint256 committedAt = commitments[c];
        if (committedAt == 0) revert CommitmentNotFound();
        if (block.timestamp < committedAt + MIN_COMMITMENT_AGE) revert CommitmentTooNew();
        if (block.timestamp > committedAt + MAX_COMMITMENT_AGE) revert CommitmentTooOld();
        delete commitments[c];
        bool existed = _recordExists(tokenId);
        if (existed && block.timestamp <= _graceEnd(tokenId)) revert AlreadyRegistered();
        if (trial && existed && block.timestamp <= uint256(records[tokenId].expiresAt) + TRIAL_PAUSE) revert TrialNotAllowed();
        uint256 oldReferrer = referrerOf[tokenId];
        address oldPayee = _payee(tokenId);
        address refPayee = _referrerPayee(oldReferrer);
        address t1 = _credit(oldPayee, carried);
        if (t1 != address(0)) emit DepositBoughtOut(tokenId, t1, carried);
        uint256 refShare = premium * PREMIUM_REFERRER_BPS / BPS_DENOMINATOR;
        uint256 ownerShare = premium - refShare;
        address t2 = _credit(refPayee, refShare);
        if (t2 != address(0)) emit ReferrerPremiumCredited(tokenId, oldReferrer, t2, refShare);
        address t3 = _credit(oldPayee, ownerShare);
        if (t3 != address(0)) emit OwnerPremiumCredited(tokenId, t3, ownerShare);
        _refundTrial(tokenId);
        uint64 newEpoch = existed ? records[tokenId].epoch + 1 : 1;
        if (existed) {
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

    /**
     * @dev Skips the ERC721 receiver check when the caller takes the page itself or when the receiver is a key wallet.
     * Any other receiver with code must accept ERC721 tokens.
     */
    function _mintTo(address to, uint256 tokenId) internal {
        if (to == msg.sender || _isKeyWallet(to)) _mint(to, tokenId);
        else _safeMint(to, tokenId);
    }

    /**
     * @notice Anyone may add a year to a top level page before its grace period ends, paying the yearly fee into its
     * deposit. The new expiry may be at most 3650 days ahead. Renewing a trial before it ends makes it a paid page and
     * credits the trial money back to its payer. Anything paid above the fee is sent back.
     */
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

    /**
     * @notice Creates a subpage for the caller under a live, paid top level page. Only the holder of the parent or its
     * subpage minter may call. The holder may also replace a subpage that is not free, while the minter only creates
     * free ones.
     */
    function registerSubpage(string calldata label, uint256 parentId)
        external nonReentrant returns (uint256 tokenId)
    {
        return _registerSubpage(label, parentId, msg.sender);
    }

    /**
     * @notice Same as registerSubpage, but for any receiver. A receiver with code must accept ERC721 tokens unless it
     * is the caller or an EIP7702 account.
     * @param to The account that receives the subpage.
     */
    function registerSubpageFor(string calldata label, uint256 parentId, address to)
        external nonReentrant returns (uint256 tokenId)
    {
        return _registerSubpage(label, parentId, to);
    }

    /**
     * @dev The caller must be the holder of the parent or the minter that holder picked in the current registration,
     * and the parent must be live and paid, so a trial has no subpages. A minter only creates a free subpage, one that
     * is new, from an earlier registration of the parent or held by the dead address. The zero address is never a
     * minter, also when no minter counts. When a subpage is minted again, its last holder loses it and drops it as its
     * display page, and its old addresses, text, website and data records stop counting.
     */
    function _registerSubpage(string calldata label, uint256 parentId, address to)
        internal returns (uint256 tokenId)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        if (parentId == 0) revert TokenDoesNotExist();
        if (!_recordExists(parentId)) revert TokenDoesNotExist();
        PageRecord storage p = records[parentId];
        if (p.parent != 0) revert NotTopLevel();
        if (block.timestamp > p.expiresAt) revert Expired();
        if (depositOf[parentId] == 0) revert Unpaid();
        address owner = _ownerOf(parentId);
        bool byMinter = owner != msg.sender;
        if (byMinter && (msg.sender == address(0) || _minterFor(parentId, owner) != msg.sender)) revert NotParentOwner();
        tokenId = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(normalized))));
        uint64 newEpoch = 1;
        if (_recordExists(tokenId)) {
            if (byMinter && records[tokenId].parentEpoch == p.epoch && _ownerOf(tokenId) != DEAD) {
                revert AlreadyRegistered();
            }
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

    /**
     * @notice The holder picks one account that may also mint subpages of a top level page, and may replace or clear
     * it. Picking one needs the page to be live. Approved accounts and operators cannot pick one. After the page has
     * moved, the account that picked it may only clear it.
     */
    function setSubpageMinter(uint256 parentId, address minter) external {
        if (!_recordExists(parentId)) revert TokenDoesNotExist();
        PageRecord storage p = records[parentId];
        if (p.parent != 0) revert NotTopLevel();
        if (minter != address(0) && block.timestamp > p.expiresAt) revert Expired();
        if (_ownerOf(parentId) != msg.sender) {
            if (minter != address(0) || _subpageMinter[parentId].setter != msg.sender) revert Unauthorized();
        }
        uint64 epoch = p.epoch;
        _subpageMinter[parentId] = SubpageMinter(minter, epoch, msg.sender);
        emit SubpageMinterSet(parentId, msg.sender, minter, epoch);
    }

    /**
     * @notice The minter that counts now. It is zero unless the account that picked it holds the page now, in the
     * registration it was picked in. Never reverts and ignores expiry.
     */
    function subpageMinterOf(uint256 parentId) external view returns (address) {
        return _minterFor(parentId, _ownerOf(parentId));
    }

    function _minterFor(uint256 parentId, address owner) internal view returns (address) {
        SubpageMinter storage m = _subpageMinter[parentId];
        if (m.setter != owner || m.epoch != records[parentId].epoch) return address(0);
        return m.minter;
    }

    /**
     * @dev The payee of the referrer, or the dead address when there is no top level referrer.
     */
    function _referrerPayee(uint256 refId) internal view returns (address) {
        if (refId == 0) return DEAD;
        if (!_recordExists(refId)) return DEAD;
        if (records[refId].parent != 0) return DEAD;
        return _payee(refId);
    }

    /**
     * @dev Credits an account, with zero and this contract replaced by the dead address. Returns who got it, or zero
     * when there is nothing to credit.
     */
    function _credit(address account, uint256 amount) internal returns (address to) {
        if (amount == 0) return address(0);
        to = account;
        if (to == address(0) || to == address(this)) to = DEAD;
        owed[to] += amount;
    }

    /**
     * @dev Credits any money still held for a trial back to the account that paid it.
     */
    function _refundTrial(uint256 tokenId) internal {
        TrialPayment memory t = trialPaymentOf[tokenId];
        if (t.amount == 0) return;
        delete trialPaymentOf[tokenId];
        address to = _credit(t.payer, t.amount);
        emit TrialRefunded(tokenId, to, t.amount);
    }

    /**
     * @dev The last second of the premium period. The deposit can be released only after it.
     */
    function _auctionEnd(uint256 tokenId) internal view returns (uint256) {
        return uint256(records[tokenId].expiresAt) + GRACE_PERIOD + PREMIUM_DECAY_PERIOD;
    }

    /**
     * @dev Credits the whole deposit to the payee and empties it.
     */
    function _releaseDeposit(uint256 tokenId) internal {
        uint256 amount = depositOf[tokenId];
        address p = _payee(tokenId);
        depositOf[tokenId] = 0;
        address to = _credit(p, amount);
        emit DepositReleased(tokenId, to, amount);
    }

    /**
     * @notice After the grace and premium periods of a page, credits its deposit to its payee. A new registration after
     * those periods does this by itself. For an unpaid trial that has ended, credits the trial money back to its payer
     * instead. Anyone may call it.
     */
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

    /**
     * @notice Sends an account all the money credited to it. Anyone may call it for any account.
     */
    function withdraw(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingToWithdraw();
        owed[account] = 0;
        emit Withdrawn(account, msg.sender, amount);
        SafeTransferLib.safeTransferETH(account, amount);
    }

    /**
     * @notice Refuses ETH, and refuses the zero address as the caller, which the ERC721 library would let approve any
     * page.
     */
    function approve(address account, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.approve(account, id);
    }

    /**
     * @notice Refuses ETH, and refuses the zero address as the caller, which the ERC721 library would let move any page
     * with no approval. Both forms of safeTransferFrom go through this function.
     */
    function transferFrom(address from, address to, uint256 id) public payable override(ERC721) {
        if (msg.value != 0) revert UnexpectedValue();
        if (msg.sender == address(0)) revert NotOwnerNorApproved();
        super.transferFrom(from, to, id);
    }

    /**
     * @dev A page held by the dead address is never active. A top level page is active until it expires, not during
     * its grace period. A subpage is active until its parent expires, in the registration it was made in, also while
     * the dead address holds the parent.
     */
    function _isActive(uint256 tokenId) internal view returns (bool) {
        if (!_recordExists(tokenId)) return false;
        if (_deleted(_ownerOf(tokenId))) return false;
        PageRecord storage r = records[tokenId];
        if (r.parent == 0) return block.timestamp <= r.expiresAt;
        PageRecord storage p = records[r.parent];
        if (r.parentEpoch != p.epoch) return false;
        return block.timestamp <= p.expiresAt;
    }

    /**
     * @dev A page held by the dead address is deleted, so its addresses, text, website and data read empty.
     */
    function _deleted(address holder) internal pure returns (bool) {
        return holder == DEAD;
    }

    /**
     * @notice True once a top level page is past its grace period, or an unpaid trial has ended. Always false for a
     * subpage.
     */
    function isExpired(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        return block.timestamp > _graceEnd(tokenId);
    }

    /**
     * @notice True after a top level page expires and until its grace period ends. Always false for a subpage.
     */
    function inGracePeriod(uint256 tokenId) public view returns (bool) {
        if (!_recordExists(tokenId) || records[tokenId].parent != 0) return false;
        uint256 e = records[tokenId].expiresAt;
        return block.timestamp > e && block.timestamp <= _graceEnd(tokenId);
    }

    /**
     * @notice Zero for a subpage, which follows the expiry of its parent.
     */
    function expiresAt(uint256 tokenId) public view returns (uint256) {
        return records[tokenId].expiresAt;
    }

    /**
     * @dev The saved main address while its saver holds the page, else the holder.
     */
    function _pointee(uint256 tokenId, address owner) internal view returns (address) {
        uint256 v = recordVersion[tokenId];
        address a = _resolvedAddress[tokenId][v];
        return (a != address(0) && _addrSaver[tokenId][v] == owner) ? a : owner;
    }

    /**
     * @notice Sets the main address, the address on the home chain. It counts only while the caller holds the page, and
     * zero points the page back at its holder. Money this contract pays for the page is credited to this address too.
     */
    function setAddr(uint256 tokenId, address a) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _saveAddr(tokenId, a);
    }

    /**
     * @dev Tokens sent to this contract could never leave it, so it is never a main address. Zero clears the saved
     * address, and the page then points at its holder.
     */
    function _saveAddr(uint256 tokenId, address a) internal {
        if (a == address(this)) revert InvalidRecipient();
        uint256 v = recordVersion[tokenId];
        _resolvedAddress[tokenId][v] = a;
        _addrSaver[tokenId][v] = msg.sender;
        addressesUpdatedAt[tokenId] = block.timestamp;
        address main = a == address(0) ? msg.sender : a;
        _emitCoin(tokenId, COIN_TYPE_OP, main);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    /**
     * @notice Sets the address for one chain. It counts only while the caller holds the page. The home chain coin type
     * sets the main address. The default EVM coin type sets the address of every other EVM chain that has none of its
     * own, so coin type 60 is announced too, with AddrChanged. An EVM address must be 20 bytes or empty, and empty or
     * zero clears it.
     */
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

    /**
     * @dev Announces the address of one EVM chain. The address of coin type 60 also goes out as AddrChanged, so the
     * two events always come together.
     */
    function _emitCoin(uint256 tokenId, uint256 coinType, address a) internal {
        emit AddressChanged(bytes32(tokenId), coinType, _encode(a));
        if (coinType == COIN_TYPE_ETH) emit AddrChanged(bytes32(tokenId), a);
    }

    /**
     * @dev Zero goes out as empty bytes, the standard way of saying no address.
     */
    function _encode(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    /**
     * @dev True for coin type 60, or any coin type from 0x80000000 to 0xffffffff.
     */
    function _isEvm(uint256 coinType) internal pure returns (bool) {
        return coinType == COIN_TYPE_ETH || (coinType >= DEFAULT_EVM && coinType <= 0xffffffff);
    }

    /**
     * @notice The address on one chain, empty when the page is not active. The home chain coin type always answers the
     * main address. Any other EVM chain answers the address the holder saved for it, else the default the holder saved
     * for every EVM chain, else nothing. A chain that is not EVM answers only what the holder saved for it.
     */
    function addr(uint256 tokenId, uint256 coinType) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        address owner = ownerOf(tokenId);
        address main = _pointee(tokenId, owner);
        if (coinType == COIN_TYPE_OP) return _encode(main);
        if (_isEvm(coinType)) return _encode(_evmAnswer(tokenId, coinType, owner));
        ChainAddress storage c = _coinAddr[tokenId][recordVersion[tokenId]][coinType];
        return c.saver == owner ? c.value : bytes("");
    }

    /**
     * @dev The address that owner saved for this chain, else the default that owner saved for every EVM chain, else
     * zero. Nothing is read from the code at an address, so the answer for an owner changes only with a save,
     * clearRecords, a new registration or a new mint of a subpage.
     */
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

    /**
     * @dev True for an account with no code or with the 23 byte EIP7702 delegation that starts with 0xef0100. An
     * undeployed contract account, or a contract still in its constructor, has no code and counts too. It only decides
     * whether a mint skips the ERC721 receiver check, and no address answer depends on it.
     */
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

    /**
     * @notice Clears every address, text, website and data record of the page at once. With nothing saved, the page
     * points at its holder again.
     */
    function clearRecords(uint256 tokenId) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        uint256 newVersion = ++recordVersion[tokenId];
        emit VersionChanged(bytes32(tokenId), uint64(newVersion));
        addressesUpdatedAt[tokenId] = block.timestamp;
        _emitCoin(tokenId, COIN_TYPE_OP, msg.sender);
        _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender));
        emit MetadataUpdate(tokenId);
    }

    /**
     * @notice Sets a text record. Writing over a profile left by another holder starts an empty profile.
     */
    function setText(uint256 tokenId, string calldata key, string calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _text[tokenId][_writeSlot(tokenId)][key] = value;
        emit TextChanged(bytes32(tokenId), key, key, value);
    }

    /**
     * @notice Sets the website. Writing over a profile left by another holder starts an empty profile.
     */
    function setContenthash(uint256 tokenId, bytes calldata hash) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _contenthash[tokenId][_writeSlot(tokenId)] = hash;
        emit ContenthashChanged(bytes32(tokenId), hash);
    }

    /**
     * @notice Sets a data record. Like an address, it counts only while the caller holds the page, so it never carries
     * over to a new holder, and keepProfile does not bring it back.
     */
    function setData(uint256 tokenId, string calldata key, bytes calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key];
        d.saver = msg.sender;
        d.value = value;
        emit DataChanged(bytes32(tokenId), key, key, value);
    }

    /**
     * @notice The holder takes the profile it found as its own, so its text and website count again. It cannot bring
     * back what clearRecords or a new registration emptied, and data records never come back with it.
     */
    function keepProfile(uint256 tokenId) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        Profile storage p = _profile[tokenId];
        if (p.writer == msg.sender) revert AlreadyKept();
        p.writer = msg.sender;
        emit ProfileWriterChanged(bytes32(tokenId), msg.sender, false);
    }

    /**
     * @dev The storage key of a profile, with the record version above the profile counter.
     */
    function _slot(uint256 tokenId, uint256 version) internal view returns (uint256) {
        return recordVersion[tokenId] << 96 | version;
    }

    /**
     * @dev A holder writing over the profile of someone else starts an empty one.
     */
    function _writeSlot(uint256 tokenId) internal returns (uint256) {
        Profile storage p = _profile[tokenId];
        if (p.writer != msg.sender) {
            if (p.writer != address(0)) ++p.version;
            p.writer = msg.sender;
            emit ProfileWriterChanged(bytes32(tokenId), msg.sender, true);
        }
        return _slot(tokenId, p.version);
    }

    /**
     * @dev The slot to read, with ok false when the page is not active or the writer of the profile does not hold it.
     */
    function _readSlot(uint256 tokenId) internal view returns (bool ok, uint256 slot) {
        Profile storage p = _profile[tokenId];
        ok = _isActive(tokenId) && p.writer == _ownerOf(tokenId);
        slot = _slot(tokenId, p.version);
    }

    /**
     * @notice The account whose text and website count while it holds the page.
     */
    function profileWriter(uint256 tokenId) external view returns (address) {
        return _profile[tokenId].writer;
    }

    /**
     * @notice The main address, which is the saved one while its saver holds the page, else the holder. Zero when the
     * page is not active.
     */
    function resolve(uint256 tokenId) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, ownerOf(tokenId));
    }

    /**
     * @notice What resolve would answer if account held the page, except that whether the page is active is judged with
     * its current holder.
     */
    function resolveAs(uint256 tokenId, address account) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        return _pointee(tokenId, account);
    }

    /**
     * @notice Empty unless the page is active and the writer of its profile holds it.
     */
    function text(uint256 tokenId, string calldata key) public view returns (string memory) {
        (bool ok, uint256 slot) = _readSlot(tokenId);
        return ok ? _text[tokenId][slot][key] : "";
    }

    /**
     * @notice Empty unless the page is active and the writer of its profile holds it.
     */
    function contenthash(uint256 tokenId) public view returns (bytes memory) {
        (bool ok, uint256 slot) = _readSlot(tokenId);
        return ok ? _contenthash[tokenId][slot] : bytes("");
    }

    /**
     * @notice A data record. Empty unless the page is active and the account that saved the record holds it.
     */
    function data(bytes32 node, string calldata key) external view returns (bytes memory) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return "";
        DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key];
        return d.saver == _ownerOf(tokenId) ? d.value : bytes("");
    }

    /**
     * @notice The same answer as addr with coin type 60: the address saved for it, else the holder's default for every
     * EVM chain, else zero. The main address is resolve.
     */
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

    /**
     * @notice The account this contract pays for the page, also after it expires. It is the saved main address while
     * its saver holds the page, else the holder, with zero and this contract replaced by the dead address.
     */
    function payee(uint256 tokenId) public view returns (address) {
        return _payee(tokenId);
    }

    function _payee(uint256 tokenId) internal view returns (address p) {
        p = _pointee(tokenId, _ownerOf(tokenId));
        if (p == address(0) || p == address(this)) p = DEAD;
    }

    /**
     * @dev No page can go to this contract. A transfer needs an active page, but a mint or a burn does not, and an
     * unpaid trial can be transferred only to the dead address.
     */
    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721)
    {
        if (to == address(this)) revert InvalidRecipient();
        if (from != address(0) && to != address(0)) {
            if (!_isActive(tokenId)) revert Expired();
            if (records[tokenId].parent == 0 && depositOf[tokenId] == 0 && to != DEAD) revert Unpaid();
        }
    }

    /**
     * @dev Records when the new holder got the page, on a mint or a transfer to another account. Announces the main
     * address and the address of coin type 60 when a mint, transfer or burn changes them. Answers for other chains can
     * change with the holder too but get no event. On a transfer to another account the sender stops showing this page
     * as its display page.
     */
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
        if (to != address(0) && !_deleted(to)) {
            main = _pointee(tokenId, to);
            eth = _evmAnswer(tokenId, COIN_TYPE_ETH, to);
        }
        if (was != main) _emitCoin(tokenId, COIN_TYPE_OP, main);
        if (was != main || ethWas != eth || to == address(0)) {
            _emitCoin(tokenId, COIN_TYPE_ETH, eth);
        }
        if (from != address(0) && to != address(0)) {
            if (primaryPage[from] == tokenId) {
                delete primaryPage[from];
                emit PrimaryPageSet(from, 0);
            }
            emit MetadataUpdate(tokenId);
        }
    }

    /**
     * @notice Chooses the display page of the caller, and 0 clears it. The caller must hold the page or be its main
     * address.
     */
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

    /**
     * @notice The name of the display page of an address. Shown only while the page is active, held by the account that
     * held it when it was chosen, and points at the address.
     */
    function reverseResolve(address a) public view returns (string memory) {
        uint256 tokenId = primaryPage[a];
        if (tokenId == 0 || !_isActive(tokenId) || _ownerOf(tokenId) != _primaryHolder[a] || resolve(tokenId) != a) {
            return "";
        }
        return _buildPageName(tokenId);
    }

    /**
     * @notice The name of a page, such as alice, or bob.alice for a subpage. Empty for an unknown id, or for a subpage
     * of an earlier registration of its parent.
     */
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

    /**
     * @dev A page held by the dead address is Invalid. A subpage follows the expiry and grace of its parent, and is
     * Invalid when its parent was registered again. A live top level page with no deposit is a trial.
     */
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
        if (_deleted(_ownerOf(tokenId))) return (PageCard.Status.Invalid, 0, parentLabel);
        expiry = E;
        if (block.timestamp <= E) {
            st = r.parent == 0 && depositOf[tokenId] == 0 ? PageCard.Status.Trial : PageCard.Status.Active;
        } else if (block.timestamp <= graceEnd) {
            st = PageCard.Status.Grace;
        } else {
            st = PageCard.Status.Expired;
        }
    }

    /**
     * @notice The status the metadata shows, for apps that need only that.
     */
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

    /**
     * @dev Escapes double quotes, backslashes, tabs and line breaks, and drops every other byte below 0x20.
     */
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

    /**
     * @dev ETH with up to four decimals, cut rather than rounded, and no trailing zeros. The fraction runs from 1 to
     * 9999 after the first return. Adding 10000 to it keeps its leading zeros behind a 1, and that 1 then becomes the
     * point. The loop that drops zeros stops at the fraction's last nonzero digit, so a decimal always follows it.
     */
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
