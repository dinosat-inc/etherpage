// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

interface INameLookup {
    function computeNamehash(string calldata fullName) external pure returns (bytes32);
    function addr(bytes32 node) external view returns (address);
    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory);
}

// pays a name the way a wallet does: look the name up, refuse when there is no address
contract NameWallet {
    function payOP(INameLookup n, string calldata fullName) external payable returns (address to) {
        to = n.addr(n.computeNamehash(fullName));
        require(to != address(0), "no address for this name");
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "send failed");
    }

    function payEth(INameLookup n, string calldata fullName) external payable returns (address to) {
        bytes memory b = n.addr(n.computeNamehash(fullName), 60);
        require(b.length == 20, "no address for this name");
        to = address(bytes20(b));
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "send failed");
    }
}
