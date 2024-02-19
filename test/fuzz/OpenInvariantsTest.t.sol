// // SPDX-License-Identifier: MIT


// // What are our invariants?? (what always must be like it is designed)

// // 1. Total supply of DSC should be less than total value of Collateral
// // 2. Getter view functions should never revert

// pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "forge-std/interfaces/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test{
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
        
//         // tell foundry what contract to use for tests
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all collateral in the protocol
//         // compare it to all the debt (dsc)

//         // total amount of DSC
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         //getting value of weth and wbtc
//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         // make sure it is always greater
//         assert(wethValue + wbtcValue >= totalSupply);
//     }

// }