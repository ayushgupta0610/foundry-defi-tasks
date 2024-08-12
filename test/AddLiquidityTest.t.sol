// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import {Test, console } from "forge-std/Test.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
// import {TickMath} from "../src/ethereum/rareskills/libraries/TickMath.sol";
// import {FullMath} from "../src/ethereum/rareskills/libraries/FullMath.sol";
// import {INonfungiblePositionManager} from "../src/ethereum/rareskills/interfaces/INonfungiblePositionManager.sol";

// contract AddLiquidityUniswapV3 is Test {
//     INonfungiblePositionManager constant nonfungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
//     IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
//     address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

//     function setUp() public {
//         string memory rpcUrl = vm.envString("ACTIVE_RPC_URL");
//         vm.createSelectFork(rpcUrl);

//         uint256 amountUSDC = 1000 * 1e6;
//         uint256 amountETH = 1e18;
//         // Add liquidity
//         deal(address(USDC), address(this), amountUSDC, true);
//         deal(address(this), amountETH);
//     }

//     function testAddLiquidityToV3() external payable {
//         uint256 ethAmount = 1000 ether / 3000; // Approximately 0.3333 ETH
//         uint256 usdcAmount = 1000e6; // 1000 USDC

//         // require(msg.value >= ethAmount, "Insufficient ETH sent");
//         // require(USDC.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC balance");

//         // Approve USDC spending
//         USDC.approve(address(USDC), address(nonfungiblePositionManager), usdcAmount);

//         uint160 minValue = uint160(sqrt((2000 << 96) / 1e6));
//         uint160 maxValue = uint160(sqrt((4000 << 96) / 1e6));

//         // Calculate tick ranges
//         int24 tickLower = TickMath.getTickAtSqrtRatio(TickMath.getSqrtRatioAtTick(TickMath.getTickAtSqrtRatio(minValue)));
//         int24 tickUpper = TickMath.getTickAtSqrtRatio(TickMath.getSqrtRatioAtTick(TickMath.getTickAtSqrtRatio(maxValue)));

//         console.log("Tick Lower:", tickLower);
//         console.log("Tick Upper:", tickUpper);

//         // Add liquidity
//         INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
//             token0: WETH9,
//             token1: address(USDC),
//             fee: 3000, // 0.3% fee tier
//             tickLower: tickLower,
//             tickUpper: tickUpper,
//             amount0Desired: ethAmount,
//             amount1Desired: usdcAmount,
//             amount0Min: 0,
//             amount1Min: 0,
//             recipient: address(this),
//             deadline: block.timestamp + 15 minutes
//         });

//         try nonfungiblePositionManager.mint{value: ethAmount}(params) returns (
//             uint256 tokenId,
//             uint128 liquidity,
//             uint256 amount0,
//             uint256 amount1
//         ) {
//             console.log("NFT Token ID:", tokenId);
//             console.log("Liquidity added:", liquidity);
//             console.log("ETH added:", amount0);
//             console.log("USDC added:", amount1);
//         } catch Error(string memory reason) {
//             console.log("Error:", reason);
//             revert(reason);
//         } catch (bytes memory lowLevelData) {
//             console.logBytes(lowLevelData);
//             revert("Low level error");
//         }

//         // Refund any excess ETH
//         if (address(this).balance > 0) {
//             payable(msg.sender).transfer(address(this).balance);
//         }
//     }

//     function sqrt(uint256 x) internal pure returns (uint256 y) {
//         uint256 z = (x + 1) / 2;
//         y = x;
//         while (z < y) {
//             y = z;
//             z = (x / z + z) / 2;
//         }
//     }

//     receive() external payable {}
// }