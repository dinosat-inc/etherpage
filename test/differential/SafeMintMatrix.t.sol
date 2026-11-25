// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {console} from "forge-std/Test.sol";
import {SafeMintBase} from "./SafeMintBase.sol";

// every build, every mint path, every recipient shape, sent by a third party and by the recipient itself
contract SafeMintMatrixTest is SafeMintBase {
    string[4] pname = ["reveal", "revealTrial", "registerSubpageFor", "registrar sale"];

    function test_matrix() public {
        uint256 mismatches;
        for (uint256 path; path < 4; ++path) {
            for (uint256 r; r < NREC; ++r) {
                for (uint256 m; m < 2; ++m) {
                    bool self = m == 1;
                    if (self && !_canAct(r)) continue;
                    string memory line = string.concat(pname[path], " | ", rname[r], self ? " | self" : " | third party");
                    for (uint256 v; v < 4; ++v) {
                        bytes4 got = _attempt(v, path, r, self);
                        bytes4 exp = _expect(v, path, r, self);
                        line = string.concat(line, " | ", vname[v], "=", _show(got));
                        if (got != exp) {
                            ++mismatches;
                            line = string.concat(line, " (expected ", _show(exp), ")");
                        }
                    }
                    console.log(line);
                }
            }
        }
        assertEq(mismatches, 0, "a build behaved other than expected");
    }
}
