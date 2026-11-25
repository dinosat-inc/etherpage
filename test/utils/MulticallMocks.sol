// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// a wallet contract whose receive and receiver hook each make one armed call and record the result
contract Reenterer {
    address public target;
    bytes public onEth;
    bytes public onNft;
    bool public ethOk;
    bytes public ethRet;
    bool public nftOk;
    bytes public nftRet;
    uint256 public ethCalls;
    uint256 public nftCalls;
    bool public bubble;

    function arm(address t, bytes calldata eth, bytes calldata nft, bool b) external {
        target = t;
        onEth = eth;
        onNft = nft;
        bubble = b;
        ethCalls = 0;
        nftCalls = 0;
    }

    function exec(address to, uint256 value, bytes calldata d) external returns (bytes memory) {
        (bool s, bytes memory r) = to.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    receive() external payable {
        ++ethCalls;
        if (onEth.length == 0 || ethCalls > 1) return;
        (ethOk, ethRet) = target.call(onEth);
        if (!ethOk && bubble) {
            bytes memory r = ethRet;
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    address public lastOperator;
    address public lastFrom;

    function onERC721Received(address operator, address from, uint256, bytes calldata) external returns (bytes4) {
        ++nftCalls;
        lastOperator = operator;
        lastFrom = from;
        if (onNft.length != 0 && nftCalls == 1) {
            (nftOk, nftRet) = target.call(onNft);
            if (!nftOk && bubble) {
                bytes memory r = nftRet;
                assembly ("memory-safe") {
                    revert(add(r, 0x20), mload(r))
                }
            }
        }
        return this.onERC721Received.selector;
    }
}

// a receiver that refuses every name with a long revert reason
contract LoudRefuser {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("this wallet refuses every name, and says so in a reason longer than thirty two bytes");
    }
}
