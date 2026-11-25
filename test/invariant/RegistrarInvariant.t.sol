// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {MockERC20} from "../utils/MinterMocks.sol";

// Calls every registrar function on the two pages the test puts up for sale, as their holders, a buyer or a
// stranger, and claims also as the payout account. The arguments are mostly ones that can succeed: new terms in ETH
// or in a token, with or without a gate and with commit and reveal or without, sales of new labels, of labels used
// before and of the taken label live, receivers among the four and any address, the price and fee token the terms
// hold, reveals of the commitments made, and claims by the accounts owed ETH. Each action makes one registrar call
// that can change state, with no try or catch, so it reverts when that call reverts and the campaign table counts
// the calls that went through.
contract RegistrarHandler is Test {
    PageNFT internal nft;
    SubpageRegistrar internal reg;
    MockERC20 internal usd;
    uint256[2] internal parents;
    address[4] internal actors;
    // the accounts terms may pay: the payout account and the two holders
    address[3] internal owed;

    struct Commitment {
        uint256 parentId;
        string label;
        address to;
        bytes32 secret;
    }

    // the commitments made and not yet revealed, and the number of new labels the calls that went through used
    Commitment[] internal pending;
    uint256 internal labels;

    constructor(
        PageNFT n,
        SubpageRegistrar r,
        MockERC20 u,
        uint256[2] memory parentIds,
        address[4] memory callers,
        address[3] memory payees
    ) {
        nft = n;
        reg = r;
        usd = u;
        parents = parentIds;
        actors = callers;
        owed = payees;
    }

    // spreads a fuzz seed over all bits, as the fuzzer often sends small numbers
    function _h(uint256 x, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(x, salt)));
    }

    // the taken label live, live in capitals, a new label used before, which may have been sold, or a new one
    function _label(uint256 s) internal returns (string memory) {
        s = _h(s, 0);
        uint256 k = s % 16;
        if (k == 0) return "live";
        if (k == 1) return "LIVE";
        if (k == 2 && labels != 0) return string.concat("s", LibString.toString((s >> 4) % labels));
        return string.concat("s", LibString.toString(labels++));
    }

    // the first account terms may pay from place s on that is owed ETH, or the one at s when none is
    function _owedAccount(uint256 s) internal view returns (address) {
        for (uint256 j; j < 3; ++j) {
            address a = owed[(s % 3 + j) % 3];
            if (reg.proceedsOf(a) != 0) return a;
        }
        return owed[s % 3];
    }

    // one of the four, or any address
    function _to(uint256 s) internal view returns (address) {
        s = _h(s, 1);
        return s % 4 != 3 ? actors[(s >> 2) % 4] : address(uint160(s >> 8));
    }

    // the fee token and price of the terms as they stand, and the ETH to send: the price and up to 0.01 ether more,
    // which comes back, or none for a token
    function _terms(uint256 parentId, uint256 extra)
        internal
        view
        returns (address feeToken, uint256 price, uint256 value)
    {
        (,,, feeToken, price,,,,) = reg.config(parentId);
        value = feeToken == address(0) ? price + bound(extra, 0, 0.01 ether) : 0;
    }

    // terms set by the holder half the time, else by any of the four: paid to the caller, the payout account or a
    // holder, or to the registrar or PageNFT, which configure refuses; in ETH, in the token, or in PageNFT, which it
    // refuses; with no gate, a gate of the token or of PageNFT, or a gate with no minimum, which it refuses
    function configure(uint256 whoS, uint256 pS, uint256 cfgS, uint256 price) external {
        uint256 parentId = parents[pS % 2];
        whoS = _h(whoS, 2);
        cfgS = _h(cfgS, 3);
        uint256 k = cfgS % 6;
        address pay = k == 0 ? address(0) : k < 4 ? owed[k - 1] : k == 4 ? address(reg) : address(nft);
        uint256 f = (cfgS >> 8) % 8;
        address feeToken = f < 5 ? address(0) : f < 7 ? address(usd) : address(nft);
        uint256 g = (cfgS >> 16) % 8;
        address gateToken = g < 4 ? address(0) : g < 6 ? address(usd) : address(nft);
        uint256 minGate = g < 4 || g == 7 ? 0 : 1 + (cfgS >> 24) % 3;
        vm.prank(whoS % 2 == 0 ? nft.ownerOf(parentId) : actors[(whoS >> 1) % 4]);
        reg.configure(
            parentId,
            pay,
            feeToken,
            bound(price, 0, 1 ether),
            (cfgS >> 32) % 4 != 0,
            gateToken,
            minGate,
            (cfgS >> 40) % 2 == 0
        );
    }

    function disable(uint256 whoS, uint256 pS) external {
        vm.prank(actors[whoS % 4]);
        reg.disable(parents[pS % 2]);
    }

    function commitSubpage(uint256 whoS, uint256 pS, uint256 lS, uint256 toS, bytes32 secret) external {
        Commitment memory c = Commitment(parents[pS % 2], _label(lS), _to(toS), secret);
        bytes32 commitment = reg.makeSubpageCommitment(c.parentId, c.label, c.to, c.secret);
        vm.prank(actors[whoS % 4]);
        reg.commitSubpage(commitment);
        pending.push(c);
    }

    function registerSubpage(uint256 whoS, uint256 pS, uint256 lS, uint256 extra) external {
        uint256 parentId = parents[pS % 2];
        (address feeToken, uint256 price, uint256 value) = _terms(parentId, extra);
        vm.prank(actors[whoS % 4]);
        reg.registerSubpage{value: value}(parentId, _label(lS), price, feeToken);
    }

    function registerSubpageFor(uint256 whoS, uint256 pS, uint256 lS, uint256 toS, uint256 extra) external {
        uint256 parentId = parents[pS % 2];
        (address feeToken, uint256 price, uint256 value) = _terms(parentId, extra);
        vm.prank(actors[whoS % 4]);
        reg.registerSubpageFor{value: value}(parentId, _label(lS), _to(toS), price, feeToken);
    }

    function revealSubpage(uint256 whoS, uint256 iS, uint256 extra) external {
        _reveal(actors[whoS % 4], iS, extra, true);
    }

    function revealSubpageFor(uint256 whoS, uint256 iS, uint256 extra) external {
        _reveal(actors[whoS % 4], iS, extra, false);
    }

    // reveals the first pending commitment from place iS on, one that names the caller for revealSubpage, or one
    // that was never made when there is none, first waiting out the 20 seconds a commitment must age
    function _reveal(address who, uint256 iS, uint256 extra, bool own) internal {
        uint256 n = pending.length;
        uint256 found = type(uint256).max;
        for (uint256 j; j < n; ++j) {
            uint256 k = (iS % n + j) % n;
            if (!own || pending[k].to == who) {
                found = k;
                break;
            }
        }
        Commitment memory c =
            found == type(uint256).max ? Commitment(parents[iS % 2], _label(iS), who, bytes32(iS)) : pending[found];
        uint256 committedAt = reg.subCommitments(reg.makeSubpageCommitment(c.parentId, c.label, c.to, c.secret));
        if (committedAt != 0 && block.timestamp < committedAt + 20) vm.warp(committedAt + 20);
        (address feeToken, uint256 price, uint256 value) = _terms(c.parentId, extra);
        vm.prank(who);
        if (own) reg.revealSubpage{value: value}(c.parentId, c.label, c.secret, price, feeToken);
        else reg.revealSubpageFor{value: value}(c.parentId, c.label, c.to, c.secret, price, feeToken);
        if (found != type(uint256).max) {
            pending[found] = pending[n - 1];
            pending.pop();
        }
    }

    // a claim, mostly by an account terms may pay, one owed ETH when there is one, else by one of the four, to
    // itself or to another address
    function claimProceeds(uint256 whoS, uint256 toS) external {
        whoS = _h(whoS, 4);
        toS = _h(toS, 5);
        vm.prank(whoS % 4 != 3 ? _owedAccount(whoS >> 2) : actors[(whoS >> 2) % 4]);
        reg.claimProceeds(toS % 4 == 0 ? address(0) : _to(toS >> 2));
    }

    // a claim by any of the four, mostly for an account terms may pay, one owed ETH when there is one, else for one
    // of the four. The account is worked out before the prank, since the view call in _owedAccount would use it up.
    function claimProceedsFor(uint256 whoS, uint256 aS) external {
        aS = _h(aS, 6);
        address account = aS % 4 != 3 ? _owedAccount(aS >> 2) : actors[(aS >> 2) % 4];
        vm.prank(actors[whoS % 4]);
        reg.claimProceedsFor(account);
    }
}

// The fuzzer drives the registrar through the handler above. The holders, the buyer and the stranger have also
// given the registrar an operator approval and an ERC20 allowance. No sequence may move a top level name, touch a
// live subpage, or leave ETH the ledger does not owe.
contract RegistrarInvariantTest is MinterBase {
    uint256 club;
    uint256 zoo;
    uint256 liveClub;
    uint256 liveZoo;
    RegistrarHandler h;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        zoo = _reg(bob, "zoo");
        vm.prank(alice);
        liveClub = nft.registerSubpageFor("live", club, carol);
        vm.prank(bob);
        liveZoo = nft.registerSubpageFor("live", zoo, carol);
        _setMinter(club, address(reg));
        _setMinter(zoo, address(reg));
        _configure(club, payout, address(0), 0, false);
        vm.prank(bob);
        reg.configure(zoo, payout, address(usd), 1, true, address(0), 0, false);
        address[4] memory who = [alice, bob, buyer, stranger];
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(who[i]);
            nft.setApprovalForAll(address(reg), true);
            usd.approve(address(reg), type(uint256).max);
            vm.stopPrank();
            usd.mint(who[i], 1e30);
        }
        h = new RegistrarHandler(nft, reg, usd, [club, zoo], who, [payout, alice, bob]);
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = RegistrarHandler.configure.selector;
        sels[1] = RegistrarHandler.disable.selector;
        sels[2] = RegistrarHandler.commitSubpage.selector;
        sels[3] = RegistrarHandler.registerSubpage.selector;
        sels[4] = RegistrarHandler.registerSubpageFor.selector;
        sels[5] = RegistrarHandler.revealSubpage.selector;
        sels[6] = RegistrarHandler.revealSubpageFor.selector;
        sels[7] = RegistrarHandler.claimProceeds.selector;
        sels[8] = RegistrarHandler.claimProceedsFor.selector;
        targetContract(address(h));
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sels}));
    }

    /// forge-config: default.invariant.fail-on-revert = false

    /// forge-config: deep.invariant.fail-on-revert = false
    function invariant_namesStay() public view {
        assertEq(nft.ownerOf(club), alice);
        assertEq(nft.ownerOf(zoo), bob);
        assertEq(nft.ownerOf(liveClub), carol);
        assertEq(nft.ownerOf(liveZoo), carol);
        assertEq(nft.balanceOf(address(reg)), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = false

    /// forge-config: deep.invariant.fail-on-revert = false
    function invariant_noUnownedEth() public view {
        assertEq(address(reg).balance, reg.proceedsOf(payout) + reg.proceedsOf(alice) + reg.proceedsOf(bob));
    }
}
