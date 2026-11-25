// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";

interface SVMBytes {
    function createBytes(uint256 length, string memory name) external pure returns (bytes memory value);
}

/// @notice src PageNFT with state writers and one probe that records the value it is called with.
/// The h_ functions exist only in this test harness.
contract PaidCallHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    bool public probed;
    uint256 public seenValue;

    function h_probe() external payable {
        probed = true;
        seenValue = msg.value;
    }

    function h_setRecord(uint256 id, string calldata label, uint64 exp, uint64 epoch) external {
        records[id] = PageRecord({label: label, parent: 0, expiresAt: exp, epoch: epoch, parentEpoch: 0});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 v) external {
        depositOf[id] = v;
    }

    function h_setHeld(uint256 id, address payer, uint96 amount) external {
        trialPaymentOf[id] = TrialPayment(payer, amount);
    }

    function h_setCommit(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }
}

/// @notice MC5 in four parts. MC5v: multicall is not payable, so a call of it with any nonzero value
/// reverts before any entry runs, and every entry of a bundle runs with msg.value 0. MC5p: reveal,
/// revealTrial and renew revert whenever msg.value is below their price, and only then with
/// InsufficientFee. MC5q: whenever a label is free, quote gives exactly that reveal price. MC5f: every
/// yearly fee and every trial price is above zero. A paid call inside a bundle therefore sees msg.value
/// 0, which is below its price, reverts, and takes the whole bundle with it, whatever the premium is.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract PaidCallProofsTest --function check_ --forge-build-out out-proofs --loop 6 --storage-layout generic
/// The loop bound 6 lets Halmos follow the label check over five symbolic bytes.
contract PaidCallProofsTest is Test {
    SVMBytes constant svm = SVMBytes(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

    PaidCallHarness n;
    address constant HOLDER = address(0xB0B);
    address constant OWNER = address(0xA11CE);
    address constant CALLER = address(0xCA11E2);
    address constant PAYER = address(0xFA7E5);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    function setUp() public {
        n = new PaidCallHarness(new PageCard());
    }

    /// @notice MC5v: multicall sent with any nonzero value by either of two callers, with no name
    /// registered, reverts with empty revert data and moves no ETH, whatever follows its selector (any
    /// bytes of length 0, 65 or 1024) and also for a well formed bundle whose entry would run, which
    /// then never runs. With no value that entry runs and sees msg.value 0.
    /// @dev Technique: symbolic value and symbolic calldata. Classification: DIRECT.
    function check_MC5v_valueRefusedFirst(uint256 v, bytes calldata tail, bool stranger) public {
        address caller = stranger ? CALLER : HOLDER;
        vm.assume(v != 0);
        vm.deal(caller, v);
        uint256 nb = address(n).balance;
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(n).call{value: v}(abi.encodePacked(PageNFT.multicall.selector, tail));
        assert(!ok);
        assert(ret.length == 0);
        assert(caller.balance == v && address(n).balance == nb);

        bytes[] memory d = new bytes[](1);
        d[0] = abi.encodeCall(PaidCallHarness.h_probe, ());
        vm.prank(caller);
        (ok, ret) = address(n).call{value: v}(abi.encodeCall(PageNFT.multicall, (d)));
        assert(!ok);
        assert(ret.length == 0);
        assert(!n.probed());
        assert(caller.balance == v && address(n).balance == nb);

        vm.prank(caller);
        (ok,) = address(n).call(abi.encodeCall(PageNFT.multicall, (d)));
        assert(ok);
        assert(n.probed() && n.seenValue() == 0);
    }

    // a label of one to five symbolic bytes, which covers every fee tier
    function _label(uint8 lenPick) internal pure returns (string memory) {
        uint8 k = lenPick % 5;
        if (k == 0) return string(svm.createBytes(1, "label1"));
        if (k == 1) return string(svm.createBytes(2, "label2"));
        if (k == 2) return string(svm.createBytes(3, "label3"));
        if (k == 3) return string(svm.createBytes(4, "label4"));
        return string(svm.createBytes(5, "label5"));
    }

    /// @notice MC5p: for every valid label of one to five bytes, any record of it (none, live, in grace,
    /// in the premium window or later, with a deposit, held trial money or neither), any time, value
    /// and referrer, and ripe commitments of both forms: reveal reverts whenever msg.value is below
    /// getFee(length) plus the deposit plus getPremium, revealTrial whenever it is below a tenth of
    /// getFee(length) plus the deposit plus getPremium, and renew whenever it is below getFee(length).
    /// The deposit counts until the end of the auction, after which it goes back to its payee first.
    /// With msg.value at or above that price none of them reverts with InsufficientFee, so these are
    /// exactly the prices. Every reveal price is at least the yearly fee.
    /// @dev Technique: symbolic state and value against the contract's own views. Classification: DIRECT.
    function check_MC5p_belowPriceReverts(
        uint8 kind, uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t,
        uint256 v, uint256 ref, bytes32 secret
    ) public {
        _mc5p(kind % 3, lenPick, exists, exp, epoch, dep, held, t, v, ref, secret);
    }

    /// @notice MC5p split by entry point so each part finishes: r reveal, t revealTrial, n renew.
    function check_MC5pr_reveal(
        uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t, uint256 v,
        uint256 ref, bytes32 secret
    ) public {
        _mc5p(0, lenPick, exists, exp, epoch, dep, held, t, v, ref, secret);
    }

    function check_MC5pt_revealTrial(
        uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t, uint256 v,
        uint256 ref, bytes32 secret
    ) public {
        _mc5p(1, lenPick, exists, exp, epoch, dep, held, t, v, ref, secret);
    }

    function check_MC5pn_renew(
        uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t, uint256 v,
        uint256 ref, bytes32 secret
    ) public {
        _mc5p(2, lenPick, exists, exp, epoch, dep, held, t, v, ref, secret);
    }

    function _mc5p(
        uint8 k, uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t,
        uint256 v, uint256 ref, bytes32 secret
    ) internal {
        vm.assume(t > 61 && t < 2 ** 64);
        vm.assume(dep == 0 || held == 0);
        string memory label = _label(lenPick);
        (bool okN, bytes memory r) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        vm.assume(okN);
        string memory norm = abi.decode(r, (string));
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(norm)))));
        if (exists) {
            n.h_setRecord(id, norm, exp, epoch);
            n.h_mint(HOLDER, id);
            n.h_setDeposit(id, dep);
            n.h_setHeld(id, PAYER, held);
        } else {
            vm.assume(dep == 0 && held == 0);
        }
        bytes32 c = keccak256(abi.encode(bytes(norm), OWNER, ref, secret));
        n.h_setCommit(c, t - 61);
        n.h_setCommit(keccak256(abi.encode(bytes(norm), OWNER, ref, secret, true)), t - 61);
        vm.warp(t);

        uint256 fee = n.getFee(bytes(norm).length);
        uint256 carried = exists && t > uint256(exp) + 111 days ? 0 : n.depositOf(id);
        uint256 price;
        bytes memory d;
        if (k == 0) {
            price = fee + carried + n.getPremium(id);
            assert(price >= fee);
            d = abi.encodeCall(PageNFT.reveal, (label, OWNER, ref, secret));
        } else if (k == 1) {
            price = fee / 10 + carried + n.getPremium(id);
            d = abi.encodeCall(PageNFT.revealTrial, (label, OWNER, ref, secret));
        } else {
            price = fee;
            d = abi.encodeCall(PageNFT.renew, (id));
        }
        vm.deal(CALLER, v);
        vm.prank(CALLER);
        (bool ok, bytes memory ret) = address(n).call{value: v}(d);
        if (v < price) assert(!ok);
        else if (!ok) assert(ret.length < 4 || bytes4(ret) != PageNFT.InsufficientFee.selector);
    }

    /// @notice MC5q: for every valid label of one to five bytes and any record of it, as in MC5p, quote returns
    /// getFee(length) and getPremium, a carried deposit that is the whole deposit during the auction and zero at any
    /// other time, and their sum as its total. So whenever the label is free, the total is the reveal price of MC5p,
    /// and a tenth of the fee plus the same carried deposit and premium is the revealTrial price of MC5p.
    /// @dev Technique: symbolic state against the contract's own views. Classification: DIRECT.
    function check_MC5q_quoteIsThePrice(
        uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint96 dep, uint96 held, uint256 t
    ) public {
        vm.assume(t > 61 && t < 2 ** 64);
        vm.assume(dep == 0 || held == 0);
        string memory label = _label(lenPick);
        (bool okN, bytes memory r) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        vm.assume(okN);
        string memory norm = abi.decode(r, (string));
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(norm)))));
        if (exists) {
            n.h_setRecord(id, norm, exp, epoch);
            n.h_mint(HOLDER, id);
            n.h_setDeposit(id, dep);
            n.h_setHeld(id, PAYER, held);
        } else {
            vm.assume(dep == 0 && held == 0);
        }
        vm.warp(t);

        uint256 fee = n.getFee(bytes(norm).length);
        uint256 premium = n.getPremium(id);
        (uint256 qFee, uint256 qCarried, uint256 qPremium, uint256 qTotal) = n.quote(label);
        assert(qFee == fee);
        assert(qPremium == premium);
        bool inAuction = exists && t > uint256(exp) + 90 days && t <= uint256(exp) + 111 days;
        assert(qCarried == (inAuction ? uint256(dep) : 0));
        assert(qTotal == qFee + qCarried + qPremium);
        if (n.isAvailable(label, 0)) {
            // the deposit term of the MC5p prices
            uint256 carried = exists && t > uint256(exp) + 111 days ? 0 : n.depositOf(id);
            assert(qTotal == fee + carried + premium);
            assert(qFee / 10 + qCarried + qPremium == fee / 10 + carried + premium);
        }
    }

    /// @notice MC5f: for every length, getFee is 0.01 ether for one or two bytes, 0.001 ether for three
    /// or four and 0.0001 ether otherwise, so every yearly fee is above zero, and every trial price, a
    /// tenth of the fee, is above zero too.
    /// @dev Technique: symbolic argument. Classification: DIRECT.
    function check_MC5f_pricesAboveZero(uint256 len) public view {
        uint256 fee = n.getFee(len);
        uint256 want = len == 1 || len == 2 ? 0.01 ether : len == 3 || len == 4 ? 0.001 ether : 0.0001 ether;
        assert(fee == want);
        assert(fee > 0);
        assert(fee / 10 > 0);
    }
}
