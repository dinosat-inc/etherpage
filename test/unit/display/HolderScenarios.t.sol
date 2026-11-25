// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {console2} from "forge-std/console2.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// holds names and gives them to any account
contract Vault {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function give(PageNFT nft, address to, uint256 id) external {
        nft.transferFrom(address(this), to, id);
    }
}

// chooses the name it receives as its display name from inside the receiver hook
contract HookSetter {
    string public seen;

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        PageNFT(msg.sender).setPrimaryPage(id);
        seen = PageNFT(msg.sender).reverseResolve(address(this));
        return this.onERC721Received.selector;
    }
}

// Display name stories. setPrimaryPage stores the name's holder with the choice, and reverseResolve shows the name
// only while it is active, is still held by that holder, and resolves to the address that chose it. Each story
// asserts what reverseResolve answers after its key steps.
contract HolderScenariosTest is MinterBase {
    function _shows(address a, string memory want, string memory step) internal view {
        assertEq(nft.reverseResolve(a), want, step);
    }

    // alice holds alice and points it at her hot wallet, which chooses it as its display name
    function _hotSetup() internal returns (uint256 id) {
        id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
        _shows(hot, "alice", "setup");
    }

    // the buyer points the sold name back at the seller's hot wallet, which stays hidden, since the buyer is not
    // the holder it chose under
    function test_S1_buyerRepoints() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        _shows(hot, "", "after the sale");
        vm.startPrank(bob);
        nft.setAddr(id, hot);
        nft.setText(id, "url", "https://scam.example");
        vm.stopPrank();
        assertEq(nft.resolve(id), hot);
        assertEq(nft.primaryPage(hot), id, "the choice stays stored");
        _shows(hot, "", "after the buyer repoints");
    }

    // the buyer writes text and gives the name back to the seller, which holds it again with its saved address,
    // so the hot wallet shows it again while the buyer's text stays hidden
    function test_S2_giftBack() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.setText(id, "url", "https://scam.example");
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        _shows(hot, "alice", "back with the holder it was chosen under");
        assertEq(nft.text(id, "url"), "", "the buyer's text does not count for alice");
        _shows(alice, "", "alice never chose a display name");
    }

    // the buyer clears the records first and then gives it back: the seller's saved address stays retired, so the
    // name points at the seller and the hot wallet stays hidden
    function test_S2b_giftBackAfterClear() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.startPrank(bob);
        nft.clearRecords(id);
        nft.setText(id, "url", "https://scam.example");
        nft.transferFrom(bob, alice, id);
        vm.stopPrank();
        assertEq(nft.resolve(id), alice, "the address alice saved does not come back");
        _shows(hot, "", "after the gift back");
    }

    // the name lapses and someone else registers it, then points it at the old hot wallet
    function test_S3_lapseAndReregister() public {
        uint256 id = _hotSetup();
        _lapseAndRegister(id, carol);
        assertEq(nft.ownerOf(id), carol);
        _shows(hot, "", "after the registration by carol");
        vm.prank(carol);
        nft.setAddr(id, hot);
        _shows(hot, "", "after the new holder repoints");
    }

    // the same account registers it again after the lapse; the new registration starts with empty records, so the
    // hot wallet shows the name again only once the holder saves the same address again
    function test_S3b_sameHolderReregisters() public {
        uint256 id = _hotSetup();
        _lapseAndRegister(id, alice);
        _shows(hot, "", "fresh records");
        vm.prank(alice);
        nft.setAddr(id, hot);
        _shows(hot, "alice", "the same holder saves hot again");
    }

    // the parent's holder takes a live subpage back by minting over it, then points it at the hot wallet
    function test_S4_takeBack() public {
        uint256 p = _reg(alice, "parent");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("sub", p, bob);
        vm.prank(bob);
        nft.setAddr(s, hot);
        vm.prank(hot);
        nft.setPrimaryPage(s);
        _shows(hot, "sub.parent", "setup");
        vm.prank(alice);
        nft.registerSubpage("sub", p);
        assertEq(nft.ownerOf(s), alice);
        _shows(hot, "", "after the parent's holder takes it back");
        vm.prank(alice);
        nft.setAddr(s, hot);
        _shows(hot, "", "after the parent's holder repoints");
    }

    // the subpage is deleted, the shop sells it again to carol, and carol points it at the hot wallet
    function test_S5_deletedThenShop() public {
        uint256 p = _reg(alice, "parent");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("sub", p, bob);
        vm.prank(bob);
        nft.setAddr(s, hot);
        vm.prank(hot);
        nft.setPrimaryPage(s);
        _shows(hot, "sub.parent", "setup");
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, s);
        _shows(hot, "", "deleted");
        _sellSetup(p, 0.001 ether);
        vm.prank(carol);
        reg.registerSubpage{value: 0.001 ether}(p, "sub", 0.001 ether, address(0));
        assertEq(nft.ownerOf(s), carol);
        vm.prank(carol);
        nft.setAddr(s, hot);
        _shows(hot, "", "after the shop buyer repoints");
    }

    // custody and back: hidden while the vault holds the name, shown again once the holder it was chosen under
    // has it back
    function test_S6_custodyRoundTrip() public {
        uint256 id = _hotSetup();
        Vault v = new Vault();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(v), id);
        _shows(hot, "", "in custody");
        v.give(nft, alice, id);
        assertEq(nft.resolve(id), hot, "the address alice saved counts again");
        _shows(hot, "alice", "back from custody");
    }

    // the holder moves the name to the wallet that shows it, which shows it again only after choosing it as its
    // holder
    function test_S7_moveToPointee() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.transferFrom(alice, hot, id);
        _shows(hot, "", "hot now holds it");
        vm.prank(hot);
        nft.setPrimaryPage(id);
        _shows(hot, "alice", "hot chooses it again");
    }

    // a receiver chooses the name as its display name from its hook during a safe mint
    function test_S8_hookDuringMint() public {
        HookSetter h = new HookSetter();
        uint256 id = _regTo(alice, "hooked", address(h));
        assertEq(nft.ownerOf(id), address(h));
        assertEq(h.seen(), "hooked", "shown inside the hook");
        _shows(address(h), "hooked", "after the mint");
    }

    // hidden in grace, shown again after a stranger renews the name
    function test_S9_graceRenewByStranger() public {
        uint256 id = _hotSetup();
        vm.warp(nft.expiresAt(id) + 1);
        _shows(hot, "", "in grace");
        uint256 fee = nft.getFee(bytes("alice").length);
        vm.prank(stranger);
        nft.renew{value: fee}(id);
        _shows(hot, "alice", "renewed by a stranger");
    }

    // a seller bundle that chooses the name and then moves it, then a buyer bundle that points the name at itself
    // and chooses it
    function test_S10_multicall() public {
        uint256 id = _reg(alice, "alice");
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        d[1] = abi.encodeCall(PageNFT.transferFrom, (alice, bob, id));
        vm.prank(alice);
        nft.multicall(d);
        assertEq(nft.primaryPage(alice), 0, "the move cleared the seller's choice");
        _shows(alice, "", "seller after its bundle");
        d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setAddr, (id, bob));
        d[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        vm.prank(bob);
        nft.multicall(d);
        _shows(bob, "alice", "buyer after its bundle");
    }

    // the seller replaced the main address before the sale, and the buyer points the name at the first one
    function test_S11_replacedAddress() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.setAddr(id, hot2);
        _shows(hot, "", "the name points at hot2");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.setAddr(id, hot);
        _shows(hot, "", "after the buyer repoints the replaced address");
    }

    // a contract wallet like a Safe holds the name and the person behind it shows it, then the wallet sells it and the
    // buyer points it back at that person
    function test_S12_safeHolder() public {
        Vault safe = new Vault();
        uint256 id = _reg(carol, "carolsafe");
        vm.prank(carol);
        nft.transferFrom(carol, address(safe), id);
        vm.prank(address(safe));
        nft.setAddr(id, carol);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        _shows(carol, "carolsafe", "setup");
        safe.give(nft, bob, id);
        _shows(carol, "", "after the Safe sells");
        vm.prank(bob);
        nft.setAddr(id, carol);
        _shows(carol, "", "after the buyer repoints");
    }

    // the buyer writes text and gives the name to the wallet that showed it, which holds it now but is not the
    // holder it chose under, so it stays hidden
    function test_S13_giftToPointee() public {
        uint256 id = _hotSetup();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.setText(id, "url", "https://scam.example");
        vm.prank(bob);
        nft.transferFrom(bob, hot, id);
        _shows(hot, "", "after the gift to the pointee");
        assertEq(nft.text(id, "url"), "", "the buyer's text does not count for hot");
    }

    // logs the gas of a call made with cold storage, which must succeed
    function _g(string memory tag, address who, bytes memory call) internal {
        vm.cool(address(nft));
        vm.prank(who);
        uint256 g = gasleft();
        (bool ok,) = address(nft).call(call);
        g -= gasleft();
        assertTrue(ok, tag);
        console2.log(tag, g);
    }

    // the gas of each display name call and of three transfers, and the display name each step leaves
    function test_G_gas() public {
        uint256 id = _reg(alice, "alice");
        uint256 id2 = _reg(alice, "alice2");
        vm.prank(alice);
        nft.setAddr(id, hot);
        _g("G1 setPrimaryPage first, holder", alice, abi.encodeCall(PageNFT.setPrimaryPage, (id2)));
        _shows(alice, "alice2", "G1");
        _g("G2 setPrimaryPage first, pointee", hot, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _shows(hot, "alice", "G2");
        _g("G3 setPrimaryPage again, pointee", hot, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _shows(hot, "alice", "G3");
        _g("G4 setPrimaryPage 0", hot, abi.encodeCall(PageNFT.setPrimaryPage, (0)));
        _shows(hot, "", "G4");
        _g("G5 setPrimaryPage after 0", hot, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        vm.cool(address(nft));
        uint256 g = gasleft();
        string memory shown = nft.reverseResolve(hot);
        console2.log("G6 reverseResolve shown", g - gasleft());
        assertEq(shown, "alice", "G6");
        _g("G7 transfer of a name the seller does not display", alice, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id)));
        _shows(alice, "alice2", "G7 keeps the seller's own display name");
        _shows(hot, "", "G7 hides the pointee's");
        _g("G8 transfer, seller display cleared", alice, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id2)));
        assertEq(nft.primaryPage(alice), 0, "G8");
        _g("G9 transfer back", bob, abi.encodeCall(PageNFT.transferFrom, (bob, alice, id2)));
        _shows(alice, "", "G9 the cleared choice does not come back");
    }

    // the gas of a reveal that mints, with cold storage
    function test_G_mint() public {
        bytes32 secret = bytes32(uint256(7));
        bytes32 c = nft.makeCommitment("mintgas", alice, 0, secret);
        vm.prank(alice);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("mintgas");
        vm.cool(address(nft));
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = nft.reveal{value: total}("mintgas", alice, 0, secret);
        console2.log("G10 reveal", g - gasleft());
        assertEq(nft.ownerOf(id), alice);
    }
}
