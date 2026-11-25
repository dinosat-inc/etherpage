// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";

/// @notice State writers for the trial interplay proofs. They exist only in this test harness.
contract TrialInterplayHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_setRecord(uint256 id, string calldata label, uint64 exp, uint64 epoch) external {
        records[id] = PageRecord({label: label, parent: 0, expiresAt: exp, epoch: epoch, parentEpoch: 0});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 amount) external payable {
        depositOf[id] = amount;
    }

    function h_setCommitment(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }

    function h_setHeld(uint256 id, address payer, uint96 amount) external {
        trialPaymentOf[id] = TrialPayment(payer, amount);
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setPrimary(address a, uint256 id, address holder) external {
        primaryPage[a] = id;
        _primaryHolder[a] = holder;
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }
}

/// @notice Symbolic proofs of the sponsored trial next to multicall and the holder stored with a
/// display name.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract TrialInterplayProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract TrialInterplayProofsTest is Test {
    TrialInterplayHarness n;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant PTE = address(0x407);
    address constant OTHER = address(0xC0FFEE);
    uint256 constant FEE = 0.0001 ether;
    uint256 constant PRICE = 0.00001 ether;
    address constant PAYER = address(0xFA7E5);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 id;

    function setUp() public {
        n = new TrialInterplayHarness(new PageCard());
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        if (k == 0) return OTHER;
        if (k == 1) return HOLDER;
        if (k == 2) return PTE;
        return DEAD;
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }

    // MT1: revealTrial inside a bundle never succeeds, with no record or one held by HOLDER, for any
    // expiry, epoch, deposit and time, a caller and a commitment owner each among OTHER, HOLDER, PTE
    // and DEAD, and commitments of both forms, ripe or not; the commitments, the holder, the held
    // money, the credits and the balance stay
    function check_MT1_trialNeverRunsInABundle(
        bool exists, uint64 exp, uint64 epoch, uint96 dep, uint64 t, uint64 committedAt, uint8 cPick, uint8 oPick
    ) public {
        address caller = _pick(cPick);
        address owner = _pick(oPick);
        if (exists) {
            vm.assume(epoch > 0 && epoch < type(uint64).max);
            n.h_setRecord(id, "alpha", exp, epoch);
            n.h_mint(HOLDER, id);
            n.h_setDeposit(id, dep);
            // here a top level record with no deposit is set up as a trial that holds its price
            if (dep == 0) {
                n.h_setHeld(id, PAYER, uint96(PRICE));
                vm.deal(address(n), PRICE);
            }
        }
        bytes32 c = n.makeCommitment("alpha", owner, 0, bytes32("s"));
        n.h_setCommitment(c, committedAt);
        n.h_setCommitment(keccak256(abi.encode(bytes("alpha"), owner, uint256(0), bytes32("s"), true)), committedAt);
        vm.warp(t);
        uint256 bal = address(n).balance;
        vm.prank(caller);
        (bool ok,) = address(n).call(
            abi.encodeCall(PageNFT.multicall, (_one(abi.encodeCall(PageNFT.revealTrial, ("alpha", owner, 0, bytes32("s"))))))
        );
        assert(!ok);
        assert(n.commitments(c) == committedAt && n.commitments(keccak256(abi.encode(bytes("alpha"), owner, uint256(0), bytes32("s"), true))) == committedAt);
        assert(n.h_ownerOf(id) == (exists ? HOLDER : address(0)));
        assert(n.owed(DEAD) == 0 && n.owed(PAYER) == 0);
        (, uint96 held) = n.trialPaymentOf(id);
        assert(held == (exists && dep == 0 ? PRICE : 0));
        assert(address(n).balance == bal);
    }

    // MT2: a trial held by HOLDER points at PTE, which chose it. After the trial lapses, one new
    // registration (a trial after the pause or a paid reveal, to any of four accounts), then a setAddr
    // to PTE, a setText, both or neither by the new holder, cannot make PTE show the name, unless the
    // new holder is HOLDER itself and it points the name at PTE again. A renew after the lapse fails
    // and changes nothing.
    function check_MT2_lapsedTrialCannotRevive(
        uint64 exp, uint64 epoch, uint64 t, uint8 toPick, uint8 how, bool point, bool withText, uint256 value
    ) public {
        vm.assume(epoch > 0 && epoch < type(uint64).max);
        vm.assume(t > exp && uint256(t) > 1000 && value <= 10 ether);
        n.h_setRecord(id, "alpha", exp, epoch);
        n.h_mint(HOLDER, id);
        n.h_setHeld(id, PAYER, uint96(PRICE));
        vm.deal(address(n), PRICE);
        n.h_setResolved(id, PTE, HOLDER);
        n.h_setPrimary(PTE, id, HOLDER);
        n.h_setPrimary(HOLDER, id, HOLDER);
        address to = _pick(toPick);
        vm.warp(t);
        assert(bytes(n.reverseResolve(PTE)).length == 0);
        uint8 k = how % 3;
        bool ok;
        vm.deal(OTHER, value);
        if (k == 2) {
            vm.prank(OTHER);
            (ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
            assert(!ok);
        } else {
            bytes32 c = n.makeCommitment("alpha", to, 0, bytes32("s"));
            n.h_setCommitment(k == 0 ? keccak256(abi.encode(bytes("alpha"), to, uint256(0), bytes32("s"), true)) : c, uint256(t) - 61);
            bytes memory d = k == 0
                ? abi.encodeCall(PageNFT.revealTrial, ("alpha", to, 0, bytes32("s")))
                : abi.encodeCall(PageNFT.reveal, ("alpha", to, 0, bytes32("s")));
            vm.prank(OTHER);
            (ok,) = address(n).call{value: value}(d);
            assert(ok == (value >= (k == 0 ? PRICE : FEE) && (k != 0 || uint256(t) > uint256(exp) + 14 days)));
            if (ok) assert(n.owed(PAYER) == PRICE);
        }
        if (ok) {
            assert(n.primaryPage(HOLDER) == 0);
            if (point && to != DEAD) {
                vm.prank(to);
                n.setAddr(id, PTE);
            }
            if (withText && to != DEAD) {
                vm.prank(to);
                n.setText(id, "url", "x");
            }
        }
        bool shown = bytes(n.reverseResolve(PTE)).length != 0;
        assert(!shown || (ok && to == HOLDER && point));
        assert(bytes(n.reverseResolve(HOLDER)).length == 0);
    }
}
