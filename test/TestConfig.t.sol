// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Test, console } from "forge-std/Test.sol";

// Whatever config you want to use
struct NetworkConfig {
    address usdcAddress;
    address wethAddress;
    address priceOracleAddress;
    address lendingPoolAddress;
    address routerV2Address;
    address cometAddress;
}

contract TestConfig is Test {
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 137) {
            activeNetworkConfig = getPolygonMainnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilPolygonConfig();
        }
    }

    function getPolygonMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            usdcAddress: 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174,
            wethAddress: 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619,
            priceOracleAddress: 0x0229F777B0fAb107F9591a41d5F02E4e98dB6f2d,
            lendingPoolAddress: 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf,
            routerV2Address: 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff,
            cometAddress: 0xF25212E676D1F7F89Cd72fFEe66158f541246445
        });
    }

    function getOrCreateAnvilPolygonConfig() public returns (NetworkConfig memory) {
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