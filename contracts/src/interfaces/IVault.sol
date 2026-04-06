// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;

    function balances(address account) external view returns (uint256);
    function lockedMargin(address account) external view returns (uint256);
    function orderMargin(address account) external view returns (uint256);
    function insuranceFund() external view returns (uint256);
    function totalDeposits() external view returns (uint256);

    function lockMargin(address account, uint256 amount) external;
    function unlockMargin(address account, uint256 amount) external;
    function lockOrderMargin(address account, uint256 amount) external;
    function unlockOrderMargin(address account, uint256 amount) external;
    function transferToInsuranceFund(uint256 amount) external;
    function drawFromInsuranceFund(uint256 amount) external;
    function realizePnl(address account, int256 pnl) external returns (uint256 deficit);

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event MarginLocked(address indexed account, uint256 amount);
    event MarginUnlocked(address indexed account, uint256 amount);
    event OrderMarginLocked(address indexed account, uint256 amount);
    event OrderMarginUnlocked(address indexed account, uint256 amount);
    event PnlRealized(address indexed account, int256 amount);
}
