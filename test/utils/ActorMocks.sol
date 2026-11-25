// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

interface IMc {
    function multicall(bytes[] calldata data) external returns (bytes[] memory);
}

// a contract account that runs a list of calls in one transaction and records each outcome
contract Actor {
    bool[] public oks;
    bytes[] public rets;

    function run(address[] calldata to, uint256[] calldata value, bytes[] calldata d) external payable {
        delete oks;
        delete rets;
        for (uint256 i; i < d.length; ++i) {
            (bool s, bytes memory r) = to[i].call{value: value[i]}(d[i]);
            oks.push(s);
            rets.push(r);
        }
    }

    function okAt(uint256 i) external view returns (bool) {
        return oks[i];
    }

    function retAt(uint256 i) external view returns (bytes memory) {
        return rets[i];
    }

    // hook: once armed, the next call to the receiver hook or to receive runs a queued list of calls and records
    // each outcome
    address[] public hookTo;
    bytes[] public hookData;
    bool[] public hookOk;
    bytes[] public hookRet;
    bool public hookArmed;

    function armHook(address[] calldata to, bytes[] calldata d) external {
        delete hookTo;
        delete hookData;
        delete hookOk;
        delete hookRet;
        for (uint256 i; i < d.length; ++i) {
            hookTo.push(to[i]);
            hookData.push(d[i]);
        }
        hookArmed = true;
    }

    function hookOkAt(uint256 i) external view returns (bool) {
        return hookOk[i];
    }

    function hookRetAt(uint256 i) external view returns (bytes memory) {
        return hookRet[i];
    }

    function _fire() internal {
        if (!hookArmed) return;
        hookArmed = false;
        for (uint256 i; i < hookData.length; ++i) {
            (bool s, bytes memory r) = hookTo[i].call(hookData[i]);
            hookOk.push(s);
            hookRet.push(r);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _fire();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        _fire();
    }
}

// refuses every name with a revert blob of a chosen size
contract Bomb {
    uint256 public size;

    function set(uint256 n) external {
        size = n;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 n = size;
        assembly ("memory-safe") {
            revert(0, n)
        }
    }
}

// burns all gas it is given in its hook
contract Burner {
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 i;
        while (gasleft() > 0) ++i;
        return bytes4(uint32(i));
    }
}

// a payer whose receive runs a queued list of calls once, during a refund; its NFT hook does nothing
contract RefundPayer {
    address[] public to;
    bytes[] public data;
    bool[] public oks;
    bytes[] public rets;
    bool public armed;

    function arm(address[] calldata t, bytes[] calldata d) external {
        delete to;
        delete data;
        delete oks;
        delete rets;
        for (uint256 i; i < d.length; ++i) {
            to.push(t[i]);
            data.push(d[i]);
        }
        armed = true;
    }

    function exec(address target, uint256 value, bytes calldata d) external returns (bytes memory) {
        (bool s, bytes memory r) = target.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    function okAt(uint256 i) external view returns (bool) {
        return oks[i];
    }

    function retAt(uint256 i) external view returns (bytes memory) {
        return rets[i];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        for (uint256 i; i < data.length; ++i) {
            (bool s, bytes memory r) = to[i].call(data[i]);
            oks.push(s);
            rets.push(r);
        }
    }
}
