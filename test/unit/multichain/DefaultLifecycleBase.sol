// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// a contract holder that accepts names and, when asked, saves its own default from inside onERC721Received
contract LifecycleHolder {
    address immutable nftAddr;
    bool public saveOnReceive;
    bytes public defaultOnReceive;

    constructor(address n) {
        nftAddr = n;
    }

    function setSaveOnReceive(bool on, bytes calldata v) external {
        saveOnReceive = on;
        defaultOnReceive = v;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (saveOnReceive && msg.sender == nftAddr) {
            PageNFT(nftAddr).setAddrForCoin(id, 0x80000000, defaultOnReceive);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// code put at an account to stand in for code it adopted later
contract LifecycleCode {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// Shared setup for DefaultLifecycleTest. It deploys the three contracts, keeps an independent model of every address
// record by record version, and checks after every call that every answer is the model's, that the last
// announcement of the Ethereum and OP answers is the answer, that every change of the Ethereum, OP and addr by node
// answers is announced, and that AddrChanged comes right after the Ethereum answer, with the same address.
abstract contract DefaultLifecycleBase is Test {
    PageCard card;
    PageNFT nft;
    SubpageRegistrar reg;

    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant LOWEST = 0x80000001;
    uint256 constant LAST = 0xffffffff;
    uint256 constant BTC = 0;
    uint256 constant ETC = 61;
    uint256 constant BELOW = 0x7fffffff;
    uint256 constant ABOVE = 0x100000000;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");

    uint256[11] coins = [ETH, OP, DEF, BASE, ARB, LOWEST, LAST, BTC, ETC, BELOW, ABOVE];

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address relayer = makeAddr("relayer");
    address cold = makeAddr("cold");
    address other = makeAddr("other");
    address seven = makeAddr("seven");

    // the model: per id and record version, the saver and value of the main address and of every coin type
    struct Entry {
        address saver;
        bytes value;
        bool set;
    }

    mapping(uint256 => uint256) mVersion;
    mapping(uint256 => mapping(uint256 => Entry)) mMain;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => Entry))) mEntry;
    uint256[] tracked;
    mapping(uint256 => bool) isTracked;
    uint256 nonce;

    // answers that changed with no event, per coin type index, and the number of model checks run
    uint256[11] silent;
    uint256 checks;
    // set around a call whose answer changes are known to go unannounced, such as a renewal in grace
    bool lenient;
    uint256 silentStrict;
    // calls whose last announcement of a coin type other than 60 and OP is not its answer at the end of the call
    uint256[11] staleInCall;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.etch(seven, abi.encodePacked(hex"ef0100", address(new LifecycleCode())));
        vm.deal(relayer, 1_000_000 ether);
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function _isEvm(uint256 c) internal pure returns (bool) {
        return c == 60 || (c >= 0x80000000 && c <= 0xffffffff);
    }

    function _track(uint256 id) internal {
        if (!isTracked[id]) {
            isTracked[id] = true;
            tracked.push(id);
        }
    }

    function _exists(uint256 id) internal view returns (bool) {
        (string memory label,,,,) = nft.records(id);
        return bytes(label).length != 0;
    }

    // activeness from the public record views; a page the dead address holds is never active
    function _active(uint256 id) internal view returns (bool) {
        (string memory label, uint256 parent,,, uint64 parentEpoch) = nft.records(id);
        if (bytes(label).length == 0) return false;
        if (nft.ownerOf(id) == DEAD) return false;
        if (parent == 0) return block.timestamp <= nft.expiresAt(id);
        if (parentEpoch != nft.epochOf(parent)) return false;
        return block.timestamp <= nft.expiresAt(parent);
    }

    function _modelMain(uint256 id, address owner) internal view returns (address) {
        Entry storage m = mMain[id][mVersion[id]];
        if (m.set && m.saver == owner && m.value.length == 20 && address(bytes20(m.value)) != address(0)) {
            return address(bytes20(m.value));
        }
        return owner;
    }

    // the rule: inactive is empty; the home chain is the main address; any other EVM chain answers the holder's own
    // entry, else the holder's default, else nothing, whatever the code at any address; anything else only its own
    // entry
    function _expect(uint256 id, uint256 coin) internal view returns (bytes memory) {
        if (!_active(id)) return "";
        address owner = nft.ownerOf(id);
        address main = _modelMain(id, owner);
        if (coin == OP) return _enc(main);
        uint256 v = mVersion[id];
        Entry storage e = mEntry[id][v][coin];
        if (_isEvm(coin)) {
            address a;
            if (e.set && e.saver == owner && e.value.length == 20) a = address(bytes20(e.value));
            if (a == address(0)) {
                Entry storage d = mEntry[id][v][DEF];
                if (d.set && d.saver == owner && d.value.length == 20) a = address(bytes20(d.value));
            }
            return _enc(a);
        }
        return (e.set && e.saver == owner) ? e.value : bytes("");
    }

    function _expectResolve(uint256 id) internal view returns (address) {
        if (!_active(id)) return address(0);
        return _modelMain(id, nft.ownerOf(id));
    }

    // every answer of every tracked id against the model, and the record version against the model's count
    function _checkModel() internal {
        for (uint256 i; i < tracked.length; ++i) {
            uint256 id = tracked[i];
            assertEq(nft.recordVersion(id), mVersion[id], "record version against the model");
            for (uint256 k; k < coins.length; ++k) {
                assertEq(
                    nft.addr(id, coins[k]),
                    _expect(id, coins[k]),
                    string.concat("answer of coin ", vm.toString(coins[k]))
                );
            }
            assertEq(nft.resolve(id), _expectResolve(id), "main address against the model");
            assertEq(_enc(nft.addr(bytes32(id))), _expect(id, ETH), "addr by node is the coin type 60 answer");
            ++checks;
        }
    }

    function _snap() internal view returns (bytes[][] memory s) {
        s = new bytes[][](tracked.length);
        for (uint256 i; i < tracked.length; ++i) {
            s[i] = new bytes[](coins.length + 1);
            for (uint256 k; k < coins.length; ++k) {
                s[i][k] = nft.addr(tracked[i], coins[k]);
            }
            s[i][coins.length] = abi.encodePacked(nft.addr(bytes32(tracked[i])));
        }
    }

    function _coinIndex(uint256 c) internal view returns (uint256) {
        for (uint256 k; k < coins.length; ++k) {
            if (coins[k] == c) return k;
        }
        return type(uint256).max;
    }

    // the last announcement of the Ethereum and OP answers and of addr by node is the answer, every change of them is
    // announced, AddrChanged comes right after the Ethereum answer with the same address and the Ethereum answer never
    // comes without it, and no coin type outside the tracked ones is announced; a stale last announcement or an
    // unannounced change of any other coin type is counted, not refused
    function _checkLogs(bytes[][] memory before, Vm.Log[] memory logs) internal {
        for (uint256 i; i < tracked.length; ++i) {
            uint256 id = tracked[i];
            bool[] memory seen = new bool[](coins.length);
            bytes[] memory last = new bytes[](coins.length);
            bool seenAddr;
            address lastAddr;
            // the Ethereum answer just announced for this id that still waits for its AddrChanged
            bool pending;
            bytes memory pendingEth;
            for (uint256 j; j < logs.length; ++j) {
                Vm.Log memory l = logs[j];
                if (l.emitter != address(nft) || l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
                if (l.topics[0] == T_ADDRESS) {
                    assertFalse(pending, "AddrChanged right after the Ethereum answer");
                    (uint256 c, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                    uint256 k = _coinIndex(c);
                    assertTrue(k != type(uint256).max, "an announcement of an untracked coin type");
                    seen[k] = true;
                    last[k] = v;
                    if (c == ETH) (pending, pendingEth) = (true, v);
                } else if (l.topics[0] == T_ADDR) {
                    assertTrue(pending, "AddrChanged only right after the Ethereum answer");
                    seenAddr = true;
                    lastAddr = abi.decode(l.data, (address));
                    assertEq(_enc(lastAddr), pendingEth, "AddrChanged carries the Ethereum answer just announced");
                    pending = false;
                } else {
                    assertFalse(pending, "AddrChanged right after the Ethereum answer");
                }
            }
            assertFalse(pending, "AddrChanged right after the Ethereum answer");
            for (uint256 k; k < coins.length; ++k) {
                bytes memory nowA = nft.addr(id, coins[k]);
                if (seen[k] && keccak256(last[k]) != keccak256(nowA)) {
                    if (coins[k] == ETH || coins[k] == OP) {
                        assertEq(last[k], nowA, string.concat("last announcement of coin ", vm.toString(coins[k])));
                    }
                    ++staleInCall[k];
                }
                bool changed = keccak256(nowA) != keccak256(before[i][k]);
                if (changed && !seen[k]) {
                    ++silent[k];
                    if (coins[k] == ETH || coins[k] == OP) {
                        if (lenient) ++silentStrict;
                        else assertTrue(false, string.concat("unannounced change of coin ", vm.toString(coins[k])));
                    }
                }
            }
            address r = nft.addr(bytes32(id));
            if (seenAddr) assertEq(lastAddr, r, "AddrChanged is the coin type 60 answer");
            if (r != address(bytes20(before[i][coins.length])) && !seenAddr) {
                if (lenient) ++silentStrict;
                else assertTrue(false, "unannounced change of addr by node");
            }
        }
    }

    // one call with its checks; the model is updated by the caller of this function on success
    function _call(address caller, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        bytes[][] memory before = _snap();
        vm.deal(caller, caller.balance + value);
        vm.recordLogs();
        vm.prank(caller);
        (ok, ret) = address(nft).call{value: value}(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) _checkLogs(before, logs);
    }

    function _must(address caller, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = _call(caller, 0, data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // model updates for each kind of successful call
    function _mSave(uint256 id, address saver, uint256 coin, bytes memory v) internal {
        if (coin == OP) {
            _mSetMain(id, saver, v.length == 0 ? address(0) : address(bytes20(v)));
            return;
        }
        bool evm = _isEvm(coin);
        mEntry[id][mVersion[id]][coin] = Entry(saver, evm && bytes20(v) == 0 ? bytes("") : v, true);
    }

    function _mSetMain(uint256 id, address saver, address a) internal {
        mMain[id][mVersion[id]] = Entry(saver, abi.encodePacked(a), true);
    }

    function _mBump(uint256 id) internal {
        ++mVersion[id];
    }

    // checked actions
    function _save(address who, uint256 id, uint256 coin, bytes memory v) internal {
        _must(who, abi.encodeCall(PageNFT.setAddrForCoin, (id, coin, v)));
        _mSave(id, who, coin, v);
        _checkModel();
    }

    function _setMain(address who, uint256 id, address a) internal {
        _must(who, abi.encodeCall(PageNFT.setAddr, (id, a)));
        _mSetMain(id, who, a);
        _checkModel();
    }

    function _clear(address who, uint256 id) internal {
        _must(who, abi.encodeCall(PageNFT.clearRecords, (id)));
        _mBump(id);
        _checkModel();
    }

    function _move(address by, address from, address to, uint256 id, uint256 how) internal {
        bytes memory data;
        if (how == 0) {
            data = abi.encodeCall(PageNFT.transferFrom, (from, to, id));
        } else if (how == 1) {
            data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
        } else {
            data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"beef");
        }
        _must(by, data);
        assertEq(nft.ownerOf(id), to, "moved");
        _checkModel();
    }

    function _reveal(address payer, string memory label, address owner) internal returns (uint256 id) {
        id = nft.computeId(label);
        _track(id);
        bool existed = _exists(id);
        bytes32 secret = keccak256(abi.encode(label, owner, vm.getBlockTimestamp(), ++nonce));
        bytes32 c = nft.makeCommitment(label, owner, 0, secret);
        _must(payer, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        (bool ok, bytes memory ret) = _call(payer, total, abi.encodeCall(PageNFT.reveal, (label, owner, 0, secret)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assertEq(abi.decode(ret, (uint256)), id);
        if (existed) _mBump(id);
        _checkModel();
    }

    function _trial(string memory label, address owner) internal returns (uint256 id) {
        id = nft.computeId(label);
        _track(id);
        bool existed = _exists(id);
        bytes32 secret = keccak256(abi.encode("trial", label, owner, vm.getBlockTimestamp(), ++nonce));
        bytes32 c = trialCommitment(address(nft), label, owner, 0, secret);
        _must(relayer, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        (bool ok, bytes memory ret) =
            _call(relayer, price, abi.encodeCall(PageNFT.revealTrial, (label, owner, 0, secret)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        if (existed) _mBump(id);
        _checkModel();
    }

    function _subId(uint256 parent, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256(bytes(label)))));
    }

    function _sub(address by, string memory label, uint256 parent, address to) internal returns (uint256 id) {
        id = _subId(parent, label);
        _track(id);
        bool existed = _exists(id);
        bytes memory ret = _must(by, abi.encodeCall(PageNFT.registerSubpageFor, (label, parent, to)));
        assertEq(abi.decode(ret, (uint256)), id);
        if (existed) _mBump(id);
        _checkModel();
    }

    // a renewal in grace brings the answers back with no event, so its changes are counted instead of refused
    function _renew(address payer, uint256 id) internal returns (bool ok) {
        (string memory label,,,,) = nft.records(id);
        uint256 fee = nft.getFee(bytes(label).length);
        lenient = true;
        (ok,) = _call(payer, fee, abi.encodeCall(PageNFT.renew, (id)));
        lenient = false;
        _checkModel();
    }

    function _resetTracked() internal {
        for (uint256 i; i < tracked.length; ++i) {
            isTracked[tracked[i]] = false;
        }
        delete tracked;
    }

    // the address announcements for one id in one recorded call, as (coin type or 1 for AddrChanged, value)
    function _addrEvents(Vm.Log[] memory logs, uint256 id)
        internal
        view
        returns (uint256[] memory kinds, bytes[] memory values)
    {
        kinds = new uint256[](logs.length);
        values = new bytes[](logs.length);
        uint256 n;
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory l = logs[j];
            if (l.emitter != address(nft) || l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
            if (l.topics[0] == T_ADDRESS) {
                (kinds[n], values[n]) = abi.decode(l.data, (uint256, bytes));
                ++n;
            } else if (l.topics[0] == T_ADDR) {
                kinds[n] = 1;
                values[n] = _enc(abi.decode(l.data, (address)));
                ++n;
            } else if (l.topics[0] == T_VERSION) {
                kinds[n] = 2;
                values[n] = l.data;
                ++n;
            }
        }
        assembly ("memory-safe") {
            mstore(kinds, n)
            mstore(values, n)
        }
    }

    // records one call and returns its address announcements for id
    function _record(address caller, bytes memory data, uint256 id)
        internal
        returns (uint256[] memory kinds, bytes[] memory values)
    {
        bytes[][] memory before = _snap();
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(nft).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkLogs(before, logs);
        (kinds, values) = _addrEvents(logs, id);
    }

    function _assertEvents(uint256[] memory kinds, bytes[] memory values, uint256[] memory wantK, bytes[] memory wantV)
        internal
        pure
    {
        assertEq(kinds.length, wantK.length, "number of address announcements");
        for (uint256 i; i < kinds.length; ++i) {
            assertEq(kinds[i], wantK[i], string.concat("announcement kind ", vm.toString(i)));
            assertEq(values[i], wantV[i], string.concat("announcement value ", vm.toString(i)));
        }
    }

    // the OP answer, the Ethereum answer and AddrChanged with it, in the order a mint, transfer, burn or setAddr gives
    // them
    function _trio(address main, address eth) internal pure returns (uint256[] memory k, bytes[] memory v) {
        k = new uint256[](3);
        v = new bytes[](3);
        (k[0], v[0]) = (OP, _enc(main));
        (k[1], v[1]) = (ETH, _enc(eth));
        (k[2], v[2]) = (1, _enc(eth));
    }

    function _cat(uint256[] memory a, bytes[] memory av, uint256[] memory b, bytes[] memory bv)
        internal
        pure
        returns (uint256[] memory k, bytes[] memory v)
    {
        k = new uint256[](a.length + b.length);
        v = new bytes[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            (k[i], v[i]) = (a[i], av[i]);
        }
        for (uint256 i; i < b.length; ++i) {
            (k[a.length + i], v[a.length + i]) = (b[i], bv[i]);
        }
    }

    function _one(uint256 kind, bytes memory value) internal pure returns (uint256[] memory k, bytes[] memory v) {
        k = new uint256[](1);
        v = new bytes[](1);
        (k[0], v[0]) = (kind, value);
    }

    // every EVM chain but the home chain with no entry of its own (no BASE entry is saved where this is used)
    function _evmAll(uint256 id, address want, string memory why) internal view {
        bytes memory w = _enc(want);
        assertEq(nft.addr(id, ETH), w, string.concat(why, ": Ethereum"));
        assertEq(nft.addr(id, DEF), w, string.concat(why, ": the default"));
        assertEq(nft.addr(id, ARB), w, string.concat(why, ": Arbitrum"));
        assertEq(nft.addr(id, LOWEST), w, string.concat(why, ": 0x80000001"));
        assertEq(nft.addr(id, LAST), w, string.concat(why, ": 0xffffffff"));
    }
}
