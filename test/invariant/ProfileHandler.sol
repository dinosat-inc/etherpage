// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";

contract HandlerVault {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// Random walks over two top level names and one subpage of each: paid registrations and takeovers,
// trials and conversions, every kind of move (wallet sends, operator sales with data, a vault that
// holds and gives back, DEAD), profile writes with values never used twice, keeps, clears, subpages
// taken back by the parent's holder, and bundles. The model follows the logs. Writes and keeps have their
// outcome and logs predicted from the state before them, and bundles their outcome. A value once discarded
// (overwritten, cleared, erased by a registration or left behind by a fresh start) must never be read again.
contract ProfileHandler is Test {
    PageNFT public nft;
    HandlerVault public vault;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant T_PWC = keccak256("ProfileWriterChanged(bytes32,address,bool)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    bytes32 constant T_SITE = keccak256("ContenthashChanged(bytes32,bytes)");
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    string[2] public labels = ["alpha", "bravo"];
    string[2] public keys = ["avatar", "url"];
    address[3] public actors;
    address public payer = makeAddr("payer");
    uint256[] public ids;

    // the model
    mapping(uint256 => address) public mWriter;
    mapping(uint256 => mapping(uint256 => string)) public mText;
    mapping(uint256 => bytes) public mSite;
    mapping(bytes32 => bool) public discarded;
    mapping(uint256 => address) public beforeVault;

    // failures found while walking; each must stay false
    bool public outcomeWrong;
    bool public logsWrong;
    bool public wrongOrderPassed;
    bool public lockout;

    // what the walk reached
    uint256 public writes;
    uint256 public freshStarts;
    uint256 public keeps;
    uint256 public clears;
    uint256 public moves;
    uint256 public vaultReturns;
    uint256 public takeBacks;
    uint256 public registrations;
    uint256 public bundlesOk;
    uint256 public shown;
    uint256 public hiddenNonEmpty;
    uint256 public lockoutChecks;
    uint256 vals;

    constructor(PageNFT n) {
        nft = n;
        vault = new HandlerVault();
        actors = [makeAddr("h0"), makeAddr("h1"), makeAddr("h2")];
        for (uint256 i; i < 3; ++i) vm.deal(actors[i], 1e9 ether);
        vm.deal(payer, 1e9 ether);
        for (uint256 i; i < 2; ++i) {
            ids.push(nft.computeId(labels[i]));
            ids.push(nft.computeId(string.concat("s.", labels[i])));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    // model
    function _owner(uint256 id) internal view returns (address o) {
        try nft.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    // whether a name is active, worked out from its record, its holder and the time rather than asked of the
    // contract; checkViews compares it with what resolve says
    function _active(uint256 id) internal view returns (bool) {
        address o = _owner(id);
        if (o == address(0) || o == DEAD) return false;
        (, uint256 parent, uint64 exp,, uint64 pe) = nft.records(id);
        if (parent == 0) return block.timestamp <= exp;
        (,, uint64 pexp, uint64 pep,) = nft.records(parent);
        return pe == pep && block.timestamp <= pexp;
    }

    function _discard(uint256 id) internal {
        for (uint256 k; k < 2; ++k) {
            if (bytes(mText[id][k]).length != 0) discarded[keccak256(bytes(mText[id][k]))] = true;
            delete mText[id][k];
        }
        if (mSite[id].length != 0) discarded[keccak256(mSite[id])] = true;
        delete mSite[id];
    }

    function _key(string memory k) internal view returns (uint256) {
        return keccak256(bytes(k)) == keccak256(bytes(keys[0])) ? 0 : 1;
    }

    function _apply(Vm.Log[] memory l) internal {
        for (uint256 i; i < l.length; ++i) {
            if (l[i].emitter != address(nft) || l[i].topics.length < 2) continue;
            bytes32 t = l[i].topics[0];
            uint256 id = uint256(l[i].topics[1]);
            if (t == T_PWC) {
                (address w, bool fresh) = abi.decode(l[i].data, (address, bool));
                if (fresh) {
                    _discard(id);
                    ++freshStarts;
                }
                mWriter[id] = w;
            } else if (t == T_VERSION) {
                _discard(id);
            } else if (t == T_TEXT) {
                (string memory k, string memory v) = abi.decode(l[i].data, (string, string));
                uint256 ki = _key(k);
                if (bytes(mText[id][ki]).length != 0) discarded[keccak256(bytes(mText[id][ki]))] = true;
                mText[id][ki] = v;
            } else if (t == T_SITE) {
                if (mSite[id].length != 0) discarded[keccak256(mSite[id])] = true;
                mSite[id] = abi.decode(l[i].data, (bytes));
            }
        }
    }

    function _run(address from, uint256 value, bytes memory data) internal returns (bool ok, Vm.Log[] memory l) {
        vm.recordLogs();
        vm.prank(from);
        (ok,) = address(nft).call{value: value}(data);
        l = vm.getRecordedLogs();
        // the recording keeps the logs of a reverted call, which no indexer ever sees
        if (ok) _apply(l);
    }

    function _val() internal returns (string memory) {
        return string.concat("v", vm.toString(++vals));
    }

    // the views against the model, for every name
    function checkViews() public {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            address o = _owner(id);
            assertEq(nft.resolve(id) != address(0), _active(id), "active");
            bool counts = _active(id) && o != address(0) && mWriter[id] == o;
            assertEq(nft.profileWriter(id), mWriter[id], "writer");
            for (uint256 k; k < 2; ++k) {
                string memory v = nft.text(id, keys[k]);
                assertEq(v, counts ? mText[id][k] : "", "text equals the model");
                if (bytes(v).length != 0) {
                    assertFalse(discarded[keccak256(bytes(v))], "a discarded value came back");
                    assertEq(nft.profileWriter(id), o, "shown only for its writer");
                    ++shown;
                } else if (bytes(mText[id][k]).length != 0) {
                    ++hiddenNonEmpty;
                }
            }
            bytes memory s = nft.contenthash(id);
            assertEq(s, counts ? mSite[id] : bytes(""), "website equals the model");
            if (s.length != 0) assertFalse(discarded[keccak256(s)], "a discarded website came back");
        }
    }

    // the holder of an active name can always make a profile count, by keeping or writing
    function _noLockout(uint256 id) internal {
        address o = _owner(id);
        if (o == address(0) || !_active(id) || o == DEAD) return;
        uint256 snap = vm.snapshotState();
        bool ok;
        bool bad;
        if (mWriter[id] != o) {
            vm.prank(o);
            (ok,) = address(nft).call(abi.encodeCall(PageNFT.keepProfile, (id)));
            bad = !ok || keccak256(bytes(nft.text(id, keys[0]))) != keccak256(bytes(mText[id][0]));
        } else {
            vm.prank(o);
            (ok,) = address(nft).call(abi.encodeWithSignature("setText(uint256,string,string)", id, "avatar", "probe"));
            bad = !ok || keccak256(bytes(nft.text(id, "avatar"))) != keccak256("probe");
        }
        // the probe is undone, and only its result is kept
        vm.revertToState(snap);
        if (bad) lockout = true;
        ++lockoutChecks;
    }

    modifier checked(uint256 r) {
        _;
        checkViews();
        _noLockout(ids[r % ids.length]);
    }

    // actions
    function buy(uint256 li, uint256 ai, bool retake) external checked(li) {
        string memory l = labels[li % 2];
        uint256 id = nft.computeId(l);
        if (retake) {
            uint256 e = nft.expiresAt(id);
            if (e != 0) {
                uint256 t = nft.depositOf(id) == 0 ? e + 1 : e + 111 days + 1;
                if (t > block.timestamp) vm.warp(t);
            }
        }
        address to = actors[ai % 3];
        bytes32 s = keccak256(abi.encode(li, ai, block.timestamp));
        bytes32 commitment = nft.makeCommitment(l, to, 0, s);
        vm.prank(to);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(l);
        (bool ok,) = _run(to, total, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", l, to, 0, s));
        if (ok) ++registrations;
    }

    function trial(uint256 li, uint256 ai) external checked(li) {
        string memory l = labels[li % 2];
        address to = actors[ai % 3];
        bytes32 s = keccak256(abi.encode("t", li, ai, block.timestamp));
        bytes32 commitment = trialCommitment(address(nft), l, to, 0, s);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        uint256 price = nft.getFee(bytes(l).length) / 10;
        (bool ok,) = _run(payer, price, abi.encodeWithSignature("revealTrial(string,address,uint256,bytes32)", l, to, 0, s));
        if (ok) ++registrations;
    }

    function renew(uint256 li) external checked(li) {
        uint256 id = nft.computeId(labels[li % 2]);
        _run(payer, nft.getFee(5), abi.encodeWithSignature("renew(uint256)", id));
    }

    function move(uint256 ii, uint256 ti, uint256 kind) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        address from = _owner(id);
        if (from == address(0) || from == DEAD || from == address(vault)) return;
        address to = kind % 7 == 0 ? DEAD : kind % 5 == 0 ? address(vault) : actors[ti % 3];
        uint256 k = kind % 3;
        bool ok;
        if (k == 0) {
            (ok,) = _run(from, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id));
        } else if (k == 1) {
            (ok,) = _run(from, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id));
        } else {
            address op = makeAddr("conduit");
            vm.prank(from);
            nft.setApprovalForAll(op, true);
            (ok,) = _run(op, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"5ea9"));
        }
        if (ok) {
            ++moves;
            if (to == address(vault)) beforeVault[id] = from;
        }
    }

    function vaultBack(uint256 ii, uint256 ti) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        if (_owner(id) != address(vault)) return;
        address to = ti % 3 == 0 ? actors[ti % 3] : beforeVault[id];
        (bool ok,) = _run(address(vault), 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(vault), to, id));
        if (ok) ++vaultReturns;
    }

    function write(uint256 ii, uint256 ai, uint256 k) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        address o = _owner(id);
        address who = ai % 5 == 0 ? actors[ai % 3] : ai % 11 == 0 ? address(vault) : o;
        if (who == address(0) || who == DEAD) who = actors[ai % 3];
        bool want = _active(id) && o == who;
        bool fresh = mWriter[id] != who;
        string memory v = _val();
        bytes memory data = k % 3 == 2
            ? abi.encodeWithSignature("setContenthash(uint256,bytes)", id, bytes(v))
            : abi.encodeWithSignature("setText(uint256,string,string)", id, keys[k % 3], v);
        (bool ok, Vm.Log[] memory l) = _run(who, 0, data);
        if (ok != want) outcomeWrong = true;
        if (!ok) return;
        ++writes;
        uint256 n = fresh ? 2 : 1;
        if (l.length != n) logsWrong = true;
        else if (fresh && keccak256(l[0].data) != keccak256(abi.encode(who, true))) logsWrong = true;
        if (nft.profileWriter(id) != who) outcomeWrong = true;
    }

    // the profile actions again, so the walk reaches them more often
    function write2(uint256 ii, uint256 ai, uint256 k) external {
        this.write(ii, ai, k);
    }

    function write3(uint256 ii, uint256 ai, uint256 k) external {
        this.write(ii, ai, k);
    }

    function keep2(uint256 ii, uint256 ai) external {
        this.keep(ii, ai);
    }

    function keep(uint256 ii, uint256 ai) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        address o = _owner(id);
        address who = ai % 4 == 0 ? actors[ai % 3] : ai % 9 == 0 ? address(vault) : o;
        if (who == address(0) || who == DEAD) who = actors[ai % 3];
        bool want = _active(id) && o == who && mWriter[id] != who;
        string memory before0 = mText[id][0];
        (bool ok, Vm.Log[] memory l) = _run(who, 0, abi.encodeCall(PageNFT.keepProfile, (id)));
        if (ok != want) outcomeWrong = true;
        if (!ok) return;
        ++keeps;
        if (l.length != 1 || keccak256(l[0].data) != keccak256(abi.encode(who, false))) logsWrong = true;
        if (keccak256(bytes(nft.text(id, keys[0]))) != keccak256(bytes(before0))) outcomeWrong = true;
    }

    function clear(uint256 ii, uint256 ai) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        address o = _owner(id);
        address who = ai % 5 == 0 ? actors[ai % 3] : o;
        if (who == address(0) || who == DEAD) return;
        (bool ok,) = _run(who, 0, abi.encodeWithSignature("clearRecords(uint256)", id));
        if (ok) ++clears;
    }

    // the parent's holder mints the subpage to someone, or takes it back by minting over it
    function sub(uint256 li, uint256 ti) external checked(li) {
        uint256 p = nft.computeId(labels[li % 2]);
        address o = _owner(p);
        if (o == address(0) || o == DEAD || o == address(vault)) return;
        address to = ti % 4 == 0 ? o : actors[ti % 3];
        uint256 sid = nft.computeId(string.concat("s.", labels[li % 2]));
        bool existed = _owner(sid) != address(0);
        (bool ok,) = _run(o, 0, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "s", p, to));
        if (ok && existed) ++takeBacks;
    }

    // keep then write succeeds as the keep would; write then keep never succeeds
    function bundle(uint256 ii, uint256 k, bool keepFirst) external checked(ii) {
        uint256 id = ids[ii % ids.length];
        address o = _owner(id);
        if (o == address(0) || o == DEAD) return;
        bytes[] memory c = new bytes[](2);
        bytes memory w = abi.encodeWithSignature("setText(uint256,string,string)", id, keys[k % 2], _val());
        bytes memory kp = abi.encodeCall(PageNFT.keepProfile, (id));
        c[0] = keepFirst ? kp : w;
        c[1] = keepFirst ? w : kp;
        bool keepOk = _active(id) && mWriter[id] != o;
        (bool ok,) = _run(o, 0, abi.encodeCall(PageNFT.multicall, (c)));
        if (!keepFirst && ok) wrongOrderPassed = true;
        if (keepFirst && ok != keepOk) outcomeWrong = true;
        if (ok) ++bundlesOk;
    }

    function warp(uint256 r) external checked(r) {
        uint256 k = r % 4;
        if (k == 0) vm.warp(block.timestamp + bound(r >> 8, 1, 130 days));
        else if (k == 1) {
            uint256 e = nft.expiresAt(ids[(r >> 8) % 2 * 2]);
            uint256 t = (r >> 16) % 2 == 0 ? e + 1 : e + 90 days + 1;
            if (t > block.timestamp) vm.warp(t);
        } else vm.warp(block.timestamp + bound(r >> 8, 1, 8 days));
    }
}
