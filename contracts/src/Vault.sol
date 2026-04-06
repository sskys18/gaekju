// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IVault } from "./interfaces/IVault.sol";

contract Vault is IVault, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AUTHORIZED_ROLE = keccak256("AUTHORIZED_ROLE");

    /// @dev USDC uses 6 decimals; internal accounting uses 18. Scale factor = 1e12.
    uint256 internal constant DECIMAL_SCALE = 1e12;

    error InsufficientBalance();
    error InsufficientLockedMargin();
    error InsufficientOrderMargin();
    error InsufficientInsuranceFund();
    error ZeroAmount();

    IERC20 public usdc;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lockedMargin;
    mapping(address => uint256) public orderMargin;
    uint256 public insuranceFund;
    uint256 public totalDeposits;

    uint256[50] private __gap;

    function initialize(address _usdc, address _admin) external initializer {
        usdc = IERC20(_usdc);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function grantAuthorized(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(AUTHORIZED_ROLE, account);
    }

    function deposit(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 internalAmount = usdcAmount * DECIMAL_SCALE;

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        balances[msg.sender] += internalAmount;
        totalDeposits += internalAmount;

        emit Deposited(msg.sender, internalAmount);
    }

    function withdraw(uint256 internalAmount) external nonReentrant {
        if (internalAmount == 0) revert ZeroAmount();
        if (balances[msg.sender] < internalAmount) revert InsufficientBalance();

        balances[msg.sender] -= internalAmount;
        totalDeposits -= internalAmount;
        uint256 usdcAmount = internalAmount / DECIMAL_SCALE;

        usdc.safeTransfer(msg.sender, usdcAmount);

        emit Withdrawn(msg.sender, internalAmount);
    }

    function lockMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        lockedMargin[account] += amount;
        emit MarginLocked(account, amount);
    }

    function unlockMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (lockedMargin[account] < amount) revert InsufficientLockedMargin();
        lockedMargin[account] -= amount;
        balances[account] += amount;
        emit MarginUnlocked(account, amount);
    }

    function lockOrderMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        orderMargin[account] += amount;
        emit OrderMarginLocked(account, amount);
    }

    function unlockOrderMargin(address account, uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (orderMargin[account] < amount) revert InsufficientOrderMargin();
        orderMargin[account] -= amount;
        balances[account] += amount;
        emit OrderMarginUnlocked(account, amount);
    }

    function transferToInsuranceFund(uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        insuranceFund += amount;
    }

    function drawFromInsuranceFund(uint256 amount) external onlyRole(AUTHORIZED_ROLE) {
        if (insuranceFund < amount) revert InsufficientInsuranceFund();
        insuranceFund -= amount;
    }

    function realizePnl(address account, int256 pnl) external onlyRole(AUTHORIZED_ROLE) returns (uint256 deficit) {
        if (pnl >= 0) {
            balances[account] += uint256(pnl);
            totalDeposits += uint256(pnl);
            emit PnlRealized(account, pnl);
            return 0;
        }
        uint256 loss = uint256(-pnl);
        // Exhaust free balance first
        if (loss <= balances[account]) {
            balances[account] -= loss;
            totalDeposits -= loss;
            emit PnlRealized(account, pnl);
            return 0;
        }
        uint256 fromBalance = balances[account];
        loss -= fromBalance;
        totalDeposits -= fromBalance;
        balances[account] = 0;
        // Then exhaust locked margin
        uint256 fromLocked = loss <= lockedMargin[account] ? loss : lockedMargin[account];
        lockedMargin[account] -= fromLocked;
        totalDeposits -= fromLocked;
        deficit = loss - fromLocked; // uncovered loss — caller must draw from insurance fund
        emit PnlRealized(account, pnl);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
