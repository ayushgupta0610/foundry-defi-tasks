// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";

// Whatever config you want to use
struct NetworkConfig {
    address usdcAddress;
    address wethAddress;
    address aavePoolAddress;
    address wrappedTokenGatewayAddress;
    address aavePriceOracleAddress;
    address quoterAddress;
    address swapRouterAddress;
}

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
            wrappedTokenGatewayAddress: 0xD322A49006FC828F9B5B37Ab215F99B4E5caB19C,
            aavePriceOracleAddress: 0x54586bE62E3c3580375aE3723C145253060Ca0C2,
            quoterAddress: 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6,
            swapRouterAddress: 0xE592427A0AEce92De3Edee1F18E0157C05861564
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