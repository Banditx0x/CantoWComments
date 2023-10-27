// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.19;

import "../libraries/SafeCast.sol";
import "./PositionRegistrar.sol";
import "./StorageLayout.sol";
import "./PoolRegistry.sol";

/* @title Liquidity mining mixin
 * @notice Contains the functions related to liquidity mining claiming. */
contract LiquidityMining is PositionRegistrar {
    uint256 constant WEEK = 604800; // Week in seconds 604800

    /// @notice Initialize the tick tracking for the first tick of a pool
    //initiatTickTrackeing for a pre-exisiting pool
    function initTickTracking(bytes32 poolIdx, int24 tick) internal {
        //TickTracking  of block.timestamp
        //initializes TickTracking to block.timestamp for enterTimestamp and 0 for exitTimestamp
        StorageLayout.TickTracking memory tickTrackingData = StorageLayout.TickTracking(uint32(block.timestamp), 0);
        //@audit is there unnecsary iteration over ticks in the same block?
        tickTracking_[poolIdx][tick].push(tickTrackingData);
    }

    /// @notice Keeps track of the tick crossings
    /// @dev Needs to be called whenever a tick is crossed

    //whenever a tick is crossed in a liquidity pool
    function crossTicks(
        bytes32 poolIdx,
        int24 exitTick,
        int24 entryTick
    ) internal {
        //why tickTracking_length
        //tickTracking_map-s from pool to tick -> array of tickTrackingData
        uint256 numElementsExit = tickTracking_[poolIdx][exitTick].length;
        //last exit for that tick is current time
        //last element of tick tracking for the pool's exit tick is replaced by or set to block.timestamp
        tickTracking_[poolIdx][exitTick][numElementsExit - 1].exitTimestamp = uint32(block.timestamp);
        //part of that tickTrackingData is exitTimestamp
        //the last exitTimeStamp is current block
        //
        StorageLayout.TickTracking memory tickTrackingData = StorageLayout.TickTracking(uint32(block.timestamp), 0);
        //add a new tickTrackingData to tickTracking array of entryTick.
        tickTracking_[poolIdx][entryTick].push(tickTrackingData);
    }

    /// @notice Keeps track of the global in-range time-weighted concentrated liquidity per week
    /// @dev Needs to be called whenever the concentrated liquidity is modified (tick crossed, positions changed)

    //accure the change in liquidity.
    function accrueConcentratedGlobalTimeWeightedLiquidity(
        bytes32 poolIdx,
        CurveMath.CurveState memory curve
    ) internal {
        //poolId has time concentratedLiquidity was last set
        uint32 lastAccrued = timeWeightedWeeklyGlobalConcLiquidityLastSet_[
            poolIdx
        ];
        // Only set time on first call
        if (lastAccrued != 0) {
            //@ audit is this the concentrated liquidity at the current point of the curve?
            uint256 liquidity = curve.concLiq_;
            uint32 time = lastAccrued;
            while (time < block.timestamp) {

                uint32 currWeek = uint32((time / WEEK) * WEEK);
                uint32 nextWeek = uint32(((time + WEEK) / WEEK) * WEEK);
                uint32 dt = uint32(
                    nextWeek < block.timestamp
                        ? nextWeek - time
                        : block.timestamp - time
                );
                //time delta * liquidity
                timeWeightedWeeklyGlobalConcLiquidity_[poolIdx][currWeek] += dt * liquidity;
                time += dt;
            }
        }
        timeWeightedWeeklyGlobalConcLiquidityLastSet_[poolIdx] = uint32(
            block.timestamp
        );
    }

    /// @notice Accrues the in-range time-weighted concentrated liquidity for a position by going over the tick entry / exit history
    /// @dev Needs to be called whenever a position is modified

    //goes through the time weighted concentrated liquidity

    //accrueConcentratedPositionTimeWeightedLiquidity
    //probabally get the liquidity of a position adjusted for time and concentration
    function accrueConcentratedPositionTimeWeightedLiquidity(
        address payable owner,
        bytes32 poolIdx,
        int24 lowerTick,
        int24 upperTick
    ) internal {
        //returns the position associated with the owner, pool id, and tick range
        RangePosition72 storage pos = lookupPosition(
            owner,
            poolIdx,
            lowerTick,
            upperTick
        );
        //encodes this to a "posKey"
        //this ABIencode packs it. Is it possible for a collision?
        bytes32 posKey = encodePosKey(owner, poolIdx, lowerTick, upperTick);
        uint32 lastAccrued = timeWeightedWeeklyPositionConcLiquidityLastSet_[
            poolIdx
        ][posKey];
        // Only set time on first call
        //if has been accrued before...
        if (lastAccrued != 0) {
            //amount of liquidity
            uint256 liquidity = pos.liquidity_;
            //for the position, each tick 10 higher than lower tick and 10 lower than upper tick
            (int24 i = lowerTick + 10; i <= upperTick - 10; ++i) {
                //get the tickTrackingIndex accrued up to
                uint32 tickTrackingIndex = tickTrackingIndexAccruedUpTo_[poolIdx][posKey][i];
                //store tickTrackingIndex as origIndex. This suggests that tickTrackingIndex will change later in this function
                uint32 origIndex = tickTrackingIndex;
                //number of times this tick was checkpointed
                uint32 numTickTracking = uint32(tickTracking_[poolIdx][i].length);
                uint32 time = lastAccrued;
                // Loop through all in-range time spans for the tick or up to the current time (if it is still in range)
                while (time < block.timestamp && tickTrackingIndex < numTickTracking) {
                    //memory not storage
                    TickTracking memory tickTracking = tickTracking_[poolIdx][i][tickTrackingIndex]
                    //removes remainder time from week
                    //time rounds down to the closest week
                    uint32 currWeek = uint32((time / WEEK) * WEEK);
                    uint32 nextWeek = uint32(((time + WEEK) / WEEK) * WEEK);
                    //time delta?
                    uint32 dt = uint32(
                        //if nextWeek hasnt completed yet, then return nextWeek - last accrued
                        //otherwise do block.timestamp - time
                        nextWeek < block.timestamp
                            ? nextWeek - time
                            : block.timestamp - time
                    );
                    uint32 tickActiveStart; // Timestamp to use for the liquidity addition
                    uint32 tickActiveEnd;
                    if (tickTracking.enterTimestamp < nextWeek) {
                        // Tick was active before next week, need to add the liquidity
                        if (tickTracking.enterTimestamp < time) {
                            // Tick was already active when last claim happened, only accrue from last claim timestamp
                            tickActiveStart = time;
                        } else {
                            // Tick has become active this week
                            tickActiveStart = tickTracking.enterTimestamp;
                        }
                        if (tickTracking.exitTimestamp == 0) {
                            // Tick still active, do not increase index because we need to continue from here
                            tickActiveEnd = uint32(nextWeek < block.timestamp ? nextWeek : block.timestamp);
                        } else {
                            // Tick is no longer active
                            if (tickTracking.exitTimestamp < nextWeek) {
                                // Exit was in this week, continue with next tick
                                tickActiveEnd = tickTracking.exitTimestamp;
                                tickTrackingIndex++;
                                //@audit dt?
                                dt = tickActiveEnd - tickActiveStart;
                            } else {
                                // Exit was in next week, we need to consider the current tick there (i.e. not increase the index)
                                tickActiveEnd = nextWeek;
                            }
                        }
                        //key equation: time the tick was active * amount of liquidity
                        //@audit: liquidity does not take concentration into account
                        timeWeightedWeeklyPositionInRangeConcLiquidity_[poolIdx][posKey][currWeek][i] +=
                            (tickActiveEnd - tickActiveStart) * liquidity;
                    }
                    //add time-delta to time
                    time += dt;
                }
                //if the new tickTrackingIndex isnt original index:
                if (tickTrackingIndex != origIndex) {
                    //accrued up to the new tickTrackingIndex
                    tickTrackingIndexAccruedUpTo_[poolIdx][posKey][i] = tickTrackingIndex;
                }
            }
        //if has hasn't been accrued at least once before...
        } else {
            //for every tick that is 10 higher than the lowest tick up to 10 lower than the highest tick
            for (int24 i = lowerTick + 10; i <= upperTick - 10; ++i) {
                //numTickTracking = how many times: tickTracking of PoolId and tick
                uint32 numTickTracking = uint32(tickTracking_[poolIdx][i].length);
                if (numTickTracking > 0) {
                    //if last tick hasn't been exited yet:
                    if (tickTracking_[poolIdx][i][numTickTracking - 1].exitTimestamp == 0) {
                        // Tick currently active
                        //tick tracking index of tick and posKey has == this index of tickTracking
                        tickTrackingIndexAccruedUpTo_[poolIdx][posKey][i] = numTickTracking - 1;
                    } else {
                        //else accured up to length
                        tickTrackingIndexAccruedUpTo_[poolIdx][posKey][i] = numTickTracking;
                    }
                }
            }
        }

        //timeWeightedLConcLiquidty of the position and Id was last set at this block.timestamp. 
        timeWeightedWeeklyPositionConcLiquidityLastSet_[poolIdx][
            posKey
        ] = uint32(block.timestamp);
    }

    //claim rewards
    function claimConcentratedRewards(
        address payable owner,
        bytes32 poolIdx,
        int24 lowerTick,
        int24 upperTick,
        uint32[] memory weeksToClaim
    ) internal {
        //first accrue position time weighted liquidity
        //accrue position liquidity then global
        accrueConcentratedPositionTimeWeightedLiquidity(
            owner,
            poolIdx,
            lowerTick,
            upperTick
        );
        CurveMath.CurveState memory curve = curves_[poolIdx];
        // Need to do a global accrual in case the current tick was already in range for a long time without any modifications that triggered an accrual
        accrueConcentratedGlobalTimeWeightedLiquidity(poolIdx, curve);
        //position key based on ticks
        bytes32 posKey = encodePosKey(owner, poolIdx, lowerTick, upperTick);
        uint256 rewardsToSend;
        //iterate over weeks
        for (uint256 i; i < weeksToClaim.length; ++i) {
            uint32 week = weeksToClaim[i];
            require(week + WEEK < block.timestamp, "Week not over yet");
            //require rewards havent been claimed
            require(
                !concLiquidityRewardsClaimed_[poolIdx][posKey][week],
                "Already claimed"
            );
            uint256 overallInRangeLiquidity = timeWeightedWeeklyGlobalConcLiquidity_[poolIdx][week];
            if (overallInRangeLiquidity > 0) {
                uint256 inRangeLiquidityOfPosition;
                for (int24 j = lowerTick + 10; j <= upperTick - 10; ++j) {
                    //@audit in range concLiquidity
                    inRangeLiquidityOfPosition += timeWeightedWeeklyPositionInRangeConcLiquidity_[poolIdx][posKey][week][j];
                }
                // Percentage of this weeks overall in range liquidity that was provided by the user times the overall weekly rewards
                rewardsToSend += inRangeLiquidityOfPosition * concRewardPerWeek_[poolIdx][week] / overallInRangeLiquidity;
            }
            concLiquidityRewardsClaimed_[poolIdx][posKey][week] = true;
        }
        if (rewardsToSend > 0) {
            (bool sent, ) = owner.call{value: rewardsToSend}("");
            require(sent, "Sending rewards failed");
        }
    }
    

    //what is ambient liquidity?
    function accrueAmbientGlobalTimeWeightedLiquidity(
        bytes32 poolIdx,
        CurveMath.CurveState memory curve
    ) internal {
        uint32 lastAccrued = timeWeightedWeeklyGlobalAmbLiquidityLastSet_[poolIdx];
        // Only set time on first call
        if (lastAccrued != 0) {
            uint256 liquidity = curve.ambientSeeds_;
            uint32 time = lastAccrued;
            while (time < block.timestamp) {
                uint32 currWeek = uint32((time / WEEK) * WEEK);
                uint32 nextWeek = uint32(((time + WEEK) / WEEK) * WEEK);
                uint32 dt = uint32(
                    nextWeek < block.timestamp
                        ? nextWeek - time
                        : block.timestamp - time
                );
                timeWeightedWeeklyGlobalAmbLiquidity_[poolIdx][currWeek] += dt * liquidity;
                time += dt;
            }
        }
        timeWeightedWeeklyGlobalAmbLiquidityLastSet_[poolIdx] = uint32(
            block.timestamp
        );
    }

    //what is ambient?
    function accrueAmbientPositionTimeWeightedLiquidity(
        address payable owner,
        bytes32 poolIdx
    ) internal {
        bytes32 posKey = encodePosKey(owner, poolIdx);
        uint32 lastAccrued = timeWeightedWeeklyPositionAmbLiquidityLastSet_[
            poolIdx
        ][posKey];
        // Only init time on first call
        if (lastAccrued != 0) {
            AmbientPosition storage pos = lookupPosition(owner, poolIdx);
            uint256 liquidity = pos.seeds_;
            uint32 time = lastAccrued;
            while (time < block.timestamp) {
                uint32 currWeek = uint32((time / WEEK) * WEEK);
                uint32 nextWeek = uint32(((time + WEEK) / WEEK) * WEEK);
                uint32 dt = uint32(
                    nextWeek < block.timestamp
                        ? nextWeek - time
                        : block.timestamp - time
                );
                timeWeightedWeeklyPositionAmbLiquidity_[poolIdx][posKey][
                    currWeek
                ] += dt * liquidity;
                time += dt;
            }
        }
        timeWeightedWeeklyPositionAmbLiquidityLastSet_[poolIdx][
            posKey
        ] = uint32(block.timestamp);
    }

    //what are ambient rewards?
    function claimAmbientRewards(
        address owner,
        bytes32 poolIdx,
        uint32[] memory weeksToClaim
    ) internal {
        CurveMath.CurveState memory curve = curves_[poolIdx];
        accrueAmbientPositionTimeWeightedLiquidity(payable(owner), poolIdx);
        accrueAmbientGlobalTimeWeightedLiquidity(poolIdx, curve);
        bytes32 posKey = encodePosKey(owner, poolIdx);
        uint256 rewardsToSend;
        for (uint256 i; i < weeksToClaim.length; ++i) {
            uint32 week = weeksToClaim[i];
            require(week + WEEK < block.timestamp, "Week not over yet");
            require(
                !ambLiquidityRewardsClaimed_[poolIdx][posKey][week],
                "Already claimed"
            );
            uint256 overallTimeWeightedLiquidity = timeWeightedWeeklyGlobalAmbLiquidity_[
                    poolIdx
                ][week];
            if (overallTimeWeightedLiquidity > 0) {
                uint256 rewardsForWeek = (timeWeightedWeeklyPositionAmbLiquidity_[
                    poolIdx
                ][posKey][week] * ambRewardPerWeek_[poolIdx][week]) /
                    overallTimeWeightedLiquidity;
                rewardsToSend += rewardsForWeek;
            }
            ambLiquidityRewardsClaimed_[poolIdx][posKey][week] = true;
        }
        if (rewardsToSend > 0) {
            (bool sent, ) = owner.call{value: rewardsToSend}("");
            require(sent, "Sending rewards failed");
        }
    }
}
