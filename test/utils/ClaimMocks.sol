// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";

// A payout that holds names and makes any call through exec. While armed, each payment that arrives outside its
// armed calls makes every armed call in turn and records whether each went through and what came back. Its receive
// never reverts, so the payment itself always goes through.
contract ArmedPayout {
    address[] internal _targets;
    uint256[] internal _values;
    bytes[] internal _datas;
    bool[] internal _oks;
    bytes[] internal _rets;
    bool public armed;
    bool internal _inside;
    // payments its receive took, and those that arrived while it was making its armed calls
    uint256 public payments;
    uint256 public nested;

    function arm(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        delete _targets;
        delete _values;
        delete _datas;
        for (uint256 i; i < targets.length; ++i) {
            _targets.push(targets[i]);
            _values.push(values[i]);
            _datas.push(datas[i]);
        }
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    // what each armed call of the last armed payment returned
    function results() external view returns (bool[] memory oks, bytes[] memory rets) {
        return (_oks, _rets);
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        ++payments;
        if (_inside) {
            ++nested;
            return;
        }
        if (!armed) return;
        _inside = true;
        delete _oks;
        delete _rets;
        for (uint256 i; i < _targets.length; ++i) {
            (bool ok, bytes memory ret) = _targets[i].call{value: _values[i]}(_datas[i]);
            _oks.push(ok);
            _rets.push(ret);
        }
        _inside = false;
    }
}

// A payout whose receive reads the registrar while it is being paid: the proceeds of every watched account and
// the registrar's balance.
contract LedgerWatchPayout {
    SubpageRegistrar public immutable reg;
    address[] internal _watched;
    uint256[] internal _seen;
    uint256 public seenBalance;
    uint256 public seenValue;
    uint256 public payments;

    constructor(SubpageRegistrar r) {
        reg = r;
    }

    function watch(address[] calldata accounts) external {
        _watched = accounts;
    }

    function claim(address to) external returns (uint256) {
        return reg.claimProceeds(to);
    }

    // proceedsOf of each watched account, in the order given to watch, as the last payment saw them
    function seen() external view returns (uint256[] memory) {
        return _seen;
    }

    receive() external payable {
        ++payments;
        seenValue = msg.value;
        delete _seen;
        for (uint256 i; i < _watched.length; ++i) _seen.push(reg.proceedsOf(_watched[i]));
        seenBalance = address(reg).balance;
    }
}

// A buyer, a subpage recipient and a payout in one. Armed at one site, the receiver hook or the receive that
// takes a buyer's excess back, it makes one call there and records the result, then carries on or, when told to
// and the call failed, reverts with what the call returned.
contract SaleHookAccount {
    uint8 public constant AT_RECEIVER = 1;
    uint8 public constant AT_REFUND = 2;

    uint8 public site;
    address public target;
    bytes public data;
    bool public bubble;
    bool public called;
    bool public ok;
    bytes public ret;

    function arm(uint8 s, address t, bytes calldata d, bool b) external {
        site = s;
        target = t;
        data = d;
        bubble = b;
        called = false;
        ok = false;
        delete ret;
    }

    function buy(address reg, bytes calldata d, uint256 value) external returns (bytes memory r) {
        bool s;
        (s, r) = reg.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    function _hook(uint8 s) internal {
        if (site != s || called) return;
        called = true;
        (bool success, bytes memory r) = target.call(data);
        ok = success;
        ret = r;
        if (!success && bubble) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _hook(AT_RECEIVER);
        return this.onERC721Received.selector;
    }

    receive() external payable {
        _hook(AT_REFUND);
    }
}

// An ERC20 whose first transferFrom after arm makes the armed call and records the result, then moves the tokens
// or, when told to and the call failed, reverts with what the call returned
contract SaleHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public data;
    bool public bubble;
    bool public called;
    bool public ok;
    bytes public ret;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function arm(address t, bytes calldata d, bool b) external {
        target = t;
        data = d;
        bubble = b;
        called = false;
        ok = false;
        delete ret;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (target != address(0) && !called) {
            called = true;
            (bool s, bytes memory r) = target.call(data);
            ok = s;
            ret = r;
            if (!s && bubble) {
                assembly ("memory-safe") {
                    revert(add(r, 0x20), mload(r))
                }
            }
        }
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// An ERC20 that burns whatever is sent to its own address
contract SelfBurnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        if (to == address(this)) totalSupply -= amount;
        else balanceOf[to] += amount;
        return true;
    }
}
