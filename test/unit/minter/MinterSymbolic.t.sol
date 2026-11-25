// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

/// @notice Symbolic checks of the minter rules. Forge runs them as fuzz tests, and Halmos runs them
///         through MinterSymbolicProofsTest on the proofs build.
contract MinterSymbolicTest is Test {
    PageNFT nft;
    uint256 club;
    uint256 live;
    address constant OWNER = address(0xA11CE);
    address constant OTHER = address(0xB0B);
    address constant HOT = address(0x4071);
    address constant TO = address(0xC0FFEE);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(OWNER, 10 ether);
        bytes32 s = bytes32(uint256(1));
        vm.prank(OWNER);
        nft.commit(nft.makeCommitment("club", OWNER, 0, s));
        vm.warp(1_800_000_061);
        (,,, uint256 total) = nft.quote("club");
        vm.prank(OWNER);
        club = nft.reveal{value: total}("club", OWNER, 0, s);
        vm.prank(OWNER);
        live = nft.registerSubpageFor("live", club, OTHER);
    }

    function _plain(address a) internal view returns (bool) {
        return a != address(0) && a.code.length == 0 && a != address(this) && a != address(vm);
    }

    function _counted() internal view returns (address m) {
        return nft.subpageMinterOf(club);
    }

    /// SC-1: after the holder that chose the minter moves the name away, a call by anyone but the
    /// new holder succeeds only from that former holder and only to switch the minter off, and what
    /// it switched off stays off when the name comes back.
    function test_check_away_setter_rule(address caller, address m) public {
        vm.assume(caller != OTHER);
        vm.prank(OWNER);
        nft.setSubpageMinter(club, HOT);
        vm.prank(OWNER);
        nft.transferFrom(OWNER, OTHER, club);

        bool ok;
        vm.prank(caller);
        try nft.setSubpageMinter(club, m) {
            ok = true;
        } catch {}
        if (ok) assert(m == address(0) && caller == OWNER);
        address cm = _counted();
        assert(cm == address(0));

        vm.prank(OTHER);
        nft.transferFrom(OTHER, OWNER, club);
        cm = _counted();
        if (ok) assert(cm == address(0));
        else assert(cm == HOT);
    }

    /// SC-2: with minter m chosen by the holder, exactly the holder and m can mint a fresh label.
    function test_check_who_mints(address caller, address m) public {
        vm.assume(_plain(caller));
        vm.prank(OWNER);
        nft.setSubpageMinter(club, m);
        vm.prank(caller);
        try nft.registerSubpageFor("fresh", club, OWNER) {
            assert(caller == OWNER || caller == m);
        } catch {
            assert(caller != OWNER && caller != m);
        }
    }

    /// SC-3: a minter never overwrites a live subpage, whoever it names as recipient,
    /// unless DEAD holds it (the recycle bin), and then it mints to any recipient that takes tokens.
    function test_check_minter_never_overwrites(address m, uint8 toPick, bool dead) public {
        vm.assume(m != OWNER && _plain(m));
        // Justification: fixed recipients; a symbolic one gives the mint a memory offset Halmos cannot follow
        uint8 k = toPick % 5;
        address to = k == 0 ? TO : k == 1 ? OTHER : k == 2 ? OWNER : k == 3 ? address(0) : address(nft);
        address h = OTHER;
        if (dead) {
            vm.prank(OTHER);
            nft.transferFrom(OTHER, DEAD, live);
            h = DEAD;
        }
        vm.prank(OWNER);
        nft.setSubpageMinter(club, m);
        vm.prank(m);
        try nft.registerSubpageFor("live", club, to) {
            assert(dead && k < 3);
            assert(nft.ownerOf(live) == to);
        } catch {
            assert(!dead || k >= 3);
            assert(nft.ownerOf(live) == h);
        }
    }

    /// SC-4: while the holder holds the name, no other caller changes what counts, and any
    /// call by another account that succeeds names zero. The only such call is from
    /// address(0) on a record nobody ever wrote, whose setter is zero; no account can send
    /// from address(0), and it would leave the minter at zero anyway.
    function test_check_non_holder_changes_nothing(address caller, address m) public {
        vm.assume(caller != OWNER);
        address bm = _counted();
        bool ok;
        vm.prank(caller);
        try nft.setSubpageMinter(club, m) {
            ok = true;
        } catch {}
        if (ok) assert(m == address(0) && caller == address(0));
        address cm = _counted();
        assert(cm == bm);
    }

    /// SC-5: whatever minter the holder picks, only the holder overwrites a live
    /// subpage; over one held by DEAD the counted minter may mint too, and nobody else.
    function test_check_take_back_is_exactly_the_minter(address caller, address m, bool dead) public {
        vm.assume(_plain(caller) && caller != OTHER);
        address h = OTHER;
        if (dead) {
            vm.prank(OTHER);
            nft.transferFrom(OTHER, DEAD, live);
            h = DEAD;
        }
        vm.prank(OWNER);
        nft.setSubpageMinter(club, m);
        vm.prank(caller);
        try nft.registerSubpageFor("live", club, TO) {
            assert(caller == OWNER || (dead && caller == m));
            assert(nft.ownerOf(live) == TO);
        } catch {
            assert(caller != OWNER && !(dead && caller == m));
            assert(nft.ownerOf(live) == h);
        }
    }
}
