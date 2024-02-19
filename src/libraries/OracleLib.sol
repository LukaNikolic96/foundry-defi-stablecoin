// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Luka Nikolic
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a prica is stale, the function will revert, and redner the DSCEngine unusable. - this is
 * by design
 * We want the DSCEngine to freeze if prices become stale.
 *
 * If Chainlink network explode and you have a lot of money locked in the protocol... well you are screwed
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 public constant TIMEOUT = 3 hours; // 10800s , their heart beat(time when they are updated usually) is 3600s
    // function that will check latest round data if it is stale or not
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        // we got all info from latestRoundData in aggregator
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // current block time stamp minus latest updated time so we know how much time has passed
        uint256 secondsSince = block.timestamp - updatedAt;
        // if time passes is more than our required time we revert with error
        if(secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
