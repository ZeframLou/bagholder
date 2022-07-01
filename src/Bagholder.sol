// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import "./lib/Math.sol";
import "./lib/Structs.sol";
import {FullMath} from "./lib/FullMath.sol";
import {IncentiveId} from "./lib/IncentiveId.sol";

contract Bagholder {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;
    using IncentiveId for IncentiveKey;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Bagholder__NotStaked();
    error Bagholder__NotNftOwner();
    error Bagholder__NotPaperHand();
    error Bagholder__AlreadyStaked();
    error Bagholder__BondInsufficient();
    error Bagholder__InvalidIncentiveKey();
    error Bagholder__IncentiveAlreadyExists();

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    uint256 internal constant PRECISION = 1e27;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    mapping(bytes32 => mapping(uint256 => Stake)) public stakes;
    mapping(bytes32 => mapping(address => StakerInfo)) public stakerInfos;
    mapping(bytes32 => IncentiveInfo) public incentiveInfos;

    /// -----------------------------------------------------------------------
    /// Public actions
    /// -----------------------------------------------------------------------

    function stake(IncentiveKey calldata key, uint256 nftId)
        external
        payable
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // check bond is sufficient
        if (msg.value < key.bondAmount) {
            revert Bagholder__BondInsufficient();
        }

        // check the NFT is not currently being staked in this incentive
        if (stakes[incentiveId][nftId].staker != address(0)) {
            revert Bagholder__AlreadyStaked();
        }

        // check msg.sender owns the NFT
        if (key.nft.ownerOf(nftId) != msg.sender) {
            revert Bagholder__NotNftOwner();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[incentiveId][msg.sender];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) =
            _accrueRewards(key, stakerInfo, incentiveInfo);

        // update stake state
        stakes[incentiveId][nftId] = Stake({staker: msg.sender});

        // update staker state
        stakerInfo.numberOfStakedTokens += 1;
        stakerInfos[incentiveId][msg.sender] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens += 1;
        incentiveInfos[incentiveId] = incentiveInfo;
    }

    function unstake(
        IncentiveKey calldata key,
        uint256 nftId,
        address bondRecipient
    )
        external
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // check the NFT is currently being staked in the incentive
        if (stakes[incentiveId][nftId].staker != msg.sender) {
            revert Bagholder__NotStaked();
        }

        // check msg.sender owns the NFT
        if (key.nft.ownerOf(nftId) != msg.sender) {
            revert Bagholder__NotNftOwner();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[incentiveId][msg.sender];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) =
            _accrueRewards(key, stakerInfo, incentiveInfo);

        // update NFT state
        delete stakes[incentiveId][nftId];

        // update staker state
        stakerInfo.numberOfStakedTokens -= 1;
        stakerInfos[incentiveId][msg.sender] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens -= 1;
        incentiveInfos[incentiveId] = incentiveInfo;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // return bond to user
        bondRecipient.safeTransferETH(key.bondAmount);
    }

    function punishPaperHand(
        IncentiveKey calldata key,
        uint256 nftId,
        address bondRecipient
    )
        external
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // check the NFT is currently being staked in this incentive by someone other than the NFT owner
        address staker = stakes[incentiveId][nftId].staker;
        if (staker == address(0) || staker == key.nft.ownerOf(nftId)) {
            revert Bagholder__NotPaperHand();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[incentiveId][staker];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) =
            _accrueRewards(key, stakerInfo, incentiveInfo);

        // update NFT state
        delete stakes[incentiveId][nftId];

        // update staker state
        stakerInfo.numberOfStakedTokens -= 1;
        stakerInfos[incentiveId][staker] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens -= 1;
        incentiveInfos[incentiveId] = incentiveInfo;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // send bond to recipient as reward
        bondRecipient.safeTransferETH(key.bondAmount);
    }

    function createIncentive(IncentiveKey calldata key, uint256 rewardAmount)
        external
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // ensure incentive doesn't already exist
        if (incentiveInfos[incentiveId].lastUpdateTime != 0) {
            revert Bagholder__IncentiveAlreadyExists();
        }

        // ensure incentive key is valid
        if (
            address(key.nft)
                == address(0)
                || address(key.rewardToken)
                == address(0)
                || key.startTime
                >= key.endTime
        ) {
            revert Bagholder__InvalidIncentiveKey();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // create incentive info
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        incentiveInfos[incentiveId] = IncentiveInfo({
            rewardRatePerSecond: rewardAmount
                / (key.endTime - key.startTime),
            rewardPerTokenStored: 0,
            numberOfStakedTokens: 0,
            lastUpdateTime: lastTimeRewardApplicable
                .safeCastTo64()
        });

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer reward tokens from sender
        key.rewardToken.safeTransferFrom(
            msg.sender, address(this), rewardAmount
        );
    }

    function claimRewards(IncentiveKey calldata key, address recipient)
        external
        virtual
    {
        bytes32 incentiveId = key.compute();

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[incentiveId][msg.sender];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) =
            _accrueRewards(key, stakerInfo, incentiveInfo);

        // update staker state
        uint256 totalRewardUnclaimed = stakerInfo.totalRewardUnclaimed;
        stakerInfo.totalRewardUnclaimed = 0;
        stakerInfos[incentiveId][msg.sender] = stakerInfo;

        // update incentive state
        incentiveInfos[incentiveId] = incentiveInfo;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer reward to user
        key.rewardToken.safeTransferFrom(
            address(this), recipient, totalRewardUnclaimed
        );
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    function rewardPerToken(IncentiveKey calldata key)
        external
        view
        returns (uint256)
    {
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        return _rewardPerToken(
            incentiveInfos[key.compute()], lastTimeRewardApplicable
        );
    }

    function earned(IncentiveKey calldata key, address staker)
        external
        view
        returns (uint256)
    {
        bytes32 incentiveId = key.compute();
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        StakerInfo memory info = stakerInfos[incentiveId][staker];
        return _earned(
            info,
            _rewardPerToken(incentiveInfos[key.compute()], lastTimeRewardApplicable)
        );
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _rewardPerToken(
        IncentiveInfo memory info,
        uint256 lastTimeRewardApplicable
    )
        internal
        pure
        returns (uint256)
    {
        if (info.numberOfStakedTokens == 0) {
            return info.rewardPerTokenStored;
        }
        return info.rewardPerTokenStored
            +
            FullMath.mulDiv(
                (lastTimeRewardApplicable - info.lastUpdateTime) * PRECISION,
                info.rewardRatePerSecond,
                info.numberOfStakedTokens
            );
    }

    function _earned(StakerInfo memory info, uint256 rewardPerToken_)
        internal
        pure
        returns (uint256)
    {
        return
            FullMath.mulDiv(
                info.numberOfStakedTokens,
                rewardPerToken_ - info.rewardPerTokenClaimed,
                PRECISION
            )
            + info.totalRewardUnclaimed;
    }

    function _accrueRewards(
        IncentiveKey calldata key,
        StakerInfo memory stakerInfo,
        IncentiveInfo memory incentiveInfo
    )
        internal
        view
        returns (StakerInfo memory, IncentiveInfo memory)
    {
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        uint256 rewardPerToken_ =
            _rewardPerToken(incentiveInfo, lastTimeRewardApplicable);

        incentiveInfo.rewardPerTokenStored = rewardPerToken_.safeCastTo128();
        incentiveInfo.lastUpdateTime = lastTimeRewardApplicable.safeCastTo64();
        stakerInfo.totalRewardUnclaimed = _earned(stakerInfo, rewardPerToken_);
        stakerInfo.rewardPerTokenClaimed = rewardPerToken_.safeCastTo128();

        return (stakerInfo, incentiveInfo);
    }
}