// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "../src/ethereum/rareskills/interfaces/INonfungiblePositionManager.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {FullMath} from "../src/ethereum/rareskills/libraries/FullMath.sol";
import {TickMath} from "../src/ethereum/rareskills/libraries/TickMath.sol";

contract AddLiquidityTest is Test {
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV3Factory public constant factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager public constant nonfungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant alice = address(0x1);
    uint24 public constant poolFee = 3000;

    IUniswapV3Pool public pool;
    uint256 public tokenId;

    uint256 public constant wethAmount = 1e18;
    uint256 public constant usdcAmount = 1000e6;

    function setUp() public {
        uint256 blockNumber = vm.envUint("BLOCK_NUMBER");
        string memory rpcUrl = vm.envString("ACTIVE_RPC_URL");
        vm.createSelectFork(rpcUrl, blockNumber);
        pool = IUniswapV3Pool(factory.getPool(address(USDC), address(WETH), poolFee));
        deal(address(USDC), alice, usdcAmount, true);
        deal(address(WETH), alice, wethAmount, false);
    }

    function testAddLiquidityAndEarnRewards() public {
        vm.startPrank(alice);

        // Approve tokens
        USDC.approve(address(nonfungiblePositionManager), usdcAmount);
        WETH.approve(address(nonfungiblePositionManager), wethAmount);

        // Add liquidity
        try nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: poolFee,
                tickLower: TickMath.MIN_TICK, //  -887220 Approx. price range: 1900 - 2100 USDC per ETH TickMath.MIN_TICK
                tickUpper: TickMath.MAX_TICK,  // TickMath.MAX_TICK
                amount0Desired: usdcAmount,
                amount1Desired: wethAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp + 10 hours
            })
        ) returns (
            uint256 tokenId_,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) {
            console.log("tokenId:", tokenId_);
            tokenId = tokenId_;
        } catch Error(string memory reason) {
            console.log("Error:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("We came here");
            console.logBytes(lowLevelData);
        }
        // tokenId = tokenId_;

        vm.stopPrank();

        // Simulate some swaps
        simulateSwaps();

        // Warp time forward
        vm.warp(block.timestamp + 7 days);

        // Check rewards
        checkRewards();
    }

    function simulateSwaps() internal {
        // Simulate a few swaps by other users
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        for (uint i = 0; i < 5; i++) {
            address swapper = address(uint160(uint256(keccak256(abi.encodePacked("swapper", i)))));
            deal(address(USDC), swapper, 10000e6);

            vm.startPrank(swapper);
            USDC.approve(address(pool), 10000e6);
            pool.swap(swapper, true, 10000e6, 1461446703485210103287273052203988822378723970341, "");
            vm.stopPrank();
        }
    }

    function checkRewards() internal {
        vm.startPrank(alice);

        // Collect fees
        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: alice,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        console.log("USDC rewards:", amount0);
        console.log("WETH rewards:", amount1);

        assertTrue(amount0 > 0 || amount1 > 0, "No rewards earned");

        vm.stopPrank();
    }
}