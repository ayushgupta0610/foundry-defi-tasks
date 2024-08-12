// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {NetworkConfig} from "../src/ethereum/NetworkConfig.sol";

contract TestConfigEthereum is Test {
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 1) {
            activeNetworkConfig = getEthMainnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getEthMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            usdcAddress: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            wethAddress: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            aavePoolAddress: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
            wrappedTokenGatewayAddress: 0x893411580e590D62dDBca8a703d61Cc4A8c7b2b9,
            creditDelegationToken: 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE,
            aavePriceOracleAddress: 0x54586bE62E3c3580375aE3723C145253060Ca0C2,
            quoterAddress: 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6,
            swapRouterAddress: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            cometAddress: 0xc3d688B66703497DAA19211EEdff47f25384cdc3,
            positionManagerAddress: 0xC36442b4a4522E871399CD717aBDD847Ab11FE88
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // if(activeNetworkConfig.wethUsdPriceFeed != address(0)) {
        //     return activeNetworkConfig;
        // }

        // return NetworkConfig({
        //     wethUsdPriceFeed: address(ethUsdPriceFeed),
        //     wbtcUsdPriceFeed: address(btcUsdPriceFeed),
        //     weth: address(wethMock),
        //     wbtc: address(wbtcMock),
        //     deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        // });
    }
}
