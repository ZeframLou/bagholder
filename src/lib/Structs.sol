// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";

struct IncentiveKey {
    ERC721 nft;
    ERC20 rewardToken;
    uint256 startTime;
    uint256 endTime;
    address refundee;
    uint256 bondAmount;
}

struct Stake {
    address staker;
}

struct StakerInfo {
    uint256 totalRewardUnclaimed;
    uint128 rewardPerTokenClaimed;
    uint64 numberOfStakedTokens;
}

struct IncentiveInfo {
    uint256 rewardRatePerSecond;
    uint128 rewardPerTokenStored;
    uint64 numberOfStakedTokens;
    uint64 lastUpdateTime;
}