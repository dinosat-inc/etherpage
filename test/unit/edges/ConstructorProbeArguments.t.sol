// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// a renderer whose render reverts with the arguments it was asked to draw
contract EchoCard {
    error Probed(string label, string parentLabel, bytes32 id, PageCard.Status status, uint256 expiry);

    function render(string memory label, string memory parentLabel, bytes32 id, PageCard.Status status, uint256 expiry)
        external
        pure
        returns (string memory)
    {
        revert Probed(label, parentLabel, id, status, expiry);
    }
}

// a renderer whose card is 100 bytes for the constructor's probe alone and 99 bytes for any other page
contract ExactProbeCard {
    function render(string memory label, string memory parentLabel, bytes32 id, PageCard.Status status, uint256 expiry)
        external
        pure
        returns (string memory)
    {
        bool probe = keccak256(bytes(label)) == keccak256("a") && bytes(parentLabel).length == 0 && id == bytes32(0)
            && status == PageCard.Status.Active && expiry == 0;
        return string(new bytes(probe ? 100 : 99));
    }
}

// The constructor probes the card of one page: an active top level page named a, with the zero id and expiry 0.
// The renderers of ConstructorProbeTest and PageNFTCoverageTest ignore their arguments, so they hold for any probe.
contract ConstructorProbeArgumentsTest is Test {
    // the probe asks for exactly that card: a renderer that reverts with its arguments fails the deployment with them
    function test_probeAsksForTheCardOfAnActiveTopLevelPageNamedA() public {
        EchoCard c = new EchoCard();
        bytes memory want = abi.encodeWithSelector(
            EchoCard.Probed.selector, string("a"), string(""), bytes32(0), PageCard.Status.Active, uint256(0)
        );
        try new PageNFT(PageCard(address(c))) returns (PageNFT) {
            fail("a renderer that reverts was accepted");
        } catch (bytes memory reason) {
            assertEq(reason, want, "the probe's arguments");
        }
    }

    // only that card decides the deployment: a renderer whose card is long enough for the probe alone is accepted
    function test_onlyTheProbedCardDecidesTheDeployment() public {
        ExactProbeCard c = new ExactProbeCard();
        try new PageNFT(PageCard(address(c))) returns (PageNFT n) {
            assertEq(address(n.card()), address(c), "bound to the card");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(PageNFT.InvalidRenderer.selector), "refused");
            fail("refused although the probed card is 100 bytes");
        }
    }
}
