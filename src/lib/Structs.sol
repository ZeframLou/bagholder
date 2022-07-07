// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";

/// @param nft the NFT to incentivize
/// @param rewardToken the token used to reward stakers
/// @param startTime the Unix timestamp (in seconds) when the incentive begins
/// @param endTime the Unix timestamp (in seconds) when the incentive ends
/// @param bondAmount the amount of ETH a staker needs to put up as bond, should be
/// enough to cover the gas cost of calling slashPaperHand() and then some
struct IncentiveKey {
    ERC721 nft;
    ERC20 rewardToken;
    uint256 startTime;
    uint256 endTime;
    uint256 bondAmount;
}

/// @param totalRewardUnclaimed the amount of unclaimed reward tokens accrued to the staker
/// @param rewardPerTokenStored the rewardPerToken value when the staker info was last updated
/// @param numberOfStakedTokens the number of NFTs staked by the staker in the specified incentive
struct StakerInfo {
    uint256 totalRewardUnclaimed;
    uint128 rewardPerTokenStored;
    uint64 numberOfStakedTokens;
}

/// @param rewardRatePerSecond the amount of reward tokens (in wei) given to stakers per second
/// @param rewardPerTokenStored the rewardPerToken value when the incentive info was last updated
/// @param numberOfStakedTokens the number of NFTs staked in the specified incentive
/// @param lastUpdateTime the Unix timestamp (in seconds) when the incentive info was last updated,
/// or the incentive's endTime if the time of the last update was after endTime
struct IncentiveInfo {
    uint256 rewardRatePerSecond;
    uint128 rewardPerTokenStored;
    uint64 numberOfStakedTokens;
    uint64 lastUpdateTime;
}