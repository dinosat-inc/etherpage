// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {HookCaller, SafeLike, Delegate7702} from "../utils/MinterMocks.sol";

// a custody contract that holds names for whoever deposited them and forwards the minter pick
contract NameVault {
    PageNFT public immutable nft;
    bool public immutable clearOnWithdraw;
    mapping(uint256 => address) public depositor;

    constructor(PageNFT n, bool c) {
        nft = n;
        clearOnWithdraw = c;
    }

    function deposit(uint256 id) external {
        nft.transferFrom(msg.sender, address(this), id);
        depositor[id] = msg.sender;
    }

    function withdraw(uint256 id) external {
        require(depositor[id] == msg.sender, "not depositor");
        delete depositor[id];
        nft.transferFrom(address(this), msg.sender, id);
        if (clearOnWithdraw) nft.setSubpageMinter(id, address(0));
    }

    function setMinter(uint256 id, address m) external {
        require(depositor[id] == msg.sender, "not depositor");
        nft.setSubpageMinter(id, m);
    }
}

// a contract that can hold names, whose hook makes the one call it was armed with when it next receives a name
contract HolderHook {
    address public target;
    bytes public data;
    bool public ok;
    bytes public ret;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    function exec(address to, uint256 value, bytes calldata d) external payable returns (bytes memory) {
        (bool s, bytes memory r) = to.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (ok, ret) = t.call(data);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

contract MinterAuthTest is MinterBase {
    uint256 club;
    address key = makeAddr("compromisedKey");
    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 1000 ether);
        club = _reg(alice, "club");
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    // S1: a sale and a buy back bring the old pick back, and that pick can only create subpages
    function test_S1_buyBackRevivesOldPick() public {
        _setMinter(club, key);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", club, key);
        // bob issues a subpage to his customer while he holds club
        vm.prank(bob);
        uint256 shop = nft.registerSubpageFor("shop", club, carol);
        // bob sells club back to alice, alice signs nothing about the minter
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        address m = nft.subpageMinterOf(club);
        assertEq(m, key);
        // the pick that came back cannot take the customer's subpage, it can only create
        vm.prank(key);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("shop", club, key);
        assertEq(nft.ownerOf(shop), carol);
        vm.prank(key);
        nft.registerSubpageFor("wallet", club, key);
    }

    // S2: an unasked gift back to the old holder revives a pick she forgot; switching it off while away prevents it
    function test_S2_unaskedGiftRevivesForgottenPick() public {
        _setMinter(club, key);
        vm.prank(alice);
        nft.transferFrom(alice, attacker, club);
        // the buyer, who also holds key, sends club back without asking
        vm.prank(attacker);
        nft.transferFrom(attacker, alice, club);
        vm.prank(key);
        uint256 w = nft.registerSubpageFor("wallet", club, attacker);
        assertEq(nft.ownerOf(w), attacker);
        assertEq(nft.getPageName(w), "wallet.club");

        // same story with dave and gold, but dave switches his pick off after selling
        uint256 gold = _reg(dave, "gold");
        _setMinter(gold, key);
        vm.prank(dave);
        nft.transferFrom(dave, attacker, gold);
        vm.prank(dave);
        nft.setSubpageMinter(gold, address(0));
        vm.prank(attacker);
        nft.transferFrom(attacker, dave, gold);
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("wallet", gold, attacker);
    }

    // S3: a custody contract is the setter, so a later depositor inherits an earlier depositor's pick
    function test_S3_custodyContractChangesUsers() public {
        NameVault vault = new NameVault(nft, false);
        vm.startPrank(alice);
        nft.approve(address(vault), club);
        vault.deposit(club);
        vault.setMinter(club, key);
        vault.withdraw(club);
        vm.stopPrank();
        // alice sells club to bob, bob deposits into the same vault
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(bob);
        uint256 s = nft.registerSubpageFor("bobs", club, carol);
        vm.startPrank(bob);
        nft.approve(address(vault), club);
        vault.deposit(club);
        vm.stopPrank();
        address m = nft.subpageMinterOf(club);
        assertEq(m, key, "alice's pick counts inside bob's deposit");
        vm.prank(key);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("bobs", club, key);
        assertEq(nft.ownerOf(s), carol);
        vm.prank(key);
        nft.registerSubpageFor("keys", club, key);
        // bob himself cannot switch it off: only the vault can, through bob's own setMinter
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        vm.prank(bob);
        vault.setMinter(club, address(0));
        assertEq(_minter(club), address(0));

        // a vault that clears on withdraw does not leak
        uint256 gold = _reg(dave, "gold");
        NameVault clean = new NameVault(nft, true);
        vm.startPrank(dave);
        nft.approve(address(clean), gold);
        clean.deposit(gold);
        clean.setMinter(gold, key);
        clean.withdraw(gold);
        nft.transferFrom(dave, bob, gold);
        vm.stopPrank();
        vm.startPrank(bob);
        nft.approve(address(clean), gold);
        clean.deposit(gold);
        vm.stopPrank();
        assertEq(_minter(gold), address(0));
    }

    // S4: epoch and expiry edges, from the last active second to a new registration by the same account
    function test_S4_epochEdges() public {
        _setMinter(club, key);
        uint256 e = nft.expiresAt(club);
        vm.warp(e);
        vm.prank(key);
        nft.registerSubpageFor("edge", club, carol);
        vm.warp(e + 1);
        vm.prank(key);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("edge2", club, carol);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot);
        assertEq(_minter(club), key);
        // a stranger renews in grace and the pick is back
        uint256 fee = nft.getFee(4);
        vm.prank(stranger);
        nft.renew{value: fee}(club);
        vm.prank(key);
        nft.registerSubpageFor("edge2", club, carol);
        // past grace, then past the premium and a release: the view still names key, minting still refuses
        e = nft.expiresAt(club);
        vm.warp(e + 90 days + 21 days + 1);
        assertEq(_minter(club), key);
        vm.prank(key);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("edge3", club, carol);
        nft.release(club);
        assertEq(_minter(club), key);
        // alice registers club again herself: the pick is off
        _reg(alice, "club");
        assertEq(nft.ownerOf(club), alice);
        assertEq(_minter(club), address(0));
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("edge3", club, carol);
    }

    // S4b: a new registration during the premium auction by another account, then a gift back
    function test_S4b_auctionThenReturn() public {
        _setMinter(club, key);
        uint256 e = nft.expiresAt(club);
        vm.warp(e + 90 days + 1 days);
        assertGt(nft.getPremium(club), 0);
        _reg(bob, "club");
        assertEq(nft.ownerOf(club), bob);
        assertEq(_minter(club), address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        assertEq(_minter(club), address(0));
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", club, key);
        // alice's old record still exists and she may clear it, but it never counts in the new epoch
        (address rm, uint64 re, address rs) = _raw(club);
        assertEq(rm, key);
        assertEq(re, 1);
        assertEq(rs, alice);
    }

    // S5: id 0, ghost ids and subpage ids
    function test_S5_oddIds() public {
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("sub", club, alice);
        uint256 ghost = _id("ghost");
        address[3] memory who = [alice, key, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.setSubpageMinter(0, key);
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.setSubpageMinter(ghost, key);
            vm.expectRevert(PageNFT.NotTopLevel.selector);
            nft.setSubpageMinter(sub, key);
            vm.expectRevert(PageNFT.NotTopLevel.selector);
            nft.setSubpageMinter(sub, address(0));
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.registerSubpageFor("x", 0, alice);
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.registerSubpageFor("x", ghost, alice);
            vm.expectRevert(PageNFT.NotTopLevel.selector);
            nft.registerSubpageFor("x", sub, alice);
            vm.stopPrank();
        }
        address m = nft.subpageMinterOf(0);
        assertEq(m, address(0));
        m = nft.subpageMinterOf(sub);
        assertEq(m, address(0));
        m = nft.subpageMinterOf(ghost);
        assertEq(m, address(0));
    }

    // S6: operators and approved accounts cannot pick; a round trip through them only wipes the holder's pick
    function test_S6_operatorAndApprovedRoundTrip() public {
        _setMinter(club, key);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(alice);
        nft.approve(carol, club);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, bob);
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, carol);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        // the operator moves club to itself, picks, and moves it back
        vm.startPrank(bob);
        nft.transferFrom(alice, bob, club);
        nft.setSubpageMinter(club, bob);
        nft.transferFrom(bob, alice, club);
        vm.stopPrank();
        address m = nft.subpageMinterOf(club);
        assertEq(m, address(0), "operator's pick does not count for alice");
        vm.prank(bob);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("op", club, bob);
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("op", club, key);
        // the operator is now the recorded setter away from the name: it may clear, never pick
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, bob);
        vm.prank(bob);
        nft.setSubpageMinter(club, address(0));
        m = nft.subpageMinterOf(club);
        assertEq(m, address(0));
    }

    // S7: switching off while away cannot clear a later holder's pick or set one
    function test_S7_awaySetterAbuse() public {
        _setMinter(club, key);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, attacker);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, alice);
        // bob picks, alice can no longer touch it
        vm.prank(bob);
        nft.setSubpageMinter(club, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        assertEq(_minter(club), hot);
        vm.prank(hot);
        nft.registerSubpageFor("b", club, carol);

        // a stale setter from an older epoch clears after a new registration, then gets the name
        uint256 gold = _reg(dave, "gold");
        _setMinter(gold, key);
        vm.warp(nft.expiresAt(gold) + 90 days + 21 days + 1);
        _reg(bob, "gold");
        vm.prank(dave);
        nft.setSubpageMinter(gold, address(0));
        (address rm, uint64 re, address rs) = _raw(gold);
        assertEq(rm, address(0));
        assertEq(re, 2, "the away clear stamps the new epoch");
        assertEq(rs, dave);
        vm.prank(bob);
        nft.transferFrom(bob, dave, gold);
        address m = nft.subpageMinterOf(gold);
        assertEq(m, address(0));
        vm.prank(key);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", gold, key);
        // bob still can pick for himself once he holds it again
        vm.prank(dave);
        nft.transferFrom(dave, bob, gold);
        vm.prank(bob);
        nft.setSubpageMinter(gold, hot);
        assertEq(_minter(gold), hot);
    }

    // S8: address(0) as a caller, which no account can be, mints nothing, with no pick, with a cleared pick and over a
    // live subpage
    function test_S8_zeroCallerMintsNothing() public {
        // no pick ever written for club
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("zero", club, stranger);
        assertTrue(nft.isAvailable("zero", club));
        // a live subpage is refused
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("live", club, carol);
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("live", club, stranger);
        // the holder clears the pick, which the contract allows; the zero caller is still refused
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("zero", club, stranger);
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("live", club, stranger);
        assertEq(nft.ownerOf(s), carol, "address(0) cannot take back either");
    }

    function test_S8b_zeroCallerOnSetter() public {
        uint256 gold = _reg(dave, "gold");
        // unwritten record: setter is zero, so address(0) passes as the setter away
        vm.prank(address(0));
        nft.setSubpageMinter(gold, address(0));
        (address rm, uint64 re, address rs) = _raw(gold);
        assertEq(rm, address(0));
        assertEq(re, 1);
        assertEq(rs, address(0));
        assertEq(_minter(gold), address(0));
        vm.prank(address(0));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(gold, key);
        // written record: refused
        _setMinter(gold, key);
        vm.prank(address(0));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(gold, address(0));
    }

    // S9: the registrar as minter never takes back a live subpage, and a parent the registrar holds never sells
    function test_S9_registrarNeverTakesBackAndHeldParentNeverSells() public {
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("live", club, carol);
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "live", 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "LIVE", 0, address(0));
        assertEq(nft.ownerOf(s), carol);
        // the parent stranded in the registrar: no sale, no config, no pick
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), club);
        assertEq(_minter(club), address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "new", 0, address(0));
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        // alice may still clear her record from afar
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
    }

    // S10: odd picks are inert
    function test_S10_oddPicks() public {
        address[4] memory picks = [address(nft), DEAD, address(reg), alice];
        for (uint256 i; i < 4; ++i) {
            _setMinter(club, picks[i]);
            vm.prank(stranger);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("x", club, stranger);
            vm.prank(key);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("x", club, key);
        }
        // the registrar pick without a config sells nothing
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(club, "x", 0, address(0));
    }

    // S11: a sale recipient that holds the parent calls back in: it can pick again, but cannot mint or buy again inside
    function test_S11_holderHookDuringSale() public {
        HolderHook h = new HolderHook();
        uint256 p = _regTo(alice, "hooked", address(h));
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (p, address(reg))));
        h.exec(address(reg), 0, abi.encodeCall(SubpageRegistrar.configure, (p, payout, address(0), 0, true, address(0), 0, false)));
        // inside the hook, the holder tries a second sale
        h.arm(address(reg), abi.encodeCall(SubpageRegistrar.registerSubpageFor, (p, "two", address(h), 0, address(0))));
        vm.prank(buyer);
        reg.registerSubpageFor(p, "one", address(h), 0, address(0));
        assertFalse(h.ok());
        assertEq(bytes4(h.ret()), REENTRANCY);
        // inside the hook, a direct mint as the holder
        h.arm(address(nft), abi.encodeCall(PageNFT.registerSubpageFor, ("three", p, address(h))));
        vm.prank(buyer);
        reg.registerSubpageFor(p, "four", address(h), 0, address(0));
        assertFalse(h.ok());
        assertEq(bytes4(h.ret()), REENTRANCY);
        // inside the hook, the holder switches the pick to another key: it succeeds, the sale stands
        h.arm(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (p, key)));
        vm.prank(buyer);
        uint256 five = reg.registerSubpageFor(p, "five", address(h), 0, address(0));
        assertTrue(h.ok());
        assertEq(nft.ownerOf(five), address(h));
        assertEq(_minter(p), key);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(p, "six", 0, address(0));
    }

    // S12: a minter's recipient hook can neither pick a minter without holding the parent nor mint inside the mint
    function test_S12_minterRecipientHook() public {
        _setMinter(club, key);
        HolderHook h = new HolderHook();
        h.arm(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (club, address(h))));
        vm.prank(key);
        nft.registerSubpageFor("r1", club, address(h));
        assertFalse(h.ok());
        assertEq(bytes4(h.ret()), PageNFT.Unauthorized.selector);
        h.arm(address(nft), abi.encodeCall(PageNFT.registerSubpageFor, ("r2", club, address(h))));
        vm.prank(key);
        nft.registerSubpageFor("r3", club, address(h));
        assertFalse(h.ok());
        assertEq(bytes4(h.ret()), REENTRANCY);
        assertEq(_minter(club), key);
    }

    // S13: an old setter contract gets the name back by a safe transfer: it holds again and its pick counts again
    function test_S13_oldSetterContractGetsNameBackBySafeTransfer() public {
        HolderHook h = new HolderHook();
        uint256 p = _regTo(alice, "ctr", address(h));
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (p, key)));
        h.exec(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(h), bob, p)));
        assertEq(_minter(p), address(0));
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(h), p);
        assertEq(_minter(p), key);
    }

    // S14: 7702 accounts as minter and as holder behave as plain accounts
    function test_S14_7702MinterAndSetter() public {
        (address eoa, uint256 pk) = makeAddrAndKey("m7702");
        Delegate7702 impl = new Delegate7702();
        vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(stranger);
        (bool ok,) = eoa.call("");
        assertTrue(ok);
        _setMinter(club, eoa);
        vm.prank(eoa);
        nft.registerSubpageFor("d", club, carol);
        // alice moves club to a second 7702 account, so her pick stops counting and the old minter is refused,
        // as with any new holder
        (address eoa2, uint256 pk2) = makeAddrAndKey("s7702");
        vm.signAndAttachDelegation(address(impl), pk2);
        vm.prank(stranger);
        (ok,) = eoa2.call("");
        vm.prank(alice);
        nft.transferFrom(alice, eoa2, club);
        assertEq(_minter(club), address(0));
        vm.prank(eoa);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("e", club, carol);
    }
}
