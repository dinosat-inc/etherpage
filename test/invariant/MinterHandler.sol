// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MockERC20, SafeLike, NoHook, RejectETH} from "../utils/MinterMocks.sol";

// a contract wallet the handler drives, it takes names and ETH
contract ContractActor {
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// Drives PageNFT and the registrar, which sells only as a minter, with many actors and keeps its own
// model of every record, owner, minter pick, saved address, data record, primary name, config and
// ledger, and of the times holderSince and addressesUpdatedAt. Every call has a predicted outcome
// (success or the exact error selector) and the handler reverts on any mismatch. After every call it
// also checks the wallet rule: the addresses of an active name change only with one of those times.
contract MinterHandler is Test {
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_ETH = 60;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    uint256 constant PERIOD = 365 days;
    uint256 constant HORIZON = 3650 days;
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant T_MINTER_SET = keccak256("SubpageMinterSet(uint256,address,address,uint64)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    uint256 constant COIN_BASE = 0x80002105;
    bytes4 constant NON_RECEIVER = 0xd1a57ed6;
    bytes4 constant INCORRECT_OWNER = 0xa1148100;
    bytes4 constant TO_ZERO = 0xea553b34;

    PageNFT public nft;
    SubpageRegistrar public reg;
    MockERC20 public usd;
    MockERC20 public gate;
    ContractActor public bot;
    SafeLike public safe;
    NoHook public noHook;
    RejectETH public rejecter;
    address public safeOwner;
    address public payoutEOA;
    address public op;
    address public hot;
    address public hot2;
    address public stranger;

    address[] public actors;
    address[] public accts;
    address[] public addrPool;
    uint256[] public parents;
    uint256[] public subs;
    uint256[] public ids;
    uint256 public unregTop;

    struct Label {
        string raw;
        string norm;
        bytes4 err;
    }

    Label[] internal topLabels;
    Label[] internal subLabels;
    string[] internal parentNorm;
    string[] internal subNorm;

    // model
    struct Rec {
        bool exists;
        string label;
        uint256 parent;
        uint64 expiresAt;
        uint64 epoch;
        uint64 parentEpoch;
    }

    struct Saved {
        address a;
        address saver;
    }

    struct MinterG {
        address minter;
        uint64 epoch;
        address setter;
    }

    struct ConfigG {
        address controller;
        bool enabled;
        bool commitReveal;
        address feeToken;
        uint96 price;
        address gateToken;
        uint96 minGate;
        address payout;
        uint64 parentEpoch;
    }

    struct MintLog {
        uint256 sub;
        uint256 parent;
        address caller;
        address to;
        bool byOwner;
        bool byMinter;
        bool wasLive;
        address nftOwner;
        address nftMinter;
        bool wasDead;
    }

    struct DataG {
        address saver;
        bytes value;
    }

    mapping(uint256 => Rec) internal g;
    mapping(uint256 => address) public gOwner;
    mapping(uint256 => uint256) public gVersion;
    mapping(uint256 => uint256) public gDeposit;
    mapping(uint256 => uint256) public gReferrer;
    mapping(address => uint256) public gOwed;
    mapping(address => uint256) public gPrimary;
    // the holder of the name when each account last chose a display name
    mapping(address => address) public gHolder;
    mapping(uint256 => mapping(uint256 => Saved)) internal gAddr;
    mapping(uint256 => mapping(uint256 => Saved)) internal gCoin60;
    // the default for every EVM chain, coin type 0x80000000, per record version
    mapping(uint256 => mapping(uint256 => Saved)) internal gDefault;
    mapping(uint256 => MinterG) internal gMinter;
    mapping(uint256 => ConfigG) internal gConfig;
    mapping(address => uint256) public gProceeds;
    mapping(uint256 => bool) public gPlainInReg;
    mapping(uint256 => uint256) public gMintCount;
    mapping(uint256 => uint64) internal seenEpoch;
    mapping(uint256 => uint256) internal seenVersion;
    MintLog[] internal mintLog;

    // the last call's outcome and, while capturing, a running hash of every log read
    bool internal lastOk;
    bytes internal lastRet;
    bool internal capturing;
    bytes32 internal capHash;

    // an indexer rebuilt from the address events alone
    mapping(uint256 => bytes) internal idxOp;
    mapping(uint256 => address) internal idxAddr;
    mapping(uint256 => bytes) internal idx60;
    mapping(uint256 => bool) internal idxSeen;

    // a reverse record indexer rebuilt from PrimaryPageSet alone
    mapping(address => uint256) internal idxPrimary;

    // set when an account moves a name away, cleared when it picks that name again with setPrimaryPage
    mapping(address => mapping(uint256 => bool)) internal gGaveAway;

    // the time of the call being made, and per name the time holderSince and addressesUpdatedAt should hold: a mint or a
    // Transfer log between two accounts sets the first, a successful setAddr, setAddrForCoin or clearRecords the second
    uint256 internal callTime;
    mapping(uint256 => uint256) internal gSince;
    mapping(uint256 => uint256) internal gAddrAt;

    // data records per record version and key, with the account that saved each
    string[2] internal dataKeys = ["pay", "com.wallet"];
    mapping(uint256 => mapping(uint256 => mapping(uint256 => DataG))) internal gData;

    // the wallet rule: per name the two times last read, and the address answers last seen while it was active
    struct Seen {
        bool set;
        uint256 time;
        bytes32 answers;
    }

    mapping(uint256 => uint256) internal lastSince;
    mapping(uint256 => uint256) internal lastAddrAt;
    mapping(uint256 => Seen) internal lastActive;

    // text "url" and the contenthash per profile slot (record version and profile version), and the
    // account whose profile counts while it holds the name
    mapping(uint256 => mapping(uint256 => string)) internal gText;
    mapping(uint256 => mapping(uint256 => bytes)) internal gHash;
    mapping(uint256 => address) internal gWriter;
    mapping(uint256 => uint256) internal gPVer;

    // coverage counters
    string[] public statKeys;
    mapping(bytes32 => uint256) public statVal;
    mapping(bytes32 => bool) internal statSeen;

    constructor(PageNFT n, SubpageRegistrar r) {
        nft = n;
        reg = r;
        usd = new MockERC20();
        gate = new MockERC20();
        bot = new ContractActor();
        safeOwner = makeAddr("safeOwner");
        safe = new SafeLike(safeOwner);
        noHook = new NoHook();
        rejecter = new RejectETH();
        payoutEOA = makeAddr("payoutEOA");
        op = makeAddr("operator");
        hot = makeAddr("hot");
        hot2 = makeAddr("hot2");
        stranger = makeAddr("stranger");

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(hot);
        actors.push(hot2);
        actors.push(op);
        actors.push(stranger);
        actors.push(address(bot));
        actors.push(address(safe));

        for (uint256 i; i < actors.length; ++i) {
            accts.push(actors[i]);
            addrPool.push(actors[i]);
        }
        accts.push(address(reg));
        accts.push(address(nft));
        accts.push(DEAD);
        accts.push(payoutEOA);
        accts.push(address(rejecter));
        accts.push(address(noHook));
        accts.push(safeOwner);
        accts.push(address(0));
        addrPool.push(DEAD);
        addrPool.push(payoutEOA);
        addrPool.push(address(0));
        addrPool.push(address(0));
        addrPool.push(address(nft));
        addrPool.push(address(reg));
        addrPool.push(address(noHook));

        string[5] memory tops = ["alpha", "beta", "gm", "x", "vault"];
        for (uint256 i; i < 5; ++i) {
            topLabels.push(Label(tops[i], tops[i], bytes4(0)));
            parentNorm.push(tops[i]);
            parents.push(_topId(tops[i]));
        }
        topLabels.push(Label("Beta", "beta", bytes4(0)));
        topLabels.push(Label("-bad", "", PageNFT.InvalidLabel.selector));
        topLabels.push(Label("", "", PageNFT.InvalidLength.selector));

        string[6] memory ss = ["a", "b", "c", "d", "shop", "e"];
        for (uint256 i; i < 6; ++i) {
            subLabels.push(Label(ss[i], ss[i], bytes4(0)));
            subNorm.push(ss[i]);
        }
        subLabels.push(Label("SHOP", "shop", bytes4(0)));
        subLabels.push(Label("A", "a", bytes4(0)));
        subLabels.push(Label("-a", "", PageNFT.InvalidLabel.selector));
        subLabels.push(Label("a_b", "", PageNFT.InvalidLabel.selector));
        subLabels.push(Label("", "", PageNFT.InvalidLength.selector));

        for (uint256 p; p < 5; ++p) {
            ids.push(parents[p]);
        }
        for (uint256 p; p < 5; ++p) {
            for (uint256 s; s < 6; ++s) {
                uint256 sid = _subId(ss[s], parents[p]);
                subs.push(sid);
                ids.push(sid);
            }
        }
        unregTop = _topId("zzz");
        ids.push(unregTop);

        // ERC20 fees and gates: everyone but the stranger approves the registrar
        for (uint256 i; i < actors.length; ++i) {
            usd.mint(actors[i], 1_000_000 ether);
            if (actors[i] != stranger) {
                vm.prank(actors[i]);
                usd.approve(address(reg), type(uint256).max);
            }
            if (i % 2 == 0) gate.mint(actors[i], 1000);
        }
    }

    // helpers
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 n) internal {
        vm.warp(_now() + n);
    }

    function _topId(string memory norm) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(norm)))));
    }

    function _subId(string memory norm, uint256 parentId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(bytes(norm)))));
    }

    function _bump(string memory k) internal {
        bytes32 h = keccak256(bytes(k));
        if (!statSeen[h]) {
            statSeen[h] = true;
            statKeys.push(k);
        }
        statVal[h] += 1;
    }

    function _isActor(address a) internal view returns (bool) {
        for (uint256 i; i < actors.length; ++i) if (actors[i] == a) return true;
        return false;
    }

    function _inAccts(address a) internal view returns (bool) {
        for (uint256 i; i < accts.length; ++i) if (accts[i] == a) return true;
        return false;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    // mostly actors, rarely DEAD, the registrar, the registry, a hookless contract or zero
    function _recipient(uint256 s) internal view returns (address) {
        uint256 r = s % 40;
        if (r < 32) return actors[(s >> 8) % actors.length];
        if (r < 35) return DEAD;
        if (r == 35) return address(reg);
        if (r == 36) return address(nft);
        if (r == 37) return address(noHook);
        if (r == 38) return address(0);
        return actors[(s >> 8) % actors.length];
    }

    function _takesNFT(address a) internal view returns (bool) {
        return a.code.length == 0 || a == address(bot) || a == address(safe);
    }

    function _takesETH(address a) internal view returns (bool) {
        return a.code.length == 0 || a == address(bot) || a == address(safe);
    }

    function _topLabel(uint256 s) internal view returns (Label memory) {
        uint256 r = s % 32;
        if (r < 28) return topLabels[r % 5];
        if (r < 30) return topLabels[5];
        if (r == 30) return topLabels[6];
        return topLabels[7];
    }

    function _subLabel(uint256 s) internal view returns (Label memory) {
        uint256 r = s % 40;
        if (r < 34) return subLabels[r % 6];
        if (r < 36) return subLabels[6];
        if (r == 36) return subLabels[7];
        if (r == 37) return subLabels[8];
        if (r == 38) return subLabels[9];
        return subLabels[10];
    }

    // mostly a pool parent, rarely a subpage, an unregistered id or zero
    function _pickParent(uint256 s) internal view returns (uint256) {
        uint256 r = s % 24;
        if (r == 0) return subs[(s >> 8) % subs.length];
        if (r == 1) return unregTop;
        if (r == 2) return 0;
        return parents[(s >> 8) % 5];
    }

    // a label whose subpage exists under P, else any pool label
    function _existingSubLabel(uint256 P, uint256 s) internal view returns (Label memory) {
        for (uint256 i; i < 6; ++i) {
            uint256 k = (s + i) % 6;
            if (g[_subId(subNorm[k], P)].exists) return subLabels[k];
        }
        return subLabels[s % 6];
    }

    // a label whose subpage under P is live and held by DEAD, else one whose subpage exists, else any pool label
    function _deadSubLabel(uint256 P, uint256 s) internal view returns (Label memory) {
        for (uint256 i; i < 6; ++i) {
            uint256 k = (s + i) % 6;
            uint256 id = _subId(subNorm[k], P);
            if (g[id].exists && _mLive(id) && gOwner[id] == DEAD) return subLabels[k];
        }
        return _existingSubLabel(P, s);
    }

    function _existingSub(uint256 s) internal view returns (uint256) {
        for (uint256 i; i < subs.length; ++i) {
            uint256 id = subs[(s + i) % subs.length];
            if (g[id].exists) return id;
        }
        return subs[s % subs.length];
    }

    function _enabledParent(uint256 s) internal view returns (uint256) {
        for (uint256 i; i < 5; ++i) {
            uint256 P = parents[(s + i) % 5];
            if (gConfig[P].enabled) return P;
        }
        return parents[s % 5];
    }

    function _pickAnyId(uint256 s) internal view returns (uint256) {
        if (s % 3 == 0) return parents[(s >> 8) % 5];
        return ids[(s >> 8) % ids.length];
    }

    function _pickRef(uint256 s, uint256 self) internal view returns (uint256) {
        uint256 r = s % 10;
        if (r < 4) return 0;
        if (r == 4) return self;
        if (r == 5) return subs[(s >> 8) % subs.length];
        if (r == 6) return unregTop;
        return parents[(s >> 8) % 5];
    }

    // spreads a fuzz seed over all bits so every choice below is uniform
    function _h(uint256 x, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(x, salt)));
    }

    function _sel(bool ok, bytes memory ret) internal pure returns (bytes4 s) {
        if (ok) return bytes4(0);
        if (ret.length < 4) return bytes4(0xffffffff);
        assembly ("memory-safe") {
            s := mload(add(ret, 0x20))
        }
    }

    function _expect(string memory what, bytes4 exp, bool ok, bytes memory ret) internal pure {
        bytes4 got = _sel(ok, ret);
        if (got != exp) {
            revert(
                string.concat(
                    what, ": expected ", vm.toString(abi.encodePacked(exp)), " got ", vm.toString(ret),
                    ok ? " (success)" : " (revert)"
                )
            );
        }
    }

    // calls target as actor a; contract actors go through their own exec
    function _call(address a, address target, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        _logs();
        callTime = _now();
        if (a == address(bot)) {
            (ok, ret) = address(bot).call(abi.encodeCall(ContractActor.exec, (target, value, data)));
        } else if (a == address(safe)) {
            vm.prank(safeOwner);
            (ok, ret) = address(safe).call(abi.encodeCall(SafeLike.exec, (target, value, data)));
        } else {
            vm.prank(a);
            (ok, ret) = target.call{value: value}(data);
        }
        // the recording keeps the logs of a reverted call, an indexer never sees them
        if (!ok) vm.getRecordedLogs();
        if (ok && target == address(nft)) _noteAddrWrites(data);
        lastOk = ok;
        lastRet = ret;
    }

    // model views
    function _mActive(uint256 id) internal view returns (bool) {
        Rec storage r = g[id];
        if (!r.exists) return false;
        // a page held by DEAD is deleted
        if (gOwner[id] == DEAD) return false;
        if (r.parent == 0) return _now() <= r.expiresAt;
        Rec storage p = g[r.parent];
        if (r.parentEpoch != p.epoch) return false;
        return _now() <= p.expiresAt;
    }

    // what an indexer should hold for a name, from the model, whatever the time
    function _mIndexed(uint256 id) internal view returns (address main, address eth) {
        if (!g[id].exists) return (address(0), address(0));
        address owner = gOwner[id];
        if (owner == DEAD) return (address(0), address(0));
        main = _mPointee(id, owner);
        eth = _mEth(id, owner, main);
    }

    // every log of a call whose state is kept passes through here, so the indexer sees all address events
    function _logs() internal returns (Vm.Log[] memory logs) {
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (capturing) capHash = keccak256(abi.encode(capHash, l.emitter, l.topics, l.data));
            // a mint or a move between two accounts sets holderSince to the time of the call
            if (l.emitter == address(nft) && l.topics.length == 4 && l.topics[0] == T_TRANSFER) {
                address from = address(uint160(uint256(l.topics[1])));
                address to = address(uint160(uint256(l.topics[2])));
                if (from != to && to != address(0)) gSince[uint256(l.topics[3])] = callTime;
                continue;
            }
            if (l.emitter == address(nft) && l.topics.length == 3 && l.topics[0] == T_PRIMARY) {
                idxPrimary[address(uint160(uint256(l.topics[1])))] = uint256(l.topics[2]);
                continue;
            }
            if (l.emitter != address(nft) || l.topics.length != 2) continue;
            uint256 node = uint256(l.topics[1]);
            if (l.topics[0] == T_ADDR) {
                idxAddr[node] = abi.decode(l.data, (address));
                idxSeen[node] = true;
            } else if (l.topics[0] == T_ADDRESS) {
                (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (coin == COIN_OP) idxOp[node] = v;
                else if (coin == COIN_ETH) idx60[node] = v;
            }
        }
    }

    // a successful setAddr, setAddrForCoin or clearRecords, alone or in a bundle, sets the time addressesUpdatedAt
    // should hold; a bundle succeeds only when every call in it does
    function _noteAddrWrites(bytes memory data) internal {
        if (data.length < 4) return;
        bytes4 sel = bytes4(data);
        if (sel == PageNFT.multicall.selector) {
            bytes memory args = new bytes(data.length - 4);
            for (uint256 i; i < args.length; ++i) args[i] = data[i + 4];
            bytes[] memory calls = abi.decode(args, (bytes[]));
            for (uint256 i; i < calls.length; ++i) _noteAddrWrites(calls[i]);
        } else if (
            sel == PageNFT.setAddr.selector || sel == PageNFT.setAddrForCoin.selector
                || sel == PageNFT.clearRecords.selector
        ) {
            uint256 id;
            assembly ("memory-safe") {
                id := mload(add(data, 36))
            }
            gAddrAt[id] = callTime;
            _bump("times.addressWrite");
        }
    }

    function _mLive(uint256 sub) internal view returns (bool) {
        Rec storage r = g[sub];
        return r.exists && r.parentEpoch == g[r.parent].epoch;
    }

    function _mPointee(uint256 id, address acct) internal view returns (address) {
        Saved storage s = gAddr[id][gVersion[id]];
        return (s.a != address(0) && s.saver == acct) ? s.a : acct;
    }

    function _mPayee(uint256 id) internal view returns (address p) {
        p = _mPointee(id, gOwner[id]);
        if (p == address(0) || p == address(nft)) p = DEAD;
    }

    function _mResolve(uint256 id) internal view returns (address) {
        if (!_mActive(id)) return address(0);
        return _mPointee(id, gOwner[id]);
    }

    function _mEth(uint256 id, address owner, address main) internal view returns (address a) {
        Saved storage c = gCoin60[id][gVersion[id]];
        if (c.saver == owner) a = c.a;
        Saved storage d = gDefault[id][gVersion[id]];
        if (a == address(0) && d.saver == owner) a = d.a;
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function _mMinter(uint256 parentId) internal view returns (address) {
        MinterG storage m = gMinter[parentId];
        if (m.setter != gOwner[parentId] || m.epoch != g[parentId].epoch) return address(0);
        return m.minter;
    }

    function _mRefPayee(uint256 refId) internal view returns (address) {
        if (refId == 0) return DEAD;
        if (!g[refId].exists) return DEAD;
        if (g[refId].parent != 0) return DEAD;
        return _mPayee(refId);
    }

    function _mPremium(uint256 id) internal view returns (uint256) {
        if (!g[id].exists || g[id].parent != 0) return 0;
        uint256 graceEnd = uint256(g[id].expiresAt) + GRACE;
        if (_now() <= graceEnd) return 0;
        uint256 elapsed = _now() - graceEnd;
        if (elapsed >= DECAY) return 0;
        return 10 ether * (DECAY - elapsed) / DECAY;
    }

    function _fee(uint256 len) internal pure returns (uint256) {
        if (len <= 2) return 0.01 ether;
        if (len <= 4) return 0.001 ether;
        return 0.0001 ether;
    }

    function _mFullName(uint256 id) internal view returns (string memory) {
        Rec storage r = g[id];
        if (!r.exists) return "";
        if (r.parent == 0) return r.label;
        Rec storage p = g[r.parent];
        if (r.parentEpoch != p.epoch) return "";
        return string.concat(r.label, ".", p.label);
    }

    function _mCredit(address a, uint256 amount) internal {
        if (amount == 0) return;
        if (a == address(0) || a == address(nft)) a = DEAD;
        require(_inAccts(a), "model credit outside the account set");
        gOwed[a] += amount;
    }

    // ledger snapshot
    function _ledgerHash() internal view returns (bytes32 h) {
        h = keccak256(abi.encode(address(nft).balance));
        for (uint256 i; i < ids.length; ++i) {
            h = keccak256(abi.encode(h, nft.depositOf(ids[i]), nft.referrerOf(ids[i])));
        }
        for (uint256 i; i < accts.length; ++i) {
            h = keccak256(abi.encode(h, nft.owed(accts[i])));
        }
    }

    function _checkMonotone() internal {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint64 e = nft.epochOf(id);
            uint256 v = nft.recordVersion(id);
            require(e >= seenEpoch[id], "epoch went down");
            require(v >= seenVersion[id], "record version went down");
            seenEpoch[id] = e;
            seenVersion[id] = v;
        }
    }

    function _noStrayTransfers(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics.length == 4 && logs[i].topics[0] == T_TRANSFER) {
                revert("an unexpected Transfer was emitted");
            }
        }
    }

    // checks the PageNFT Transfer logs are exactly a burn (burnFrom, 0, id) when burned is set, then one (from, to, id)
    function _checkTransfers(Vm.Log[] memory logs, bool burned, address burnFrom, address from, address to, uint256 id)
        internal
        view
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 4 || l.topics[0] != T_TRANSFER) continue;
            address f = address(uint160(uint256(l.topics[1])));
            address t = address(uint160(uint256(l.topics[2])));
            uint256 tid = uint256(l.topics[3]);
            require(tid == id, "Transfer of another token");
            if (burned && n == 0) {
                require(f == burnFrom && t == address(0), "burn Transfer mismatch");
            } else {
                require(f == from && t == to, "Transfer mismatch");
            }
            ++n;
        }
        require(n == (burned ? 2 : 1), "wrong number of Transfer logs");
    }

    modifier step(bool touchesLedger) {
        vm.recordLogs();
        _logs();
        bytes32 before = touchesLedger ? bytes32(0) : _ledgerHash();
        _;
        if (!touchesLedger) require(_ledgerHash() == before, "a ledger moved on a non-ledger action");
        _noStrayTransfers(_logs());
        _checkMonotone();
        _walletRule();
    }

    // bootstrap
    function bootstrap() external {
        vm.recordLogs();
        address alice = actors[0];
        address bob = actors[1];
        address carol = actors[2];
        _doRegister(alice, topLabels[0], alice, 0, 1, 0);
        _doRegister(bob, topLabels[1], bob, parents[0], 2, 0);
        _doRegister(address(safe), topLabels[2], address(safe), 0, 3, 0);
        _doRegister(carol, topLabels[3], carol, 0, 4, 0);
        _doRegister(address(bot), topLabels[4], address(bot), parents[2], 5, 0);
        _doSetMinter(alice, parents[0], address(reg));
        _doConfigure(alice, parents[0], payoutEOA, address(0), 0.01 ether, true, address(0), 0, false);
        _doSetMinter(bob, parents[1], hot);
        _doSetMinter(address(safe), parents[2], address(bot));
        _doSetMinter(carol, parents[3], address(reg));
        _doConfigure(carol, parents[3], address(0), address(usd), 1 ether, true, address(gate), 1, true);
        _doSetMinter(address(bot), parents[4], hot2);
        vm.prank(alice);
        nft.setApprovalForAll(op, true);
        vm.prank(bob);
        nft.setApprovalForAll(op, true);
        _logs();
        _checkMonotone();
        _walletRule();
    }

    // actions
    function act_register(uint256 whoS, uint256 labS, uint256 toS, uint256 refS, uint256 payS) external step(true) {
        whoS = _h(whoS, 0);
        labS = _h(labS, 1);
        toS = _h(toS, 2);
        refS = _h(refS, 3);
        payS = _h(payS, 4);
        address payer = _actor(whoS);
        Label memory L = _topLabel(labS);
        address to = toS % 4 == 0 ? payer : _recipient(toS);
        uint256 id = L.err == 0 ? _topId(L.norm) : 0;
        _doRegister(payer, L, to, _pickRef(refS, id), payS, 61 + payS % 600);
    }

    // tries to register a parent name again, and in about one call out of six first moves to the first second after its
    // grace or to a point past its premium window, when that point is still ahead
    function act_expireAndRegister(uint256 pS, uint256 whoS, uint256 toS, uint256 when) external step(true) {
        pS = _h(pS, 0);
        whoS = _h(whoS, 1);
        toS = _h(toS, 2);
        when = _h(when, 3);
        uint256 k = pS % 5;
        uint256 P = parents[k];
        if (g[P].exists && when % 6 == 0) {
            uint256 base = uint256(g[P].expiresAt) + GRACE + 1;
            uint256 r = when % 4;
            uint256 target = r == 0 ? base : r == 1 ? base + (when >> 8) % DECAY : base + DECAY + (when >> 8) % 60 days;
            if (target > _now()) vm.warp(target);
        }
        address payer = _actor(whoS);
        address to = toS % 3 == 0 ? payer : _actor(toS >> 8);
        _doRegister(payer, topLabels[k], to, _pickRef(when >> 16, P), whoS >> 8, 1);
        // for each other name past its grace period, three times in four an actor tries to register it for
        // itself; a new registration leaves the subpages of the earlier one stale
        for (uint256 i = 1; i < 5; ++i) {
            uint256 j = (k + i) % 5;
            uint256 Q = parents[j];
            if (g[Q].exists && _now() > uint256(g[Q].expiresAt) + GRACE && (when >> (20 + i)) % 4 != 0) {
                address np = _actor(when >> (40 + 8 * i));
                _doRegister(np, topLabels[j], np, 0, when >> (30 + i), 1);
                _bump("register.newHolderAfterLapse");
            }
        }
    }

    // the holder tries to pick an actor as minter three times in four, and that actor then tries to mint whether
    // or not it was just picked, often over a label that exists
    function act_minterRoutine(uint256 pS, uint256 mS, uint256 lS, uint256 toS) external step(false) {
        pS = _h(pS, 0);
        mS = _h(mS, 1);
        lS = _h(lS, 2);
        toS = _h(toS, 3);
        uint256 P = parents[pS % 5];
        address owner = gOwner[P];
        if (!_isActor(owner)) {
            _bump("minterRoutine.skip");
            return;
        }
        address[4] memory ms = [hot, address(bot), hot2, address(safe)];
        address minter = ms[mS % 4];
        if ((mS >> 8) % 4 != 0) _doSetMinter(owner, P, minter);
        Label memory L = lS % 5 < 2 ? _existingSubLabel(P, lS >> 8) : lS % 5 == 2 ? _deadSubLabel(P, lS >> 8) : _subLabel(lS);
        // the subpage's holder sometimes makes it their primary name first, so taking it back must clear it
        if (L.err == 0 && (lS >> 40) % 3 == 0) {
            uint256 sub = _subId(L.norm, P);
            if (_isActor(gOwner[sub]) && _mActive(sub)) {
                _doSetPrimary(gOwner[sub], sub);
                _bump("minterRoutine.primaryFirst");
            }
        }
        address to = toS % 3 == 0 ? minter : _recipient(toS);
        bytes memory data = to == minter && (toS >> 4) % 2 == 0
            ? abi.encodeCall(PageNFT.registerSubpage, (L.raw, P))
            : abi.encodeCall(PageNFT.registerSubpageFor, (L.raw, P, to));
        _doMint(minter, P, L, to, data);
        _bump("minterRoutine");
    }

    struct RegCtx {
        uint256 id;
        uint256 fee;
        uint256 carried;
        uint256 released;
        uint256 premium;
        uint256 total;
        uint256 value;
        bytes32 secret;
        bytes4 exp;
        uint256 balBefore;
        bool existed;
        address oldOwner;
    }

    function _doRegister(address payer, Label memory L, address to, uint256 ref, uint256 payS, uint256 wait) internal {
        RegCtx memory c;
        c.id = L.err == 0 ? _topId(L.norm) : 0;
        c.secret = keccak256(abi.encode(payer, L.raw, to, ref, payS, _now()));
        bytes32 commitment = L.err == 0
            ? keccak256(abi.encode(bytes(L.norm), to, ref, c.secret))
            : keccak256(abi.encode(c.secret));
        (bool cok, bytes memory cret) = _call(payer, address(nft), 0, abi.encodeCall(PageNFT.commit, (commitment)));
        _expect("commit", bytes4(0), cok, cret);
        if (wait < 61) wait = 61;
        _warp(wait);

        if (L.err == 0) {
            c.fee = _fee(bytes(L.norm).length);
            c.carried = gDeposit[c.id];
            // after the auction the reveal first releases the old deposit to the last payee
            if (c.carried != 0 && _now() > uint256(g[c.id].expiresAt) + GRACE + DECAY) {
                c.released = c.carried;
                c.carried = 0;
            }
            c.premium = _mPremium(c.id);
        }
        c.total = c.fee + c.carried + c.premium;
        c.value = c.total + (payS % 3 == 0 ? (payS >> 8) % 1e15 : 0);
        if (payS % 29 == 7 && c.total > 0) c.value = c.total - 1;

        // prediction, in the order reveal checks
        if (L.err != 0) c.exp = L.err;
        else if (ref == c.id) c.exp = PageNFT.SelfReferral.selector;
        else if (c.value < c.total) c.exp = PageNFT.InsufficientFee.selector;
        else if (g[c.id].exists && _now() <= uint256(g[c.id].expiresAt) + GRACE) c.exp = PageNFT.AlreadyRegistered.selector;
        else if (to == address(nft)) c.exp = PageNFT.InvalidRecipient.selector;
        else if (to == address(0)) c.exp = TO_ZERO;
        else if (!_takesNFT(to)) c.exp = NON_RECEIVER;

        vm.deal(payer, payer.balance + c.value);
        c.balBefore = payer.balance;
        c.existed = g[c.id].exists;
        c.oldOwner = gOwner[c.id];
        bytes memory data = abi.encodeCall(PageNFT.reveal, (L.raw, to, ref, c.secret));
        (bool ok, bytes memory ret) = _call(payer, address(nft), c.value, data);
        Vm.Log[] memory logs = _logs();
        _expect("register", c.exp, ok, ret);
        _bump(ok ? "register.ok" : "register.refused");
        if (!ok) {
            require(payer.balance == c.balBefore, "register: failed call moved the payer's ETH");
            return;
        }
        require(abi.decode(ret, (uint256)) == c.id || payer == address(bot) || payer == address(safe), "register: id");
        require(c.balBefore - payer.balance == c.total, "register: payer charged other than the total");
        _checkTransfers(logs, c.existed, c.oldOwner, address(0), to, c.id);

        // credits of a registration over an existing record, taken from the old state
        if (c.existed) {
            address oldPayee = _mPayee(c.id);
            address refPayee = _mRefPayee(gReferrer[c.id]);
            uint256 refShare = c.premium * 2500 / 10_000;
            _mCredit(oldPayee, c.released);
            _mCredit(oldPayee, c.carried);
            _mCredit(refPayee, refShare);
            _mCredit(oldPayee, c.premium - refShare);
            if (gPrimary[c.oldOwner] == c.id) delete gPrimary[c.oldOwner];
            gVersion[c.id] += 1;
            _bump("register.again");
            if (c.premium > 0) _bump("register.withPremium");
            if (c.released > 0) _bump("register.releasedFirst");
        }
        Rec storage r = g[c.id];
        r.epoch = c.existed ? r.epoch + 1 : 1;
        r.exists = true;
        r.label = L.norm;
        r.parent = 0;
        r.parentEpoch = 0;
        r.expiresAt = uint64(_now() + PERIOD);
        gReferrer[c.id] = ref;
        gDeposit[c.id] = gDeposit[c.id] - c.released + c.fee;
        gOwner[c.id] = to;
        gPlainInReg[c.id] = false;
    }

    function act_renew(uint256 whoS, uint256 pS, uint256 payS) external step(true) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        payS = _h(payS, 2);
        address payer = _actor(whoS);
        uint256 id = _pickParent(pS);
        uint256 fee = g[id].exists ? _fee(bytes(g[id].label).length) : 0;
        uint256 value = fee + (payS % 2 == 0 ? (payS >> 8) % 1e15 : 0);
        if (payS % 23 == 3 && fee > 0) value = fee - 1;
        bytes4 exp;
        if (!g[id].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (g[id].parent != 0) exp = PageNFT.NotTopLevel.selector;
        else if (_now() > uint256(g[id].expiresAt) + GRACE) exp = PageNFT.Expired.selector;
        else if (value < fee) exp = PageNFT.InsufficientFee.selector;
        else if (uint256(g[id].expiresAt) + PERIOD > _now() + HORIZON) exp = PageNFT.RenewalTooFar.selector;

        vm.deal(payer, payer.balance + value);
        uint256 before = payer.balance;
        (bool ok, bytes memory ret) = _call(payer, address(nft), value, abi.encodeCall(PageNFT.renew, (id)));
        _expect("renew", exp, ok, ret);
        _bump(ok ? "renew.ok" : "renew.refused");
        if (!ok) return;
        require(before - payer.balance == fee, "renew: payer charged other than the fee");
        g[id].expiresAt += uint64(PERIOD);
        gDeposit[id] += fee;
    }

    function act_transfer(uint256 whoS, uint256 idS, uint256 toS, uint256 mode) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        toS = _h(toS, 2);
        mode = _h(mode, 3);
        uint256 id = idS % 3 == 0 ? _existingSub(idS >> 8) : parents[(idS >> 8) % 5];
        if (!g[id].exists) {
            _bump("transfer.skip");
            return;
        }
        address owner = gOwner[id];
        // the holder often shows the name as its display name before it moves
        if ((idS >> 40) % 3 == 0 && _isActor(owner) && _mActive(id)) {
            _doSetPrimary(owner, id);
            _bump("transfer.primaryFirst");
        }
        uint256 r = whoS % 5;
        address caller = r < 2 ? owner : r == 2 ? op : r == 3 ? nft.getApproved(id) : _actor(whoS >> 8);
        if (!_isActor(caller)) caller = _actor(whoS >> 8);
        address to = _recipient(toS);
        // sometimes the name goes back to the account that picked its minter
        if (toS % 3 == 1 && _isActor(gMinter[id].setter) && gMinter[id].setter != owner) {
            to = gMinter[id].setter;
            _bump("transfer.toSetter");
        }
        address from = mode % 23 == 5 ? _actor(mode >> 8) : owner;
        bool ok = _doTransfer(caller, id, from, to, (mode >> 16) % 3);
        // the new holder points the name back at the sender, which must not revive its display name
        if (ok && from != to && _isActor(to) && (toS >> 40) % 3 == 0) {
            _doSetMain(to, id, from);
            _bump("transfer.revivalAttempt");
        }
        if (!ok || g[id].parent != 0 || from == to) return;
        // after the name has left it, the old holder tries to switch its minter off, or one time in five to pick hot,
        // which is always refused
        if (_isActor(from) && (mode >> 32) % 3 == 0) {
            _doSetMinter(from, id, (mode >> 40) % 5 == 0 ? hot : address(0));
        } else if (_isActor(to) && (mode >> 56) % 3 == 0) {
            // a round trip: the name comes straight back, as after a flash loan or a cancelled sale
            _doTransfer(to, id, to, from, (mode >> 60) % 3);
            _bump("transfer.roundTrip");
        }
    }

    // the counted minter tries one of ten calls beyond minting, nine of them powers of the holder and one an underpaid
    // renewal, and the outcome must match the prediction, a refusal unless the minter is also approved for the name or
    // an operator of the holder
    function act_minterOverreach(uint256 pS, uint256 kS, uint256 xS) external step(true) {
        pS = _h(pS, 0);
        kS = _h(kS, 1);
        xS = _h(xS, 2);
        uint256 P = parents[pS % 5];
        address m = _mMinter(P);
        address owner = gOwner[P];
        if (!_isActor(m) || m == owner) {
            _bump("overreach.skip");
            return;
        }
        uint256 k = kS % 10;
        bytes memory data;
        address target = address(nft);
        uint256 value;
        bytes4 exp;
        bool active = _mActive(P);
        if (k == 0) {
            _doTransfer(m, P, owner, _actor(xS), xS % 3);
            _bump("overreach.transfer");
            return;
        } else if (k == 1) {
            data = abi.encodeCall(PageNFT.approve, (m, P));
            if (!nft.isApprovedForAll(owner, m)) exp = ERC721.NotOwnerNorApproved.selector;
        } else if (k == 2) {
            data = abi.encodeCall(PageNFT.setAddr, (P, m));
            exp = active ? PageNFT.Unauthorized.selector : PageNFT.Expired.selector;
        } else if (k == 3) {
            data = abi.encodeCall(PageNFT.clearRecords, (P));
            exp = active ? PageNFT.Unauthorized.selector : PageNFT.Expired.selector;
        } else if (k == 4) {
            data = abi.encodeCall(PageNFT.setSubpageMinter, (P, _actor(xS)));
            if (_now() > g[P].expiresAt) exp = PageNFT.Expired.selector;
            else exp = PageNFT.Unauthorized.selector;
        } else if (k == 5) {
            // an underpaid renewal
            uint256 fee = _fee(bytes(g[P].label).length);
            value = fee - 1 - xS % (fee - 1);
            data = abi.encodeCall(PageNFT.renew, (P));
            exp = _now() > uint256(g[P].expiresAt) + GRACE ? PageNFT.Expired.selector : PageNFT.InsufficientFee.selector;
        } else if (k == 6) {
            target = address(reg);
            data = abi.encodeCall(SubpageRegistrar.configure, (P, m, address(0), 0, true, address(0), 0, false));
            exp = SubpageRegistrar.NotAuthorized.selector;
        } else if (k == 7) {
            target = address(reg);
            data = abi.encodeCall(SubpageRegistrar.disable, (P));
            exp = SubpageRegistrar.NotAuthorized.selector;
        } else if (k == 8) {
            data = abi.encodeCall(PageNFT.setAddrForCoin, (P, COIN_ETH, abi.encodePacked(m)));
            exp = active ? PageNFT.Unauthorized.selector : PageNFT.Expired.selector;
        } else {
            data = abi.encodeCall(PageNFT.setText, (P, "url", "minter"));
            exp = active ? PageNFT.Unauthorized.selector : PageNFT.Expired.selector;
        }
        if (value != 0) vm.deal(m, m.balance + value);
        uint256 before = m.balance;
        (bool ok, bytes memory ret) = _call(m, target, value, data);
        _expect("minter overreach", exp, ok, ret);
        require(m.balance == before || ok, "overreach moved the minter's ETH");
        _bump(string.concat("overreach.", vm.toString(k)));
        if (ok && k == 1) _bump("overreach.approveAsOperator");
    }

    function _doTransfer(address caller, uint256 id, address from, address to, uint256 kind) internal returns (bool ok) {
        address owner = gOwner[id];
        bytes4 exp;
        if (to == address(nft)) exp = PageNFT.InvalidRecipient.selector;
        else if (to != address(0) && !_mActive(id)) exp = PageNFT.Expired.selector;
        else if (from != owner) exp = INCORRECT_OWNER;
        else if (caller != from && nft.getApproved(id) != caller && !nft.isApprovedForAll(from, caller)) {
            exp = ERC721.NotOwnerNorApproved.selector;
        } else if (to == address(0)) exp = TO_ZERO;
        else if (kind != 0 && !_takesNFT(to)) exp = NON_RECEIVER;

        bytes memory data = kind == 0
            ? abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id)
            : kind == 1
                ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id)
                : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"beef");
        bytes memory ret;
        (ok, ret) = _call(caller, address(nft), 0, data);
        Vm.Log[] memory logs = _logs();
        _expect("transfer", exp, ok, ret);
        if (owner == DEAD) _bump("transfer.fromDeleted");
        bool top = g[id].parent == 0;
        _bump(ok ? (top ? "transfer.parent.ok" : "transfer.sub.ok") : "transfer.refused");
        if (!ok) return false;
        _checkTransfers(logs, false, address(0), from, to, id);
        if (caller != owner) _bump(caller == op ? "transfer.byOperator" : "transfer.byApproved");
        if (kind != 0) _bump("transfer.safe.ok");
        if (to == address(reg)) {
            require(kind == 0, "a safe transfer put a name in the registrar");
            gPlainInReg[id] = true;
            _bump("transfer.plainIntoRegistrar");
        }
        if (to == DEAD) _bump("transfer.toDead");
        if (to == DEAD && top) _bump("transfer.parent.toDead");
        address mBefore = _mMinter(id);
        gOwner[id] = to;
        // a move between two accounts clears the sender's pointer when it names the id
        bool cleared = from != to && gPrimary[from] == id;
        _checkPrimaryLogs(logs, cleared, from, id);
        if (from != to) gGaveAway[from][id] = true;
        if (cleared) {
            delete gPrimary[from];
            _bump(to == DEAD ? "transfer.clearedPrimary.toDead" : "transfer.clearedPrimary");
        }
        if (top) {
            address mAfter = _mMinter(id);
            if (mBefore == address(0) && mAfter != address(0)) _bump("minter.revivedByReturn");
            if (mBefore != address(0) && mAfter == address(0)) _bump("minter.offByTransfer");
        }
    }

    // exactly one PrimaryPageSet(from, 0), right before the MetadataUpdate of the move, when cleared;
    // none otherwise
    function _checkPrimaryLogs(Vm.Log[] memory logs, bool cleared, address from, uint256 id) internal view {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 3 || l.topics[0] != T_PRIMARY) continue;
            ++n;
            require(address(uint160(uint256(l.topics[1]))) == from && l.topics[2] == bytes32(0), "PrimaryPageSet fields");
            require(i + 1 < logs.length, "PrimaryPageSet is the last log");
            Vm.Log memory m = logs[i + 1];
            require(m.topics.length == 1 && m.topics[0] == T_META && abi.decode(m.data, (uint256)) == id, "PrimaryPageSet not before MetadataUpdate");
        }
        require(n == (cleared ? 1 : 0), "PrimaryPageSet count on a transfer");
    }

    // setAddr of a main address, predicted and applied as act_setAddr does
    function _doSetMain(address caller, uint256 id, address a) internal {
        bytes4 exp;
        if (!_mActive(id)) exp = PageNFT.Expired.selector;
        else if (gOwner[id] != caller) exp = PageNFT.Unauthorized.selector;
        else if (a == address(nft)) exp = PageNFT.InvalidRecipient.selector;
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.setAddr, (id, a)));
        _logs();
        _expect("setAddr back", exp, ok, ret);
        if (ok) gAddr[id][gVersion[id]] = Saved(a, caller);
    }

    // a subpage holder deletes its subpage by sending it to DEAD
    function act_subToDead(uint256 pS, uint256 lS, uint256 mode) external step(false) {
        pS = _h(pS, 0);
        lS = _h(lS, 1);
        mode = _h(mode, 2);
        uint256 P = parents[pS % 5];
        Label memory L = _existingSubLabel(P, lS);
        uint256 sub = _subId(L.norm, P);
        address h = gOwner[sub];
        if (!g[sub].exists || !_isActor(h)) {
            _bump("subToDead.skip");
            return;
        }
        address caller = mode % 4 == 0 && nft.isApprovedForAll(h, op) ? op : h;
        if (_doTransfer(caller, sub, h, DEAD, (mode >> 8) % 3)) _bump("subToDead.ok");
    }

    // the parent holder takes a subpage back and frees it by minting it to DEAD
    function act_remintToDead(uint256 pS, uint256 lS) external step(false) {
        pS = _h(pS, 0);
        lS = _h(lS, 1);
        uint256 P = parents[pS % 5];
        address owner = gOwner[P];
        if (!_isActor(owner)) {
            _bump("remintToDead.skip");
            return;
        }
        Label memory L = lS % 3 == 0 ? _subLabel(lS >> 8) : _existingSubLabel(P, lS >> 8);
        bytes memory data = abi.encodeCall(PageNFT.registerSubpageFor, (L.raw, P, DEAD));
        _doMint(owner, P, L, DEAD, data);
        _bump("remintToDead");
    }

    // a counted minter that is an actor other than the holder mints over a label DEAD holds, or mints another label
    // when there is none
    function act_recycleMint(uint256 pS, uint256 lS, uint256 toS) external step(false) {
        pS = _h(pS, 0);
        lS = _h(lS, 1);
        toS = _h(toS, 2);
        uint256 P = parents[pS % 5];
        address m = _mMinter(P);
        Label memory L = _deadSubLabel(P, lS);
        if (!_isActor(m) || m == gOwner[P]) {
            _bump("recycleMint.skip");
            return;
        }
        address to = toS % 3 == 0 ? m : _recipient(toS);
        _doMint(m, P, L, to, abi.encodeCall(PageNFT.registerSubpageFor, (L.raw, P, to)));
        _bump("recycleMint");
    }

    function act_approve(uint256 whoS, uint256 idS, uint256 spS) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        spS = _h(spS, 2);
        uint256 id = _pickAnyId(idS);
        address caller = whoS % 3 != 2 && _isActor(gOwner[id]) ? gOwner[id] : _actor(whoS >> 8);
        address[5] memory sp = [op, hot, stranger, address(bot), address(0)];
        address spender = sp[spS % 5];
        bytes4 exp;
        if (!g[id].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (caller != gOwner[id] && !nft.isApprovedForAll(gOwner[id], caller)) exp = ERC721.NotOwnerNorApproved.selector;
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.approve, (spender, id)));
        _expect("approve", exp, ok, ret);
        _bump(ok ? "approve.ok" : "approve.refused");
    }

    function act_setApprovalForAll(uint256 whoS, uint256 opS, bool on) external step(false) {
        whoS = _h(whoS, 0);
        opS = _h(opS, 1);
        address caller = _actor(whoS);
        address[4] memory ops = [op, hot, address(bot), stranger];
        (bool ok, bytes memory ret) =
            _call(caller, address(nft), 0, abi.encodeCall(ERC721.setApprovalForAll, (ops[opS % 4], on)));
        _expect("setApprovalForAll", bytes4(0), ok, ret);
        _bump("approveAll.ok");
    }

    function act_setMinter(uint256 whoS, uint256 pS, uint256 mS) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        mS = _h(mS, 2);
        uint256 P = _pickParent(pS);
        MinterG memory m = gMinter[P];
        uint256 r = whoS % 8;
        address caller = r < 4 ? gOwner[P] : r < 6 ? m.setter : r == 6 ? m.minter : _actor(whoS >> 8);
        if (!_isActor(caller)) caller = _actor(whoS >> 8);
        uint256 k = mS % 10;
        address minter = k < 2 ? address(reg) : k < 4 ? hot : k == 4 ? address(bot) : k == 5 ? hot2
            : k == 6 ? address(safe) : k < 9 ? address(0) : _actor(mS >> 8);
        if (caller == m.setter && caller != gOwner[P] && (mS >> 32) % 3 != 0) minter = address(0);
        _doSetMinter(caller, P, minter);
    }

    function _doSetMinter(address caller, uint256 P, address minter) internal {
        bytes4 exp;
        if (!g[P].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (g[P].parent != 0) exp = PageNFT.NotTopLevel.selector;
        else if (minter != address(0) && _now() > g[P].expiresAt) exp = PageNFT.Expired.selector;
        else if (gOwner[P] != caller && (minter != address(0) || gMinter[P].setter != caller)) {
            exp = PageNFT.Unauthorized.selector;
        }
        (bool ok, bytes memory ret) =
            _call(caller, address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (P, minter)));
        Vm.Log[] memory logs = _logs();
        _expect("setSubpageMinter", exp, ok, ret);
        bool away = gOwner[P] != caller;
        if (!ok) {
            _bump(string.concat(away ? "setMinter.refused.notHolder." : "setMinter.refused.", vm.toString(abi.encodePacked(exp))));
            return;
        }
        uint64 epoch = g[P].epoch;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) continue;
            ++n;
            require(logs[i].topics.length == 4 && logs[i].topics[0] == T_MINTER_SET, "setSubpageMinter: log kind");
            require(uint256(logs[i].topics[1]) == P, "setSubpageMinter: log parent");
            require(address(uint160(uint256(logs[i].topics[2]))) == caller, "setSubpageMinter: log account");
            require(address(uint160(uint256(logs[i].topics[3]))) == minter, "setSubpageMinter: log minter");
            require(keccak256(logs[i].data) == keccak256(abi.encode(epoch)), "setSubpageMinter: log data");
        }
        require(n == 1, "setSubpageMinter: log count");
        gMinter[P] = MinterG(minter, epoch, caller);
        if (away) _bump("setMinter.switchOffAway");
        else if (minter == address(0)) _bump("setMinter.clear");
        else _bump("setMinter.pick");
        if (minter == address(reg)) _bump("setMinter.registrar");
    }

    function act_mint(uint256 whoS, uint256 pS, uint256 lS, uint256 toS) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        lS = _h(lS, 2);
        toS = _h(toS, 3);
        uint256 P = _pickParent(pS);
        uint256 lk = lS % 6;
        Label memory L = lk < 2 ? _existingSubLabel(P, lS >> 8) : lk == 2 ? _deadSubLabel(P, lS >> 8) : _subLabel(lS);
        address counted = _mMinter(P);
        uint256 r = whoS % 8;
        address caller = r < 3 ? gOwner[P] : r < 6 ? counted : r == 6 ? gMinter[P].minter : _actor(whoS >> 8);
        if (!_isActor(caller)) caller = _actor(whoS >> 8);
        bool self = toS % 3 == 0;
        address to = self ? caller : _recipient(toS);
        bytes memory data = self
            ? abi.encodeCall(PageNFT.registerSubpage, (L.raw, P))
            : abi.encodeCall(PageNFT.registerSubpageFor, (L.raw, P, to));
        _doMint(caller, P, L, to, data);
    }

    struct MintCtx {
        uint256 sub;
        bytes4 exp;
        bool byOwner;
        bool byMinter;
        bool wasLive;
        bool existed;
        address oldOwner;
        address nftOwner;
        address nftMinter;
        bool wasDead;
    }

    function _predictMint(address caller, uint256 P, Label memory L, address to)
        internal
        view
        returns (MintCtx memory c)
    {
        c.sub = L.err == 0 ? _subId(L.norm, P) : 0;
        c.existed = g[c.sub].exists;
        c.oldOwner = gOwner[c.sub];
        c.wasLive = c.existed && _mLive(c.sub);
        // a live subpage held by DEAD counts as free
        c.wasDead = c.wasLive && c.oldOwner == DEAD;
        address owner = gOwner[P];
        address m = _mMinter(P);
        c.byOwner = owner == caller && g[P].exists;
        c.byMinter = !c.byOwner && m == caller && m != address(0);
        if (L.err != 0) c.exp = L.err;
        else if (P == 0 || !g[P].exists) c.exp = ERC721.TokenDoesNotExist.selector;
        else if (g[P].parent != 0) c.exp = PageNFT.NotTopLevel.selector;
        else if (_now() > g[P].expiresAt) c.exp = PageNFT.Expired.selector;
        else if (owner != caller && m != caller) c.exp = PageNFT.NotParentOwner.selector;
        else if (owner != caller && c.wasLive && !c.wasDead) c.exp = PageNFT.AlreadyRegistered.selector;
        else if (to == address(nft)) c.exp = PageNFT.InvalidRecipient.selector;
        else if (to == address(0)) c.exp = TO_ZERO;
        else if (!_takesNFT(to)) c.exp = NON_RECEIVER;
    }

    // what PageNFT itself says just before the mint, kept in the log beside the model's answer
    function _nftView(MintCtx memory c, uint256 P) internal view {
        if (P == 0 || !g[P].exists) return;
        c.nftOwner = nft.ownerOf(P);
        c.nftMinter = nft.subpageMinterOf(P);
    }

    // a mint by caller straight to PageNFT; a registrar sale predicts and applies its mint on its own
    function _doMint(address caller, uint256 P, Label memory L, address to, bytes memory data) internal {
        MintCtx memory c = _predictMint(caller, P, L, to);
        _nftView(c, P);
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, data);
        Vm.Log[] memory logs = _logs();
        _expect("registerSubpage", c.exp, ok, ret);
        if (!ok) {
            if (c.exp == PageNFT.AlreadyRegistered.selector) _bump("mint.createOnlyRefusedLive");
            else if (c.exp == PageNFT.NotParentOwner.selector) _bump("mint.refused.notOwnerNorMinter");
            else _bump(string.concat("mint.refused.", vm.toString(abi.encodePacked(c.exp))));
            return;
        }
        _checkTransfers(logs, c.existed, c.oldOwner, address(0), to, c.sub);
        _applySubMint(c, P, caller, to);
    }

    function _applySubMint(MintCtx memory c, uint256 P, address caller, address to) internal {
        require(c.byOwner || c.byMinter, "a subpage was minted by neither the holder nor the counted minter");
        require(!(c.byMinter && c.wasLive && !c.wasDead), "a minter overwrote a live subpage");
        mintLog.push(
            MintLog(c.sub, P, caller, to, c.byOwner, c.byMinter, c.wasLive, c.nftOwner, c.nftMinter, c.wasDead)
        );
        if (c.wasDead) _bump(c.byOwner ? "recycle.owner" : caller == address(reg) ? "recycle.sale" : "recycle.minter");
        if (to == DEAD) _bump(c.wasLive ? "recycle.liveToDead" : "recycle.mintToDead");
        if (c.byOwner) _bump(c.wasLive ? "mint.owner.takeBack" : c.existed ? "mint.owner.stale" : "mint.owner.fresh");
        else _bump(c.wasDead ? "mint.minter.overDead" : c.existed ? "mint.minter.stale" : "mint.minter.fresh");
        if (c.byMinter && caller.code.length > 0) _bump("mint.minter.contract");
        if (c.byMinter && caller.code.length == 0) _bump("mint.minter.eoa");
        Rec storage r = g[c.sub];
        if (c.existed) {
            if (gPrimary[c.oldOwner] == c.sub) delete gPrimary[c.oldOwner];
            gVersion[c.sub] += 1;
        }
        r.epoch = c.existed ? r.epoch + 1 : 1;
        r.exists = true;
        r.label = _normOfSub(c.sub, P);
        r.parent = P;
        r.parentEpoch = g[P].epoch;
        r.expiresAt = 0;
        gOwner[c.sub] = to;
        gPlainInReg[c.sub] = false;
        gMintCount[c.sub] += 1;
    }

    function _normOfSub(uint256 sub, uint256 P) internal view returns (string memory) {
        for (uint256 i; i < subNorm.length; ++i) if (_subId(subNorm[i], P) == sub) return subNorm[i];
        revert("unknown subpage id");
    }

    function act_configure(uint256 whoS, uint256 pS, uint256 cfgS) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        cfgS = _h(cfgS, 2);
        uint256 r = pS % 12;
        uint256 P = r == 0 ? subs[(pS >> 8) % subs.length] : r == 1 ? unregTop : parents[(pS >> 8) % 5];
        address caller = whoS % 5 != 4 && _isActor(gOwner[P]) ? gOwner[P] : _actor(whoS >> 8);
        Cfg memory c = _cfg(caller, cfgS);
        _doConfigure(caller, P, c.pay, c.feeToken, c.price, c.enabled, c.gateToken, c.minGate, c.commitReveal);
    }

    struct Cfg {
        address pay;
        address feeToken;
        uint256 price;
        bool enabled;
        address gateToken;
        uint256 minGate;
        bool commitReveal;
    }

    function _cfg(address caller, uint256 cfgS) internal view returns (Cfg memory c) {
        uint256 k = cfgS % 10;
        c.pay = k == 0 ? address(0) : k == 1 ? caller : k < 4 ? payoutEOA : k == 4 ? address(rejecter)
            : k == 5 ? (cfgS >> 60) % 4 == 0 ? address(reg) : payoutEOA : k == 6 ? (cfgS >> 60) % 4 == 0 ? address(nft) : actors[1]
            : k == 7 ? actors[1] : k == 8 ? address(safe) : address(bot);
        uint256 f = (cfgS >> 8) % 10;
        c.feeToken = f < 6 ? address(0) : f < 9 ? address(usd) : (cfgS >> 62) % 2 == 0 ? address(nft) : address(reg);
        uint256 pr = (cfgS >> 16) % 7;
        c.price = pr == 0 ? 0 : pr == 1 ? 0.001 ether : pr == 2 ? 0.02 ether : pr == 3 ? 1 ether : pr == 4 ? 7
            : pr == 5 ? 0.01 ether : (cfgS >> 24) % 8 == 0 ? uint256(type(uint96).max) + 1 : 0.3 ether;
        c.enabled = (cfgS >> 32) % 8 != 0;
        uint256 gt = (cfgS >> 40) % 8;
        c.gateToken = gt < 5 ? address(0) : address(gate);
        c.minGate = gt < 5 ? 0 : 1 + (cfgS >> 48) % 1500;
        if (gt == 7 && (cfgS >> 56) % 4 == 0) c.minGate = 0; // mismatched gate
        c.commitReveal = (cfgS >> 58) % 4 == 0;
    }

    // the two setup transactions a seller sends: pick the registrar as minter, then configure
    function act_setupSale(uint256 whoS, uint256 pS, uint256 cfgS) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        cfgS = _h(cfgS, 2);
        uint256 P = parents[pS % 5];
        address caller = _isActor(gOwner[P]) ? gOwner[P] : _actor(whoS);
        _doSetMinter(caller, P, address(reg));
        Cfg memory c = _cfg(caller, cfgS);
        _doConfigure(caller, P, c.pay, c.feeToken, c.price, true, c.gateToken, c.minGate, c.commitReveal);
        _bump("setupSale");
    }

    function _doConfigure(
        address caller,
        uint256 P,
        address pay,
        address feeToken,
        uint256 price,
        bool enabled,
        address gateToken,
        uint256 minGate,
        bool commitReveal
    ) internal {
        address effPay = pay == address(0) ? caller : pay;
        bytes4 exp;
        if (!g[P].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (gOwner[P] != caller) exp = SubpageRegistrar.NotAuthorized.selector;
        else if (g[P].parent != 0) exp = SubpageRegistrar.ParentNotTopLevel.selector;
        else if (effPay == address(reg) || effPay == address(nft)) exp = SubpageRegistrar.NotAuthorized.selector;
        else if (feeToken == address(nft) || feeToken == address(reg)) exp = SubpageRegistrar.BadFeeToken.selector;
        else if (price > type(uint96).max || minGate > type(uint96).max) exp = SubpageRegistrar.ValueTooLarge.selector;
        else if ((gateToken != address(0)) != (minGate != 0)) exp = SubpageRegistrar.BadGateConfig.selector;
        (bool ok, bytes memory ret) = _call(
            caller,
            address(reg),
            0,
            abi.encodeCall(
                SubpageRegistrar.configure, (P, pay, feeToken, price, enabled, gateToken, minGate, commitReveal)
            )
        );
        _expect("configure", exp, ok, ret);
        _bump(ok ? "configure.ok" : "configure.refused");
        if (!ok) return;
        gConfig[P] = ConfigG(
            caller, enabled, commitReveal, feeToken, uint96(price), gateToken, uint96(minGate), effPay, g[P].epoch
        );
    }

    function act_disable(uint256 whoS, uint256 pS) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        uint256 P = _pickParent(pS);
        address caller = whoS % 3 != 2 && _isActor(gOwner[P]) ? gOwner[P] : _actor(whoS >> 8);
        bytes4 exp;
        if (!g[P].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (gOwner[P] != caller) exp = SubpageRegistrar.NotAuthorized.selector;
        (bool ok, bytes memory ret) = _call(caller, address(reg), 0, abi.encodeCall(SubpageRegistrar.disable, (P)));
        _expect("disable", exp, ok, ret);
        _bump(ok ? "disable.ok" : "disable.refused");
        if (ok) gConfig[P].enabled = false;
    }

    struct SaleCtx {
        uint256 P;
        address buyer;
        address to;
        uint256 maxPrice;
        address expFee;
        uint256 value;
        bool viaReveal;
        bool committed;
        uint256 age;
        bytes32 secret;
        bytes4 exp;
        uint256 buyerEth;
        uint256 buyerUsd;
        uint256 payoutUsd;
    }

    function act_sell(uint256 whoS, uint256 pS, uint256 lS, uint256 toS, uint256 mode) external step(false) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        lS = _h(lS, 2);
        toS = _h(toS, 3);
        mode = _h(mode, 4);
        SaleCtx memory s;
        s.P = pS % 16 == 0 ? _pickParent(pS >> 8) : pS % 2 == 0 ? _enabledParent(pS >> 8) : parents[(pS >> 8) % 5];
        s.buyer = _actor(whoS);
        Label memory L = lS % 5 == 0 ? _existingSubLabel(s.P, lS >> 8) : lS % 5 == 1 ? _deadSubLabel(s.P, lS >> 8) : _subLabel(lS);
        s.to = toS % 3 == 0 ? s.buyer : _recipient(toS);
        ConfigG memory c = gConfig[s.P];
        s.maxPrice = mode % 13 == 1 && c.price > 0 ? c.price - 1 : uint256(c.price) + (mode >> 8) % 3;
        s.expFee = mode % 17 == 2 ? (c.feeToken == address(0) ? address(usd) : address(0)) : c.feeToken;
        s.value = c.feeToken == address(0) ? uint256(c.price) + ((mode >> 16) % 4 == 0 ? (mode >> 24) % 1e15 : 0) : 0;
        if (mode % 19 == 3) s.value = c.price > 0 && c.feeToken == address(0) ? c.price - 1 : 1;
        s.viaReveal = c.commitReveal || mode % 5 == 0;
        if (s.viaReveal) {
            s.secret = keccak256(abi.encode(whoS, pS, lS, toS, mode, _now()));
            bytes32 commitment = L.err == 0
                ? keccak256(abi.encode(s.P, L.norm, s.to, s.secret))
                : keccak256(abi.encode(s.secret));
            s.committed = mode % 23 != 4;
            if (s.committed) {
                (bool cok, bytes memory cret) =
                    _call(_actor(mode >> 32), address(reg), 0, abi.encodeCall(SubpageRegistrar.commitSubpage, (commitment)));
                _expect("commitSubpage", bytes4(0), cok, cret);
            }
            s.age = mode % 29 == 6 ? 10 : 61 + (mode >> 40) % 600;
            _warp(s.age);
        }
        s.exp = _predictSale(s, c, L);

        vm.deal(s.buyer, s.buyer.balance + s.value);
        s.buyerEth = s.buyer.balance;
        s.buyerUsd = usd.balanceOf(s.buyer);
        s.payoutUsd = usd.balanceOf(c.payout);
        bytes memory data = s.viaReveal
            ? s.to == s.buyer && mode % 2 == 0
                ? abi.encodeCall(SubpageRegistrar.revealSubpage, (s.P, L.raw, s.secret, s.maxPrice, s.expFee))
                : abi.encodeCall(SubpageRegistrar.revealSubpageFor, (s.P, L.raw, s.to, s.secret, s.maxPrice, s.expFee))
            : s.to == s.buyer && mode % 2 == 0
                ? abi.encodeCall(SubpageRegistrar.registerSubpage, (s.P, L.raw, s.maxPrice, s.expFee))
                : abi.encodeCall(SubpageRegistrar.registerSubpageFor, (s.P, L.raw, s.to, s.maxPrice, s.expFee));

        MintCtx memory mc;
        if (s.exp == bytes4(0) || s.exp == PageNFT.InvalidRecipient.selector || s.exp == NON_RECEIVER || s.exp == TO_ZERO) {
            mc = _predictMint(address(reg), s.P, L, s.to);
            _nftView(mc, s.P);
        }
        (bool ok, bytes memory ret) = _call(s.buyer, address(reg), s.value, data);
        Vm.Log[] memory logs = _logs();
        _expect("sale", s.exp, ok, ret);
        if (!ok) {
            require(s.buyer.balance == s.buyerEth, "sale: failed call moved the buyer's ETH");
            _bumpSaleRefusal(s.exp);
            return;
        }
        require(mc.exp == bytes4(0), "sale: the registrar mint should have failed");
        _checkTransfers(logs, mc.existed, mc.oldOwner, address(0), s.to, mc.sub);
        _applySubMint(mc, s.P, address(reg), s.to);
        if (c.feeToken == address(0)) {
            require(s.buyerEth - s.buyer.balance == c.price, "sale: buyer charged other than the price");
            gProceeds[c.payout] += c.price;
            _bump(c.price == 0 ? "sale.ok.free" : "sale.ok.eth");
        } else {
            require(s.buyerEth == s.buyer.balance, "sale: ERC20 sale moved ETH");
            if (s.buyer != c.payout) {
                require(s.buyerUsd - usd.balanceOf(s.buyer) == c.price, "sale: buyer ERC20");
                require(usd.balanceOf(c.payout) - s.payoutUsd == c.price, "sale: payout ERC20");
            }
            _bump("sale.ok.erc20");
        }
        if (c.gateToken != address(0)) _bump("sale.ok.gated");
        if (s.viaReveal) _bump("sale.ok.reveal");
        if (mc.existed) _bump(mc.wasDead ? "sale.ok.deadLabel" : "sale.ok.staleLabel");
    }

    function _predictSale(SaleCtx memory s, ConfigG memory c, Label memory L) internal view returns (bytes4) {
        if (s.to == address(reg)) return SubpageRegistrar.NotAuthorized.selector;
        if (!c.enabled) return SubpageRegistrar.NotEnabled.selector;
        if (c.feeToken != s.expFee) return SubpageRegistrar.UnexpectedFeeToken.selector;
        if (uint256(c.price) > s.maxPrice) return SubpageRegistrar.PriceTooHigh.selector;
        if (!s.viaReveal) {
            if (c.commitReveal) return SubpageRegistrar.CommitRequired.selector;
        } else {
            if (L.err != 0) return L.err;
            if (!s.committed) return SubpageRegistrar.CommitmentNotFound.selector;
            if (s.age < 20) return SubpageRegistrar.CommitmentTooNew.selector;
        }
        if (g[s.P].parent != 0) return SubpageRegistrar.ParentNotTopLevel.selector;
        if (g[s.P].epoch != c.parentEpoch) return SubpageRegistrar.StaleConfig.selector;
        if (gOwner[s.P] != c.controller) return SubpageRegistrar.StaleController.selector;
        address m = _mMinter(s.P);
        if (m != address(reg)) return SubpageRegistrar.NotMinter.selector;
        if (!_mAvailableSub(L, s.P)) return SubpageRegistrar.NotAvailable.selector;
        if (c.gateToken != address(0) && gate.balanceOf(s.buyer) < c.minGate) return SubpageRegistrar.GateFailed.selector;
        if (c.feeToken == address(0)) {
            if (s.value < c.price) return SubpageRegistrar.InsufficientFee.selector;
        } else if (s.value != 0) {
            return SubpageRegistrar.UnexpectedETH.selector;
        }
        if (s.to == address(nft)) return PageNFT.InvalidRecipient.selector;
        if (s.to == address(0)) return TO_ZERO;
        if (!_takesNFT(s.to)) return NON_RECEIVER;
        if (c.feeToken != address(0) && c.price != 0 && s.buyer == stranger) {
            return SafeTransferLib.TransferFromFailed.selector;
        }
        return bytes4(0);
    }

    function _bumpSaleRefusal(bytes4 e) internal {
        if (e == SubpageRegistrar.NotMinter.selector) _bump("sale.refused.NotMinter");
        else if (e == SubpageRegistrar.StaleController.selector) _bump("sale.refused.StaleController");
        else if (e == SubpageRegistrar.StaleConfig.selector) _bump("sale.refused.StaleConfig");
        else if (e == SubpageRegistrar.NotAvailable.selector) _bump("sale.refused.NotAvailable");
        else if (e == SubpageRegistrar.NotEnabled.selector) _bump("sale.refused.NotEnabled");
        else if (e == SubpageRegistrar.GateFailed.selector) _bump("sale.refused.GateFailed");
        else _bump(string.concat("sale.refused.", vm.toString(abi.encodePacked(e))));
    }

    function _mAvailableSub(Label memory L, uint256 P) internal view returns (bool) {
        if (L.err != 0) return false;
        if (!g[P].exists || g[P].parent != 0 || !_mActive(P)) return false;
        uint256 s = _subId(L.norm, P);
        if (!g[s].exists) return true;
        return g[s].parentEpoch != g[P].epoch || gOwner[s] == DEAD;
    }

    function act_claim(uint256 whoS, uint256 toS, uint256 mode) external step(false) {
        whoS = _h(whoS, 0);
        toS = _h(toS, 1);
        mode = _h(mode, 2);
        address account;
        address to;
        address caller;
        bytes memory data;
        if (mode % 2 == 0) {
            uint256 r = whoS % 6;
            account = r == 0 ? payoutEOA : r == 1 ? address(rejecter) : _actor(whoS >> 8);
            caller = account;
            uint256 t = toS % 7;
            address argTo = t == 0 ? address(0) : t == 1 ? account : t == 2 ? address(reg) : t == 3 ? address(rejecter)
                : t == 4 ? actors[3] : t == 5 ? address(noHook) : payoutEOA;
            to = argTo == address(0) ? account : argTo;
            data = abi.encodeCall(SubpageRegistrar.claimProceeds, (argTo));
        } else {
            uint256 r = toS % 8;
            account = r == 0 ? payoutEOA : r == 1 ? address(rejecter) : r == 2 ? address(reg) : r == 3 ? address(nft)
                : r == 4 ? DEAD : _actor(toS >> 8);
            caller = _actor(whoS);
            to = account;
            data = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (account));
        }
        uint256 amount = gProceeds[account];
        bytes4 exp;
        if (amount == 0) exp = SubpageRegistrar.NothingToClaim.selector;
        else if (to == address(reg)) exp = SubpageRegistrar.NotAuthorized.selector;
        else if (!_takesETH(to)) exp = SafeTransferLib.ETHTransferFailed.selector;
        uint256 before = to.balance;
        (bool ok, bytes memory ret) = _call(caller, address(reg), 0, data);
        _expect("claim", exp, ok, ret);
        _bump(ok ? "claim.ok" : "claim.refused");
        if (!ok) return;
        require(to.balance - before == amount, "claim: recipient got other than the amount");
        gProceeds[account] = 0;
    }

    function act_withdraw(uint256 whoS, uint256 aS) external step(true) {
        whoS = _h(whoS, 0);
        aS = _h(aS, 1);
        address account = accts[aS % accts.length];
        address caller = _actor(whoS);
        uint256 amount = gOwed[account];
        bytes4 exp;
        if (amount == 0) exp = PageNFT.NothingToWithdraw.selector;
        else if (!_takesETH(account)) exp = SafeTransferLib.ETHTransferFailed.selector;
        uint256 before = account.balance;
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.withdraw, (account)));
        _expect("withdraw", exp, ok, ret);
        _bump(ok ? "withdraw.ok" : "withdraw.refused");
        if (!ok) return;
        require(account.balance - before == amount, "withdraw: amount");
        gOwed[account] = 0;
    }

    function act_release(uint256 whoS, uint256 pS) external step(true) {
        whoS = _h(whoS, 0);
        pS = _h(pS, 1);
        uint256 id = _pickParent(pS);
        bytes4 exp;
        if (!g[id].exists) exp = ERC721.TokenDoesNotExist.selector;
        else if (g[id].parent != 0) exp = PageNFT.NotTopLevel.selector;
        else if (_now() <= uint256(g[id].expiresAt) + GRACE + DECAY) exp = PageNFT.NotReleasable.selector;
        else if (gDeposit[id] == 0) exp = PageNFT.NothingToRelease.selector;
        (bool ok, bytes memory ret) = _call(_actor(whoS), address(nft), 0, abi.encodeCall(PageNFT.release, (id)));
        _expect("release", exp, ok, ret);
        _bump(ok ? "release.ok" : "release.refused");
        if (!ok) return;
        _mCredit(_mPayee(id), gDeposit[id]);
        gDeposit[id] = 0;
    }

    function act_warp(uint256 s) external step(false) {
        s = _h(s, 0);
        uint256 n = s % 10 == 0 ? s % 120 days : s % 2 days;
        _warp(n);
        _bump("warp");
    }

    function act_setAddr(uint256 whoS, uint256 idS, uint256 aS, uint256 mode) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        aS = _h(aS, 2);
        mode = _h(mode, 3);
        uint256 id = _pickAnyId(idS);
        address caller = whoS % 5 != 4 && _isActor(gOwner[id]) ? gOwner[id] : _actor(whoS >> 8);
        address a = addrPool[aS % addrPool.length];
        uint256 k = mode % 7;
        bytes memory data;
        bytes4 exp;
        if (!_mActive(id)) exp = PageNFT.Expired.selector;
        else if (gOwner[id] != caller) exp = PageNFT.Unauthorized.selector;
        if (k < 3) {
            data = abi.encodeCall(PageNFT.setAddr, (id, a));
            if (exp == 0 && a == address(nft)) exp = PageNFT.InvalidRecipient.selector;
        } else if (k == 3) {
            bytes memory v = a == address(0) && (aS >> 8) % 2 == 0 ? bytes("") : abi.encodePacked(a);
            data = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, v));
            if (exp == 0 && a == address(nft)) exp = PageNFT.InvalidRecipient.selector;
        } else if (k < 6) {
            bytes memory v = a == address(0) && (aS >> 8) % 2 == 0 ? bytes("") : abi.encodePacked(a);
            data = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_ETH, v));
        } else if ((aS >> 8) % 2 == 0) {
            data = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, abi.encodePacked(a)));
        } else {
            data = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_ETH, hex"0102"));
            if (exp == 0) exp = PageNFT.InvalidLength.selector;
        }
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, data);
        _expect("setAddr", exp, ok, ret);
        if (g[id].exists && gOwner[id] == DEAD) _bump("setAddr.onDeleted");
        _bump(ok ? (k < 4 ? "setAddr.main.ok" : k < 6 ? "setAddr.coin60.ok" : "setAddr.default.ok") : "setAddr.refused");
        if (!ok) return;
        if (k < 4) gAddr[id][gVersion[id]] = Saved(a, caller);
        else if (k < 6) gCoin60[id][gVersion[id]] = Saved(a, caller);
        else gDefault[id][gVersion[id]] = Saved(a, caller);
    }

    function _pSlot(uint256 id) internal view returns (uint256) {
        return gVersion[id] << 96 | gPVer[id];
    }

    // a write by someone other than the writer starts an empty profile
    function _pWrite(uint256 id, address caller) internal {
        if (gWriter[id] == caller) return;
        if (gWriter[id] != address(0)) gPVer[id] += 1;
        gWriter[id] = caller;
    }

    // a profile: text and website, which count only while their writer holds the name
    function act_setProfile(uint256 whoS, uint256 idS, uint256 vS) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        vS = _h(vS, 2);
        uint256 id = _pickAnyId(idS);
        address caller = whoS % 5 != 4 && _isActor(gOwner[id]) ? gOwner[id] : _actor(whoS >> 8);
        bytes4 exp;
        if (!_mActive(id)) exp = PageNFT.Expired.selector;
        else if (gOwner[id] != caller) exp = PageNFT.Unauthorized.selector;
        bool isText = vS % 2 == 0;
        string memory t = string.concat("t", vm.toString(vS % 1000));
        bytes memory hsh = abi.encodePacked(uint16(vS % 65536));
        bytes memory data = isText
            ? abi.encodeCall(PageNFT.setText, (id, "url", t))
            : abi.encodeCall(PageNFT.setContenthash, (id, hsh));
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, data);
        _expect("setProfile", exp, ok, ret);
        _bump(ok ? "profile.ok" : "profile.refused");
        if (g[id].exists && gOwner[id] == DEAD) _bump("profile.onDeleted");
        if (!ok) return;
        _pWrite(id, caller);
        if (isText) gText[id][_pSlot(id)] = t;
        else gHash[id][_pSlot(id)] = hsh;
    }

    function act_clearRecords(uint256 whoS, uint256 idS) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        uint256 id = _pickAnyId(idS);
        address caller = whoS % 4 != 3 && _isActor(gOwner[id]) ? gOwner[id] : _actor(whoS >> 8);
        bytes4 exp;
        if (!_mActive(id)) exp = PageNFT.Expired.selector;
        else if (gOwner[id] != caller) exp = PageNFT.Unauthorized.selector;
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.clearRecords, (id)));
        _expect("clearRecords", exp, ok, ret);
        _bump(ok ? "clearRecords.ok" : "clearRecords.refused");
        if (ok) gVersion[id] += 1;
    }

    // an active name held by an actor, else any pool id
    function _heldId(uint256 s) internal view returns (uint256) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[(s + i) % ids.length];
            if (_mActive(id) && _isActor(gOwner[id])) return id;
        }
        return _pickAnyId(s);
    }

    // a data record, written mostly by the holder of an active name and sometimes by another account
    function act_setData(uint256 whoS, uint256 idS, uint256 kS, uint256 vS) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        kS = _h(kS, 2);
        vS = _h(vS, 3);
        uint256 id = idS % 4 != 0 ? _heldId(idS >> 8) : _pickAnyId(idS >> 8);
        address caller = whoS % 5 != 4 && _isActor(gOwner[id]) ? gOwner[id] : _actor(whoS >> 8);
        uint256 k = kS % 2;
        bytes memory v = vS % 7 == 0 ? bytes("") : abi.encodePacked(uint64(vS));
        bytes4 exp;
        if (!_mActive(id)) exp = PageNFT.Expired.selector;
        else if (gOwner[id] != caller) exp = PageNFT.Unauthorized.selector;
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.setData, (id, dataKeys[k], v)));
        _logs();
        _expect("setData", exp, ok, ret);
        if (g[id].exists && gOwner[id] == DEAD) _bump("data.onDeleted");
        _bump(ok ? "data.ok" : "data.refused");
        if (ok) gData[id][gVersion[id]][k] = DataG(caller, v);
    }

    function act_setPrimary(uint256 whoS, uint256 idS) external step(false) {
        whoS = _h(whoS, 0);
        idS = _h(idS, 1);
        uint256 id = idS % 10 == 0 ? 0 : _pickAnyId(idS >> 4);
        uint256 r = whoS % 3;
        address caller = r == 0 ? gOwner[id] : r == 1 ? _mResolve(id) : _actor(whoS >> 8);
        if (!_isActor(caller)) caller = _actor(whoS >> 8);
        _doSetPrimary(caller, id);
    }

    function _doSetPrimary(address caller, uint256 id) internal {
        bytes4 exp;
        if (id != 0) {
            if (!_mActive(id)) exp = PageNFT.Expired.selector;
            else if (caller != gOwner[id] && caller != _mResolve(id)) exp = PageNFT.Unauthorized.selector;
        }
        (bool ok, bytes memory ret) = _call(caller, address(nft), 0, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _expect("setPrimaryPage", exp, ok, ret);
        _bump(ok ? "primary.ok" : "primary.refused");
        if (ok) {
            gPrimary[caller] = id;
            if (id != 0) {
                gGaveAway[caller][id] = false;
                gHolder[caller] = gOwner[id];
            }
        }
    }

    // The wallet rule, after every step. holderSince and addressesUpdatedAt never go down. While a name is active, a
    // change in its address answers since they were last seen active comes with one of the two times at or after that
    // moment. A step can hold a commit wait, so the change need not carry the step's last time.
    function _walletRule() internal {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 since = nft.holderSince(id);
            uint256 addrAt = nft.addressesUpdatedAt(id);
            require(since >= lastSince[id] && addrAt >= lastAddrAt[id], "a time went down");
            lastSince[id] = since;
            lastAddrAt[id] = addrAt;
            if (!_mActive(id)) continue;
            bytes32 a = keccak256(
                abi.encode(
                    nft.resolve(id), nft.addr(bytes32(id)), nft.addr(id, COIN_OP), nft.addr(id, COIN_ETH),
                    nft.addr(id, DEFAULT_EVM), nft.addr(id, COIN_BASE), nft.addr(id, 0)
                )
            );
            Seen storage s = lastActive[id];
            if (s.set && s.answers != a) {
                require(since >= s.time || addrAt >= s.time, "wallet rule: the answers changed with no new time");
                _bump("wallet.changeWithTime");
            }
            lastActive[id] = Seen(true, _now(), a);
        }
    }

    // checks, run after every call

    // holderSince and addressesUpdatedAt equal the times the model set, and neither is in the future
    function checkTimes() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 since = nft.holderSince(id);
            uint256 addrAt = nft.addressesUpdatedAt(id);
            require(since <= _now() && addrAt <= _now(), "a time in the future");
            require(since == gSince[id], "holderSince");
            require(addrAt == gAddrAt[id], "addressesUpdatedAt");
            require((since != 0) == g[id].exists, "holderSince is zero only for a name never minted");
        }
    }

    // a data record shows only while the name is active and the account that saved it in this record version holds it
    function checkData() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            for (uint256 k; k < 2; ++k) {
                DataG storage d = gData[id][gVersion[id]][k];
                bytes memory want = _mActive(id) && d.saver == gOwner[id] ? d.value : bytes("");
                require(keccak256(nft.data(bytes32(id), dataKeys[k])) == keccak256(want), "data");
            }
        }
    }

    function checkRecords() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            Rec storage r = g[id];
            (string memory label, uint256 parent, uint64 exp, uint64 ep, uint64 pep) = nft.records(id);
            require(keccak256(bytes(label)) == keccak256(bytes(r.exists ? r.label : "")), "record label");
            require(parent == r.parent && exp == r.expiresAt && ep == r.epoch && pep == r.parentEpoch, "record fields");
            require(nft.recordVersion(id) == gVersion[id], "record version");
            require(nft.depositOf(id) == gDeposit[id], "deposit");
            require(nft.referrerOf(id) == gReferrer[id], "referrer");
            if (r.exists && r.parent != 0) require(gDeposit[id] == 0 && gReferrer[id] == 0, "subpage ledger");
            try nft.ownerOf(id) returns (address o) {
                require(r.exists && o == gOwner[id], "owner");
            } catch {
                require(!r.exists, "record without a token");
            }
        }
        require(nft.balanceOf(address(nft)) == 0, "the registry owns a name");
    }

    // isAvailable against the model for every pool label under every pool parent, a subpage used as
    // a parent, and every top level label, including ones DEAD holds
    function checkAvailability() external view {
        for (uint256 p; p < 5; ++p) {
            uint256 P = parents[p];
            for (uint256 k; k < subLabels.length; ++k) {
                Label memory L = subLabels[k];
                require(nft.isAvailable(L.raw, P) == _mAvailableSub(L, P), "isAvailable of a subpage");
            }
            require(!nft.isAvailable("a", subs[p * 6]), "a subpage is never a parent");
        }
        for (uint256 k; k < topLabels.length; ++k) {
            Label memory L = topLabels[k];
            bool want;
            if (L.err == 0) {
                uint256 id = _topId(L.norm);
                want = !g[id].exists || _now() > uint256(g[id].expiresAt) + GRACE;
            }
            require(nft.isAvailable(L.raw, 0) == want, "isAvailable of a top-level name");
        }
    }

    function checkMinter() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 P = ids[i];
            require(nft.subpageMinterOf(P) == _mMinter(P), "subpageMinterOf differs from the model");
            bytes32 base = keccak256(abi.encode(P, uint256(12)));
            uint256 w0 = uint256(vm.load(address(nft), base));
            uint256 w1 = uint256(vm.load(address(nft), bytes32(uint256(base) + 1)));
            MinterG storage gm = gMinter[P];
            require(address(uint160(w0)) == gm.minter, "raw minter");
            require(uint64(w0 >> 160) == gm.epoch, "raw epoch");
            require((w0 >> 224) == 0, "raw high bits");
            require(address(uint160(w1)) == gm.setter && (w1 >> 160) == 0, "raw setter");
        }
    }

    function checkSaverRule() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            bool active = _mActive(id);
            address owner = gOwner[id];
            address main = _mPointee(id, owner);
            require(nft.resolve(id) == (active ? main : address(0)), "resolve");
            require(nft.payee(id) == _mPayee(id), "payee");
            bytes memory opA = nft.addr(id, COIN_OP);
            require(keccak256(opA) == keccak256(active ? _enc(main) : bytes("")), "addr OP");
            bytes memory ethA = nft.addr(id, COIN_ETH);
            require(keccak256(ethA) == keccak256(active ? _enc(_mEth(id, owner, main)) : bytes("")), "addr 60");
            // addr with no coin type answers coin type 60 too
            require(nft.addr(bytes32(id)) == (active ? _mEth(id, owner, main) : address(0)), "addr(node)");
            address[3] memory xs = [actors[0], hot, address(bot)];
            for (uint256 j; j < 3; ++j) {
                require(nft.resolveAs(id, xs[j]) == (active ? _mPointee(id, xs[j]) : address(0)), "resolveAs");
            }
            bool counts = active && gWriter[id] == owner;
            require(nft.profileWriter(id) == gWriter[id], "profile writer");
            string memory wantText = counts ? gText[id][_pSlot(id)] : "";
            require(keccak256(bytes(nft.text(id, "url"))) == keccak256(bytes(wantText)), "text");
            bytes memory wantHash = counts ? gHash[id][_pSlot(id)] : bytes("");
            require(keccak256(nft.contenthash(id)) == keccak256(wantHash), "contenthash");
            if (!active) {
                require(nft.addr(id, COIN_BASE).length == 0 && nft.addr(id, 0).length == 0, "inactive other coins");
            }
        }
    }

    // the indexer ends on the answer of every name, an empty one for a deleted page; AddrChanged carries the coin
    // type 60 answer
    function checkIndexer() external view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (address main, address eth) = _mIndexed(id);
            require(keccak256(idxOp[id]) == keccak256(_enc(main)), "indexer OP");
            require(idxAddr[id] == eth, "indexer addr");
            require(keccak256(idx60[id]) == keccak256(_enc(eth)), "indexer 60");
        }
    }

    function checkPrimary() external view {
        for (uint256 i; i < accts.length; ++i) {
            address a = accts[i];
            uint256 t = gPrimary[a];
            require(nft.primaryPage(a) == t, "primaryPage");
            address stored = address(uint160(uint256(vm.load(address(nft), keccak256(abi.encode(a, uint256(13)))))));
            require(stored == gHolder[a], "stored holder");
            string memory want =
                (t == 0 || !_mActive(t) || gOwner[t] != gHolder[a] || _mResolve(t) != a) ? "" : _mFullName(t);
            require(keccak256(bytes(nft.reverseResolve(a))) == keccak256(bytes(want)), "reverseResolve");
        }
        for (uint256 i; i < ids.length; ++i) {
            require(
                keccak256(bytes(nft.getPageName(ids[i]))) == keccak256(bytes(_mFullName(ids[i]))), "getPageName"
            );
        }
    }

    // the reverse record indexer ends on every stored pointer
    function checkPrimaryIndexer() external view {
        for (uint256 i; i < accts.length; ++i) {
            require(idxPrimary[accts[i]] == nft.primaryPage(accts[i]), "reverse indexer");
        }
    }

    // an account that moved a name away never points at it again unless it chose it again
    function checkSellerPointer() external view {
        for (uint256 i; i < accts.length; ++i) {
            address a = accts[i];
            uint256 t = nft.primaryPage(a);
            require(t == 0 || !gGaveAway[a][t], "a seller still points at a name it moved away");
        }
    }

    function checkLedgers() external view {
        uint256 sumD;
        uint256 sumO;
        for (uint256 i; i < ids.length; ++i) sumD += gDeposit[ids[i]];
        for (uint256 i; i < accts.length; ++i) {
            require(nft.owed(accts[i]) == gOwed[accts[i]], "owed");
            sumO += gOwed[accts[i]];
        }
        require(address(nft).balance == sumD + sumO, "the balance equals the deposits plus the credits");
        uint256 sumP;
        for (uint256 i; i < accts.length; ++i) {
            require(reg.proceedsOf(accts[i]) == gProceeds[accts[i]], "proceedsOf");
            sumP += gProceeds[accts[i]];
        }
        require(address(reg).balance == sumP, "registrar solvency");
    }

    function checkRegistrarHolds() external view {
        uint256 n;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (g[id].exists && gOwner[id] == address(reg)) {
                require(gPlainInReg[id], "the registrar holds a name not sent by a plain transfer");
                ++n;
            }
        }
        require(nft.balanceOf(address(reg)) == n, "registrar balance");
    }

    function checkMintLog() external view {
        for (uint256 i; i < mintLog.length; ++i) {
            MintLog storage e = mintLog[i];
            require(e.byOwner || e.byMinter, "mint log: unauthorized");
            if (e.byMinter && e.wasLive) require(e.wasDead, "mint log: a minter overwrote a subpage DEAD did not hold");
            if (e.byOwner) require(e.nftOwner == e.caller, "mint log: PageNFT owner view");
            else require(e.nftMinter == e.caller, "mint log: PageNFT minter view");
        }
        for (uint256 i; i < subs.length; ++i) {
            uint256 s = subs[i];
            require(gMintCount[s] == g[s].epoch && nft.epochOf(s) == g[s].epoch, "subpage mints not all logged");
        }
    }

    function checkConfig() external view {
        for (uint256 i; i < 5; ++i) {
            uint256 P = parents[i];
            ConfigG storage c = gConfig[P];
            (
                address controller,
                bool enabled,
                bool commitReveal,
                address feeToken,
                uint96 price,
                address gateToken,
                uint96 minGate,
                address pay,
                uint64 pe
            ) = reg.config(P);
            require(
                controller == c.controller && enabled == c.enabled && commitReveal == c.commitReveal
                    && feeToken == c.feeToken && price == c.price && gateToken == c.gateToken && minGate == c.minGate
                    && pay == c.payout && pe == c.parentEpoch,
                "registrar config"
            );
        }
    }

    function mintLogLength() external view returns (uint256) {
        return mintLog.length;
    }

    function statCount() external view returns (uint256) {
        return statKeys.length;
    }

    function statLine() external view returns (string memory line) {
        for (uint256 i; i < statKeys.length; ++i) {
            line = string.concat(
                line, i == 0 ? "" : ",", statKeys[i], "=", vm.toString(statVal[keccak256(bytes(statKeys[i]))])
            );
        }
    }
}
