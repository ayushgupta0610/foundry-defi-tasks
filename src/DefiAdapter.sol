// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Errors.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IComptroller} from "./interfaces/IComptroller.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DefiAdapter {

    using SafeERC20 for IERC20;

    ILendingPool private lendingPool;
    IUniswapV2Router02 private routerV2;
    IComptroller private comptroller;

    event Borrowed();
    event Deposited();
    event FlashLoaned();
    event Lent();

    // Polygon Mainnet Addresses
    // aaveLendingPool: 0x8dff5e27ea6b7ac08ebfdf9eb090f32ee9a30fcf
    // uniswapRouter: 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff
    // compound: 0x2F9E3953b2Ef89fA265f2a32ed9F80D00229125B
    constructor(address aaveLendingPool, address uniswapRouter, address compoundController) {
        // Store aave and compound protocol addresses
        lendingPool = ILendingPool(aaveLendingPool);
        routerV2 = IUniswapV2Router02(uniswapRouter);
        comptroller = IComptroller(compoundController);
    }

    // Approve this contract for USDC by the user for 'amount' value
    // Use 0 for no referral code.
    function depositInAave(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        // Validate asset? Should be only USDC in our case
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(lendingPool), amount);
        lendingPool.deposit(
            asset,
            amount,
            onBehalfOf,
            referralCode
        );
    }

    // onBehalfOf must have enough collateral via deposit() on Aave
    // the type of borrow debt. Stable: 1, Variable: 2
    // Use 0 for no referral code.
    function borrowFromAave(address asset, uint256 amount, address onBehalfOf, uint16 referralCode, uint256 interestRateMode) external {
        // Validate asset? Should be only USDC in our case
        lendingPool.borrow(
            asset,
            amount,
            interestRateMode,
            referralCode,
            onBehalfOf
        );
        IERC20(asset).safeTransfer(onBehalfOf, amount);
    }

    // Create a function to get how much can the user borrow asset by providing 'amount' of assetDeposited - can be put as a check for revert in the above function

    // The user should have approved this contract on assetIn for 'amountIn' value
    function swaptoETHFromUniswap(address assetIn, uint256 amountIn, address assetOut, uint256 amountOutMin, address onBehalfOf, uint256 deadline) external {
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(assetIn).approve(address(routerV2), amountIn);
        address[] memory path = new address[](2);
        path[0] = assetIn;
        path[1] = assetOut;
        uint[] memory amounts = routerV2.swapExactTokensForETH(amountIn, amountOutMin, path, onBehalfOf, deadline);
        (bool success, ) = onBehalfOf.call{ value: amounts[amounts.length - 1] }("");
        if (!success) {
            revert TransferFailed();
        }
    } 

    function depositToCompound() external {
        
    }

    receive() external payable {

    }

}