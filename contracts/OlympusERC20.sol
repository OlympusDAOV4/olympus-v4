// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.26;

import {Ownable} from "./Ownable.sol";

import "./libraries/SafeMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IOHM.sol";
import "./interfaces/IERC20Permit.sol";

import "./types/ERC20Permit.sol";
import "./types/OlympusAccessControlled.sol";

contract Olympus is Ownable {
    string public constant name = "Olympus";
    string public constant symbol = "OHM";
    uint8 public constant decimals = 18;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant MAX_WALLET = TOTAL_SUPPLY * 2 / 100;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(address => bool) public isExempt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ExemptSet(address indexed account, bool exempt);

    error MaxWalletExceeded();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        isExempt[msg.sender] = true;
        isExempt[address(0)] = true;
        isExempt[POOL_MANAGER] = true;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /* ---------- Admin ---------- */

    function setExempt(address account, bool exempt) external onlyOwner {
        isExempt[account] = exempt;
        emit ExemptSet(account, exempt);
    }

    /* ---------- ERC-20 ---------- */

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - value; }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        uint256 fromBal = balanceOf[from];
        if (fromBal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - value;
            balanceOf[to] += value;
        }
        if (!isExempt[to] && balanceOf[to] > MAX_WALLET) revert MaxWalletExceeded();
        emit Transfer(from, to, value);
    }
}
