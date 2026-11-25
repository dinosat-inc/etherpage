// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTHarness} from "../MinterHarness.sol";

interface SVMW {
    function enableSymbolicStorage(address) external;
    function createBool(string memory name) external pure returns (bool value);
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256 value);
    function createAddress(string memory name) external pure returns (address value);
    function createBytes32(string memory name) external pure returns (bytes32 value);
}

/// @notice A plain ERC20 fee token: transferFrom needs the balance and the allowance and returns true.
contract MockFeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setBal(address a, uint256 b) external {
        balanceOf[a] = b;
    }

    function setAllowance(address a, address spender, uint256 v) external {
        allowance[a][spender] = v;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        require(al >= amt && balanceOf[from] >= amt);
        allowance[from][msg.sender] = al - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice A gate token that answers balanceOf with a stored amount.
contract MockGate {
    mapping(address => uint256) public balanceOf;

    function setBal(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

/// @notice Widened proofs of SubpageRegistrar. The tier proof MP8 covers only an ETH sale through
/// registerSubpageFor with no gate, the buyer's guards always passing (maxPrice 2^256-1, fee token 0),
/// and only one direction (a sale that succeeds was allowed). These add:
/// WSR1 both sale entry points (revealSubpageFor with a symbolic secret and commitment time), a
/// symbolic maxPrice and expected fee token, an ERC20 fee token or ETH, a gate token or none, a
/// symbolic value, and the rule both ways, with the exact money effects (proceeds, refund to the
/// buyer, token balances) and the commitment use;
/// WSR2 claimProceeds and claimProceedsFor by any caller, for any account and recipient;
/// WSR3 configure and WSR4 disable by any caller, with any arguments.
/// Registrar storage is symbolic (any prior config, proceeds and commitments).
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideRegistrarProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideRegistrarProofsTest is Test {
    SVMW constant svm = SVMW(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

    PageNFTHarness nft;
    SubpageRegistrar reg;
    MockFeeToken token;
    MockGate gate;

    address constant TO = address(0xC0FFEE);
    address constant HOLDER = address(0xB0B);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant CAP = 2 ** 96;

    function setUp() public {
        nft = new PageNFTHarness(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        token = new MockFeeToken();
        gate = new MockGate();
    }

    function _sub(uint256 pid, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes(label)))));
    }

    function _parent(uint256 pid, address owner, uint64 exp, uint64 epoch) internal {
        vm.assume(pid != 0);
        vm.assume(owner != address(0) && owner != address(nft) && owner != address(reg));
        nft.h_setRecord(pid, "club", 0, exp, epoch, 0);
        nft.h_mint(owner, pid);
    }

    struct Sale {
        address controller;
        bool enabled;
        bool commitReveal;
        address feeToken;
        uint96 price;
        address gateToken;
        uint96 minGate;
        address pay;
        uint64 cEpoch;
        uint256 sub;
        bytes32 c;
        uint256 committedAt;
        bool avail;
        address counted;
        bool expected;
        uint256 regEth;
        uint256 proceeds;
        uint256 pz;
        uint256 tb;
        uint256 tp;
        bool exists;
        address holder;
    }

    function _readConfig(uint256 pid, Sale memory s) internal view {
        (s.controller, s.enabled, s.commitReveal, s.feeToken, s.price, s.gateToken, s.minGate, s.pay, s.cEpoch) =
            reg.config(pid);
    }

    /// @notice WSR1: a sale through either entry point succeeds exactly when the config is enabled, its
    /// fee token is the one the buyer expects and its price at most the buyer's maxPrice, the commitment
    /// rule holds (a ripe commitment for exactly this parent, label, recipient and secret for
    /// revealSubpageFor; commitReveal off for registerSubpageFor), the parent is in the config's epoch
    /// and held by its controller, the registrar is the counted minter, the label is free, the buyer
    /// passes the gate, and the payment is right (ETH: value at least the price; token: no ETH and
    /// enough balance and allowance). Then the payout's proceeds grow by exactly the price (ETH) or the
    /// payout gets exactly the price in tokens from the buyer, the buyer gets the rest of its ETH back,
    /// no other account's proceeds change, and the commitment is used. A refusal moves nothing.
    function check_WSR1_sale(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s_,
        address buyer, uint256 value, bool viaReveal, bool useToken, bool useGate
    ) public {
        Sale memory s;
        // the remaining inputs are symbolic too, made here to keep the stack small
        bytes32 secret = svm.createBytes32("secret");
        uint256 maxPrice = svm.createUint(256, "maxPrice");
        address expectedFeeToken = svm.createAddress("expectedFeeToken");
        uint256 bal = svm.createUint(256, "bal");
        uint256 allow = svm.createUint(256, "allow");
        uint256 gbal = svm.createUint(256, "gbal");
        uint256 pbal = svm.createUint(256, "pbal");
        address z = svm.createAddress("z");
        svm.enableSymbolicStorage(address(reg));
        s.exists = svm.createBool("exists");
        bool dead = svm.createBool("dead");
        s.holder = dead ? DEAD : HOLDER;
        uint64 se = uint64(svm.createUint(64, "se"));
        uint64 pe = uint64(svm.createUint(64, "pe"));
        vm.assume(
            buyer != address(nft) && buyer != address(reg) && buyer != address(token) && buyer != address(gate)
                && buyer.code.length == 0 && uint160(buyer) > 0x1ff
        );
        vm.assume(value <= CAP && bal <= CAP && allow <= CAP && gbal <= CAP && pbal <= CAP);
        _parent(pid, owner, exp, epoch);
        s.sub = _sub(pid, "fresh");
        vm.assume(s.sub != pid);
        if (s.exists) {
            vm.assume(se < type(uint64).max);
            nft.h_setRecord(s.sub, "fresh", pid, 0, se, pe);
            nft.h_mint(s.holder, s.sub);
        }
        nft.h_setMinter(pid, m, e, s_);
        vm.warp(ts);
        _readConfig(pid, s);
        vm.assume(s.feeToken == (useToken ? address(token) : address(0)));
        vm.assume(s.gateToken == (useGate ? address(gate) : address(0)));
        // Justification: configure refuses these payouts
        vm.assume(s.pay != address(reg) && s.pay != address(nft) && s.pay != address(0));
        vm.assume(z != s.pay);
        s.proceeds = reg.proceedsOf(s.pay);
        vm.assume(s.proceeds <= CAP);
        s.pz = reg.proceedsOf(z);
        token.setBal(s.pay, pbal);
        token.setBal(buyer, bal);
        token.setAllowance(buyer, address(reg), allow);
        gate.setBal(buyer, gbal);
        s.tb = token.balanceOf(buyer);
        s.tp = token.balanceOf(s.pay);
        s.c = keccak256(abi.encode(pid, string("fresh"), TO, secret));
        s.committedAt = reg.subCommitments(s.c);
        vm.assume(s.committedAt < 2 ** 64);
        s.avail = nft.isAvailable("fresh", pid);
        s.counted = nft.subpageMinterOf(pid);
        s.regEth = address(reg).balance;
        {
            bool ripe = s.committedAt != 0 && uint256(ts) >= s.committedAt + 20 && uint256(ts) <= s.committedAt + 86400;
            bool pays = useToken
                ? value == 0 && (s.price == 0 || (allow >= s.price && bal >= s.price))
                : value >= s.price;
            s.expected = s.enabled && s.feeToken == expectedFeeToken && uint256(s.price) <= maxPrice
                && (viaReveal ? ripe : !s.commitReveal) && s.cEpoch == epoch && s.controller == owner
                && s.counted == address(reg) && s.avail && (!useGate || gbal >= s.minGate) && pays;
        }
        vm.deal(buyer, value);
        bytes memory d = viaReveal
            ? abi.encodeCall(SubpageRegistrar.revealSubpageFor, (pid, "fresh", TO, secret, maxPrice, expectedFeeToken))
            : abi.encodeCall(SubpageRegistrar.registerSubpageFor, (pid, "fresh", TO, maxPrice, expectedFeeToken));
        vm.prank(buyer);
        (bool ok,) = address(reg).call{value: value}(d);
        assert(ok == s.expected);
        assert(reg.proceedsOf(z) == s.pz);
        if (ok) {
            assert(nft.ownerOf(s.sub) == TO);
            assert(nft.h_ownerOf(pid) == owner);
            if (viaReveal) assert(reg.subCommitments(s.c) == 0);
            if (useToken) {
                assert(address(reg).balance == s.regEth);
                assert(reg.proceedsOf(s.pay) == s.proceeds);
                assert(buyer.balance == 0);
                if (s.pay == buyer) {
                    assert(token.balanceOf(buyer) == s.tb);
                } else {
                    assert(token.balanceOf(buyer) == s.tb - s.price);
                    assert(token.balanceOf(s.pay) == s.tp + s.price);
                }
            } else {
                assert(address(reg).balance == s.regEth + s.price);
                assert(reg.proceedsOf(s.pay) == s.proceeds + s.price);
                assert(buyer.balance == value - s.price);
                assert(token.balanceOf(buyer) == s.tb && token.balanceOf(s.pay) == s.tp);
            }
        } else {
            assert(address(reg).balance == s.regEth);
            assert(reg.proceedsOf(s.pay) == s.proceeds);
            assert(buyer.balance == value);
            assert(token.balanceOf(buyer) == s.tb && token.balanceOf(s.pay) == s.tp);
            assert(reg.subCommitments(s.c) == s.committedAt);
            assert(nft.h_ownerOf(s.sub) == (s.exists ? s.holder : address(0)));
        }
    }

    /// @notice WSR2: claimProceeds(to) and claimProceedsFor(account), by any caller: they succeed exactly
    /// when the account has proceeds and the recipient is not the registrar; the account is the caller
    /// for claimProceeds and the recipient is to (the caller for 0), while claimProceedsFor always pays
    /// the account itself. Exactly that amount moves to the recipient, the account's proceeds become
    /// zero and no other account's proceeds change.
    function check_WSR2_claim(bool forOther, address caller, address account, address to, address z, uint256 extra)
        public
    {
        svm.enableSymbolicStorage(address(reg));
        address acct = forOther ? account : caller;
        address payee = forOther ? account : (to == address(0) ? caller : to);
        uint256 amt = reg.proceedsOf(acct);
        vm.assume(amt <= CAP && extra <= CAP && z != acct);
        // Justification: the recipient takes ETH like an account with no code (precompiles left out), or is
        // the registrar itself, which is refused
        vm.assume(
            payee == address(reg)
                || (payee.code.length == 0 && (uint160(payee) == 0 || uint160(payee) > 0x1ff))
        );
        uint256 pz = reg.proceedsOf(z);
        vm.deal(address(reg), amt + extra);
        uint256 pb = payee.balance;
        uint256 rb = address(reg).balance;
        vm.prank(caller);
        (bool ok,) = forOther
            ? address(reg).call(abi.encodeCall(SubpageRegistrar.claimProceedsFor, (account)))
            : address(reg).call(abi.encodeCall(SubpageRegistrar.claimProceeds, (to)));
        assert(ok == (amt != 0 && payee != address(reg)));
        assert(reg.proceedsOf(z) == pz);
        if (ok) {
            assert(reg.proceedsOf(acct) == 0);
            assert(payee.balance == pb + amt);
            assert(address(reg).balance == rb - amt);
        } else {
            assert(reg.proceedsOf(acct) == amt);
            assert(address(reg).balance == rb);
        }
    }

    function _raw(uint256 pid) internal view returns (bytes memory r) {
        (, r) = address(reg).staticcall(abi.encodeWithSignature("config(uint256)", pid));
    }

    /// @notice WSR3: configure by any caller with any arguments succeeds exactly when the caller holds the
    /// parent, the parent is a top level page, the payout (the caller for 0) is neither contract, the
    /// fee token is neither contract, price and gate balance fit in 96 bits and the gate token and gate
    /// balance are both set or both unset. It then stores exactly these values with the parent's epoch;
    /// a refusal changes nothing, and no other parent's config, proceeds or commitment ever changes.
    function check_WSR3_configure(
        uint256 pid, address owner, bool pExists, bool top, bool pDead, uint64 exp, uint64 epoch, address caller,
        address payout, address feeToken, uint256 price, bool enabled, address gateToken, uint256 minGate,
        bool commitReveal
    ) public {
        uint256 pid2 = svm.createUint(256, "pid2");
        address z = svm.createAddress("z");
        bytes32 k = svm.createBytes32("k");
        svm.enableSymbolicStorage(address(reg));
        vm.assume(pid != 0 && pid2 != pid);
        vm.assume(owner != address(0) && owner != address(nft));
        address holder = pDead ? DEAD : owner;
        if (pExists) {
            nft.h_setRecord(pid, "club", top ? 0 : 1, exp, epoch, 0);
            nft.h_mint(holder, pid);
        }
        bytes32 before = keccak256(_raw(pid));
        bytes32 before2 = keccak256(_raw(pid2));
        uint256 pz = reg.proceedsOf(z);
        uint256 ck = reg.subCommitments(k);
        address pay2 = payout == address(0) ? caller : payout;
        bool expected = pExists && caller == holder && top && pay2 != address(reg) && pay2 != address(nft)
            && feeToken != address(nft) && feeToken != address(reg) && price <= type(uint96).max
            && minGate <= type(uint96).max && ((gateToken != address(0)) == (minGate != 0));
        vm.prank(caller);
        (bool ok,) = address(reg).call(
            abi.encodeCall(
                SubpageRegistrar.configure,
                (pid, payout, feeToken, price, enabled, gateToken, minGate, commitReveal)
            )
        );
        assert(ok == expected);
        if (ok) {
            assert(
                keccak256(_raw(pid))
                    == keccak256(
                        abi.encode(caller, enabled, commitReveal, feeToken, price, gateToken, minGate, pay2, epoch)
                    )
            );
        } else {
            assert(keccak256(_raw(pid)) == before);
        }
        assert(keccak256(_raw(pid2)) == before2);
        assert(reg.proceedsOf(z) == pz && reg.subCommitments(k) == ck);
    }

    /// @notice WSR4: disable by any caller succeeds exactly when the caller holds the parent (a page of
    /// any kind with a token); it then clears only the enabled flag; a refusal changes nothing.
    function check_WSR4_disable(
        uint256 pid, address owner, bool pExists, bool top, bool pDead, uint64 exp, uint64 epoch, address caller,
        uint256 pid2
    ) public {
        svm.enableSymbolicStorage(address(reg));
        vm.assume(pid != 0 && pid2 != pid);
        vm.assume(owner != address(0) && owner != address(nft));
        address holder = pDead ? DEAD : owner;
        if (pExists) {
            nft.h_setRecord(pid, "club", top ? 0 : 1, exp, epoch, 0);
            nft.h_mint(holder, pid);
        }
        Sale memory s;
        _readConfig(pid, s);
        bytes32 before = keccak256(_raw(pid));
        bytes32 before2 = keccak256(_raw(pid2));
        vm.prank(caller);
        (bool ok,) = address(reg).call(abi.encodeCall(SubpageRegistrar.disable, (pid)));
        assert(ok == (pExists && caller == holder));
        if (ok) {
            assert(
                keccak256(_raw(pid))
                    == keccak256(
                        abi.encode(
                            s.controller, false, s.commitReveal, s.feeToken, s.price, s.gateToken, s.minGate, s.pay,
                            s.cEpoch
                        )
                    )
            );
        } else {
            assert(keccak256(_raw(pid)) == before);
        }
        assert(keccak256(_raw(pid2)) == before2);
    }
}
