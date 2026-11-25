// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";

// For the differentials whose world B is src and whose world A has no profile writer rule: the rule
// adds writer events to B's logs and may hide B's text and website. ProfileDifferentialTest checks the
// exact rule; here B's writer events are checked for shape and removed, and B's profile answers must
// be A's answer or empty.
library ProfileLogs {
    bytes32 internal constant T_PWC = keccak256("ProfileWriterChanged(bytes32,address,bool)");
    bytes32 internal constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    bytes32 internal constant T_SITE = keccak256("ContenthashChanged(bytes32,bytes)");

    // B's logs without the writer events; each must be a fresh start right before a text or website
    // event of the same node from the same contract
    function strip(Vm.Log[] memory lb) internal pure returns (Vm.Log[] memory out) {
        out = new Vm.Log[](lb.length);
        uint256 n;
        for (uint256 i; i < lb.length; ++i) {
            Vm.Log memory l = lb[i];
            if (l.topics.length > 0 && l.topics[0] == T_PWC) {
                require(l.topics.length == 2 && i + 1 < lb.length, "writer event shape");
                (, bool fresh) = abi.decode(l.data, (address, bool));
                require(fresh, "only fresh writer events here");
                Vm.Log memory nx = lb[i + 1];
                require(
                    nx.emitter == l.emitter && nx.topics.length >= 2 && (nx.topics[0] == T_TEXT || nx.topics[0] == T_SITE)
                        && nx.topics[1] == l.topics[1],
                    "a writer event not followed by a write of the same node"
                );
                continue;
            }
            out[n++] = l;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // same when B's answer is A's, hidden when it differs and B's is empty
    // (ABI encoded text or contenthash)
    function subset(bytes memory ra, bytes memory rb) internal pure returns (bool same, bool hidden) {
        same = keccak256(ra) == keccak256(rb);
        hidden = !same && keccak256(rb) == keccak256(abi.encode(""));
    }
}
