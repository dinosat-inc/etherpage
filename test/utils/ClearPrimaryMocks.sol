// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

interface INft {
    function safeTransferFrom(address from, address to, uint256 id) external payable;
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external payable;
    function transferFrom(address from, address to, uint256 id) external payable;
    function primaryPage(address a) external view returns (uint256);
    function reverseResolve(address a) external view returns (string memory);
    function setAddr(uint256 id, address a) external;
    function setPrimaryPage(uint256 id) external;
}

// a marketplace that settles a sale as an approved operator, the way OpenSea does
contract Market {
    function settle(address nft, address from, address to, uint256 id, bool safe) external {
        if (safe) INft(nft).safeTransferFrom(from, to, id, hex"5ea0");
        else INft(nft).transferFrom(from, to, id);
    }
}

// a buyer contract that looks at the seller's display name from inside its receiver hook and can
// point the name back at the seller there
contract Probe {
    uint256 public seenPointer = type(uint256).max;
    string public seenReverse;
    bool public revive;
    address public nft;

    function arm(address n, bool r) external {
        nft = n;
        revive = r;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        seenPointer = INft(nft).primaryPage(from);
        seenReverse = INft(nft).reverseResolve(from);
        if (revive) INft(nft).setAddr(id, from);
        return this.onERC721Received.selector;
    }

    function exec(address to, bytes calldata d) external returns (bytes memory) {
        (bool s, bytes memory r) = to.call(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }
}
