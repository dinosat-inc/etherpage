// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";

/// @notice Symbolic proof that a trial registration switches off a stale subpage minter.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract MinterTrialProofsTest --function test_check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract MinterTrialProofsTest is Test {
    PageCard card;
    PageNFT nft;

    string constant LABEL = "club";
    address constant OWNER = address(0xA11CE);
    address constant TO = address(0xC0FFEE);

    function setUp() public {
        card = new PageCard();
        nft = new PageNFT(card);
    }

    // the raw minter record as two words, exactly as slot 12 stores it
    function _rawMinter(uint256 id) internal view returns (uint256 w0, uint256 w1) {
        bytes32 b = keccak256(abi.encode(id, uint256(12)));
        w0 = uint256(vm.load(address(nft), b));
        w1 = uint256(vm.load(address(nft), bytes32(uint256(b) + 1)));
    }

    function _register(address who, bool trial) internal returns (uint256 id) {
        bytes32 secret = bytes32(uint256(7));
        bytes32 c = nft.makeCommitment(LABEL, who, 0, secret);
        vm.prank(who);
        nft.commit(trial ? keccak256(abi.encode(bytes(LABEL), who, uint256(0), secret, true)) : c);
        vm.warp(block.timestamp + 61);
        if (trial) {
            uint256 fee = nft.getFee(bytes(LABEL).length) / 10;
            vm.deal(who, fee);
            vm.prank(who);
            id = nft.revealTrial{value: fee}(LABEL, who, 0, secret);
        } else {
            (,,, uint256 total) = nft.quote(LABEL);
            vm.deal(who, total);
            vm.prank(who);
            id = nft.reveal{value: total}(LABEL, who, 0, secret);
        }
    }

    /// @notice MP7t: a trial registration over a name whose last registration has ended switches the
    /// minter that registration picked off, whoever takes the trial (the former setter included), and
    /// leaves the raw record untouched. The last registration is either a paid year past its auction, its
    /// deposit released or not, or an ended trial, released or not. The minter stays off after the new holder
    /// renews the trial into a paid name, so the stale minter cannot mint a subpage under it.
    /// @dev Technique: concrete registrations with symbolic minter, registrant and history. Classification: DIRECT.
    function test_check_MP7t_trialRegistrationSwitchesOff(address m, bool sameAccount, bool afterTrial, bool releaseFirst)
        public
    {
        vm.warp(1_800_000_000);
        address first = OWNER;
        address second = sameAccount ? OWNER : TO;
        uint256 id = _register(first, afterTrial);
        vm.prank(first);
        nft.setSubpageMinter(id, m);
        (uint256 w0, uint256 w1) = _rawMinter(id);
        uint256 exp = nft.expiresAt(id);
        if (afterTrial) {
            if (releaseFirst) {
                vm.warp(exp + 1);
                nft.release(id);
            }
            vm.warp(exp + 14 days + 1);
        } else {
            vm.warp(exp + 90 days + 21 days + 1);
            // the trial releases the deposit by itself when nobody did
            if (releaseFirst) nft.release(id);
        }
        assert(_register(second, true) == id);
        assert(nft.depositOf(id) == 0);

        (uint256 a0, uint256 a1) = _rawMinter(id);
        assert(a0 == w0 && a1 == w1);
        assert(nft.subpageMinterOf(id) == address(0));
        assert(nft.ownerOf(id) == second);
        assert(nft.epochOf(id) == 2);
        (address payer, uint96 held) = nft.trialPaymentOf(id);
        assert(payer == second && held != 0);

        uint256 fee = nft.getFee(bytes(LABEL).length);
        vm.deal(second, fee);
        vm.prank(second);
        nft.renew{value: fee}(id);
        assert(nft.depositOf(id) == fee);
        assert(nft.subpageMinterOf(id) == address(0));

        // the zero address cannot send a call, and the holder may always mint
        if (m != address(0) && m != second) {
            vm.prank(m);
            (bool ok,) = address(nft).call(abi.encodeCall(PageNFT.registerSubpage, ("sub", id)));
            assert(!ok);
        }
    }
}
