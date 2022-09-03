// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import {BoringOwnable} from "boringsolidity/BoringOwnable.sol";

import {Multicall} from "openzeppelin/utils/Multicall.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {FullMath} from "v3-core/libraries/FullMath.sol";

import {SelfPermit} from "v3-periphery/base/SelfPermit.sol";

import "./lib/Math.sol";
import "./lib/Structs.sol";
import {IncentiveId} from "./lib/IncentiveId.sol";

/// @title Bagholder
/// @author zefram.eth
/// @notice Incentivize NFT holders to keep holding their bags without letting their
/// precious NFTs leave their wallets.
/// @dev Uses an optimistic staking model where if someone staked and then transferred
/// their NFT elsewhere, someone else can slash them and receive the staker's bond.
contract Bagholder is Multicall, SelfPermit, BoringOwnable {
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

    /// @notice Thrown when unstaking an NFT that hasn't been staked
    error Bagholder__NotStaked();

    /// @notice Thrown when an unauthorized account tries to perform an action available
    /// only to the NFT's owner
    error Bagholder__NotNftOwner();

    /// @notice Thrown when trying to slash someone who shouldn't be slashed
    error Bagholder__NotPaperHand();

    /// @notice Thrown when staking an NFT that's already staked
    error Bagholder__AlreadyStaked();

    /// @notice Thrown when the bond provided by the staker differs from the specified amount
    error Bagholder__BondIncorrect();

    /// @notice Thrown when creating an incentive using invalid parameters (e.g. start time is after end time)
    error Bagholder__InvalidIncentiveKey();

    /// @notice Thrown when staking into an incentive that doesn't exist
    error Bagholder__IncentiveNonexistent();

    /// @notice Thrown when creating an incentive with a zero reward rate
    error Bagholder__RewardAmountTooSmall();

    /// @notice Thrown when creating an incentive that already exists
    error Bagholder__IncentiveAlreadyExists();

    /// @notice Thrown when setting the protocol fee recipient to the zero address
    /// while having a non-zero protocol fee
    error Bagholder_ProtocolFeeRecipientIsZero();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Stake(
        address indexed staker,
        bytes32 indexed incentiveId,
        uint256 indexed nftId
    );
    event Unstake(
        address indexed staker,
        bytes32 indexed incentiveId,
        uint256 indexed nftId,
        address bondRecipient
    );
    event SlashPaperHand(
        address indexed sender,
        bytes32 indexed incentiveId,
        uint256 indexed nftId,
        address bondRecipient
    );
    event CreateIncentive(
        address indexed sender,
        bytes32 indexed incentiveId,
        IncentiveKey key,
        uint256 rewardAmount,
        uint256 protocolFeeAmount
    );
    event ClaimRewards(
        address indexed staker,
        bytes32 indexed incentiveId,
        address recipient
    );
    event ClaimRefund(
        address indexed sender,
        bytes32 indexed incentiveId,
        uint256 refundAmount
    );
    event SetProtocolFee(ProtocolFeeInfo protocolFeeInfo_);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The precision used by rewardPerToken
    uint256 internal constant PRECISION = 1e27;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice Records the address that staked an NFT into an incentive.
    /// Zero address if the NFT hasn't been staked into the incentive.
    /// @dev incentive ID => NFT ID => staker address
    mapping(bytes32 => mapping(uint256 => address)) public stakers;

    /// @notice Records accounting info about each staker.
    /// @dev incentive ID => staker address => info
    mapping(bytes32 => mapping(address => StakerInfo)) public stakerInfos;

    /// @notice Records accounting info about each incentive.
    /// @dev incentive ID => info
    mapping(bytes32 => IncentiveInfo) public incentiveInfos;

    /// @notice Stores the amount and recipient of the protocol fee
    ProtocolFeeInfo public protocolFeeInfo;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(ProtocolFeeInfo memory protocolFeeInfo_) {
        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Bagholder_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;
        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Public actions
    /// -----------------------------------------------------------------------

    /// @notice Stakes an NFT into an incentive. The NFT stays in the user's wallet.
    /// The caller must provide the ETH bond (specified in the incentive key) as part of
    /// the call. Anyone can stake on behalf of anyone else, provided they provide the bond.
    /// @param key the incentive's key
    /// @param nftId the ID of the NFT
    function stake(IncentiveKey calldata key, uint256 nftId)
        external
        payable
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();
        address staker = key.nft.ownerOf(nftId);
        StakerInfo memory stakerInfo = stakerInfos[incentiveId][staker];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // check bond is correct
        if (msg.value != key.bondAmount) {
            revert Bagholder__BondIncorrect();
        }

        // check the NFT is not currently being staked in this incentive
        if (stakers[incentiveId][nftId] != address(0)) {
            revert Bagholder__AlreadyStaked();
        }

        // ensure the incentive exists
        if (incentiveInfo.lastUpdateTime == 0) {
            revert Bagholder__IncentiveNonexistent();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) = _accrueRewards(
            key,
            stakerInfo,
            incentiveInfo
        );

        // update stake state
        stakers[incentiveId][nftId] = staker;

        // update staker state
        stakerInfo.numberOfStakedTokens += 1;
        stakerInfos[incentiveId][staker] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens += 1;
        incentiveInfos[incentiveId] = incentiveInfo;

        emit Stake(staker, incentiveId, nftId);
    }

    /// @notice Stakes multiple NFTs into incentives. The NFTs stay in the user's wallet.
    /// The caller must provide the ETH bond (specified in the incentive keys) as part of
    /// the call. Anyone can stake on behalf of anyone else, provided they provide the bond.
    /// @param inputs The array of inputs, with each input consisting of an incentive key
    /// and an NFT ID.
    function stakeMultiple(StakeMultipleInput[] calldata inputs)
        external
        payable
        virtual
    {
        uint256 numInputs = inputs.length;
        uint256 totalBondRequired;
        for (uint256 i; i < numInputs; ) {
            /// -----------------------------------------------------------------------
            /// Storage loads
            /// -----------------------------------------------------------------------

            bytes32 incentiveId = inputs[i].key.compute();
            uint256 nftId = inputs[i].nftId;
            address staker = inputs[i].key.nft.ownerOf(nftId);
            StakerInfo memory stakerInfo = stakerInfos[incentiveId][staker];
            IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            // check the NFT is not currently being staked in this incentive
            if (stakers[incentiveId][nftId] != address(0)) {
                revert Bagholder__AlreadyStaked();
            }

            // ensure the incentive exists
            if (incentiveInfo.lastUpdateTime == 0) {
                revert Bagholder__IncentiveNonexistent();
            }

            /// -----------------------------------------------------------------------
            /// State updates
            /// -----------------------------------------------------------------------

            // accrue rewards
            (stakerInfo, incentiveInfo) = _accrueRewards(
                inputs[i].key,
                stakerInfo,
                incentiveInfo
            );

            // update stake state
            stakers[incentiveId][nftId] = staker;

            // update staker state
            stakerInfo.numberOfStakedTokens += 1;
            stakerInfos[incentiveId][staker] = stakerInfo;

            // update incentive state
            incentiveInfo.numberOfStakedTokens += 1;
            incentiveInfos[incentiveId] = incentiveInfo;

            emit Stake(staker, incentiveId, nftId);

            totalBondRequired += inputs[i].key.bondAmount;
            unchecked {
                ++i;
            }
        }

        // check bond is correct
        if (msg.value != totalBondRequired) {
            revert Bagholder__BondIncorrect();
        }
    }

    /// @notice Unstakes an NFT from an incentive and returns the ETH bond.
    /// The caller must be the owner of the NFT AND the current staker.
    /// @param key the incentive's key
    /// @param nftId the ID of the NFT
    /// @param bondRecipient the recipient of the ETH bond
    function unstake(
        IncentiveKey calldata key,
        uint256 nftId,
        address bondRecipient
    ) external virtual {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // check the NFT is currently being staked in the incentive
        if (stakers[incentiveId][nftId] != msg.sender) {
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
        (stakerInfo, incentiveInfo) = _accrueRewards(
            key,
            stakerInfo,
            incentiveInfo
        );

        // update NFT state
        delete stakers[incentiveId][nftId];

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

        emit Unstake(msg.sender, incentiveId, nftId, bondRecipient);
    }

    /// @notice Unstaked an NFT from an incentive, then use the bond to stake an NFT into another incentive.
    /// Must be called by the owner of the unstaked NFT. The bond amount of the incentive to unstake from must be at least
    /// that of the incentive to stake in, with any extra bond sent to the specified recipient.
    /// @param unstakeKey the key of the incentive to unstake from
    /// @param unstakeNftId the ID of the NFT to unstake
    /// @param stakeKey the key of the incentive to stake into
    /// @param stakeNftId the ID of the NFT to stake
    /// @param bondRecipient the recipient of any extra bond
    function restake(
        IncentiveKey calldata unstakeKey,
        uint256 unstakeNftId,
        IncentiveKey calldata stakeKey,
        uint256 stakeNftId,
        address bondRecipient
    ) external virtual {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 unstakeIncentiveId = unstakeKey.compute();
        bytes32 stakeIncentiveId = stakeKey.compute();

        // check the NFT is currently being staked in the unstake incentive
        if (stakers[unstakeIncentiveId][unstakeNftId] != msg.sender) {
            revert Bagholder__NotStaked();
        }

        // check msg.sender owns the unstaked NFT
        if (unstakeKey.nft.ownerOf(unstakeNftId) != msg.sender) {
            revert Bagholder__NotNftOwner();
        }

        // check there's enough bond
        if (unstakeKey.bondAmount < stakeKey.bondAmount) {
            revert Bagholder__BondIncorrect();
        }

        // check the staked NFT is not currently being staked in the stake incentive
        if (stakers[stakeIncentiveId][stakeNftId] != address(0)) {
            revert Bagholder__AlreadyStaked();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads (Unstake)
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[unstakeIncentiveId][
            msg.sender
        ];
        IncentiveInfo memory incentiveInfo = incentiveInfos[unstakeIncentiveId];

        /// -----------------------------------------------------------------------
        /// State updates (Unstake)
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) = _accrueRewards(
            unstakeKey,
            stakerInfo,
            incentiveInfo
        );

        // update NFT state
        delete stakers[unstakeIncentiveId][unstakeNftId];

        // update staker state
        stakerInfo.numberOfStakedTokens -= 1;
        stakerInfos[unstakeIncentiveId][msg.sender] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens -= 1;
        incentiveInfos[unstakeIncentiveId] = incentiveInfo;

        emit Unstake(
            msg.sender,
            unstakeIncentiveId,
            unstakeNftId,
            bondRecipient
        );

        /// -----------------------------------------------------------------------
        /// Storage loads (Stake)
        /// -----------------------------------------------------------------------

        address staker = stakeKey.nft.ownerOf(stakeNftId);
        stakerInfo = stakerInfos[stakeIncentiveId][staker];
        incentiveInfo = incentiveInfos[stakeIncentiveId];

        // ensure the incentive exists
        if (incentiveInfo.lastUpdateTime == 0) {
            revert Bagholder__IncentiveNonexistent();
        }

        /// -----------------------------------------------------------------------
        /// State updates (Stake)
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) = _accrueRewards(
            stakeKey,
            stakerInfo,
            incentiveInfo
        );

        // update stake state
        stakers[stakeIncentiveId][stakeNftId] = staker;

        // update staker state
        stakerInfo.numberOfStakedTokens += 1;
        stakerInfos[stakeIncentiveId][staker] = stakerInfo;

        // update incentive state
        incentiveInfo.numberOfStakedTokens += 1;
        incentiveInfos[stakeIncentiveId] = incentiveInfo;

        emit Stake(staker, stakeIncentiveId, stakeNftId);

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        if (unstakeKey.bondAmount != stakeKey.bondAmount) {
            unchecked {
                // return extra bond to user
                // already checked unstakeKey.bondAmount > stakeKey.bondAmount
                bondRecipient.safeTransferETH(
                    unstakeKey.bondAmount - stakeKey.bondAmount
                );
            }
        }
    }

    /// @notice Slashes a staker who has transferred the staked NFT to another address.
    /// The bond is given to the slasher as reward.
    /// @param key the incentive's key
    /// @param nftId the ID of the NFT
    /// @param bondRecipient the recipient of the ETH bond
    function slashPaperHand(
        IncentiveKey calldata key,
        uint256 nftId,
        address bondRecipient
    ) external virtual {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();

        // check the NFT is currently being staked in this incentive by someone other than the NFT owner
        address staker = stakers[incentiveId][nftId];
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
        (stakerInfo, incentiveInfo) = _accrueRewards(
            key,
            stakerInfo,
            incentiveInfo
        );

        // update NFT state
        delete stakers[incentiveId][nftId];

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

        emit SlashPaperHand(msg.sender, incentiveId, nftId, bondRecipient);
    }

    /// @notice Creates an incentive and transfers the reward tokens from the caller.
    /// @dev Will revert if the incentive key is invalid (e.g. startTime >= endTime)
    /// @param key the incentive's key
    /// @param rewardAmount the amount of reward tokens to add to the incentive
    function createIncentive(IncentiveKey calldata key, uint256 rewardAmount)
        external
        virtual
    {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        bytes32 incentiveId = key.compute();
        ProtocolFeeInfo memory protocolFeeInfo_ = protocolFeeInfo;

        // ensure incentive doesn't already exist
        if (incentiveInfos[incentiveId].lastUpdateTime != 0) {
            revert Bagholder__IncentiveAlreadyExists();
        }

        // ensure incentive key is valid
        if (
            address(key.nft) == address(0) ||
            address(key.rewardToken) == address(0) ||
            key.startTime >= key.endTime ||
            key.endTime < block.timestamp
        ) {
            revert Bagholder__InvalidIncentiveKey();
        }

        // apply protocol fee
        uint256 protocolFeeAmount;
        if (protocolFeeInfo_.fee != 0) {
            protocolFeeAmount = FullMath.mulDiv(
                rewardAmount,
                protocolFeeInfo_.fee,
                1000
            );
            rewardAmount -= protocolFeeAmount;
        }

        // ensure incentive amount makes sense
        uint128 rewardRatePerSecond = (rewardAmount /
            (key.endTime - key.startTime)).safeCastTo128();
        if (rewardRatePerSecond == 0) {
            revert Bagholder__RewardAmountTooSmall();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // create incentive info
        incentiveInfos[incentiveId] = IncentiveInfo({
            rewardRatePerSecond: rewardRatePerSecond,
            rewardPerTokenStored: 0,
            numberOfStakedTokens: 0,
            lastUpdateTime: block.timestamp.safeCastTo64(),
            accruedRefund: 0
        });

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer reward tokens from sender
        key.rewardToken.safeTransferFrom(
            msg.sender,
            address(this),
            rewardAmount
        );

        // transfer protocol fee
        if (protocolFeeAmount != 0) {
            key.rewardToken.safeTransferFrom(
                msg.sender,
                protocolFeeInfo_.recipient,
                protocolFeeAmount
            );
        }

        emit CreateIncentive(
            msg.sender,
            incentiveId,
            key,
            rewardAmount,
            protocolFeeAmount
        );
    }

    /// @notice Claims the reward tokens the caller has earned from a particular incentive.
    /// @param key the incentive's key
    /// @param recipient the recipient of the reward tokens
    /// @return rewardAmount the amount of reward tokens claimed
    function claimRewards(IncentiveKey calldata key, address recipient)
        external
        virtual
        returns (uint256 rewardAmount)
    {
        bytes32 incentiveId = key.compute();

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        StakerInfo memory stakerInfo = stakerInfos[incentiveId][msg.sender];
        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];

        // ensure the incentive exists
        if (incentiveInfo.lastUpdateTime == 0) {
            revert Bagholder__IncentiveNonexistent();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        (stakerInfo, incentiveInfo) = _accrueRewards(
            key,
            stakerInfo,
            incentiveInfo
        );

        // update staker state
        rewardAmount = stakerInfo.totalRewardUnclaimed;
        stakerInfo.totalRewardUnclaimed = 0;
        stakerInfos[incentiveId][msg.sender] = stakerInfo;

        // update incentive state
        incentiveInfos[incentiveId] = incentiveInfo;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer reward to user
        key.rewardToken.safeTransfer(recipient, rewardAmount);

        emit ClaimRewards(msg.sender, incentiveId, recipient);
    }

    function claimRefund(IncentiveKey calldata key)
        external
        virtual
        returns (uint256 refundAmount)
    {
        bytes32 incentiveId = key.compute();

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        IncentiveInfo memory incentiveInfo = incentiveInfos[incentiveId];
        refundAmount = incentiveInfo.accruedRefund;

        // ensure the incentive exists
        if (incentiveInfo.lastUpdateTime == 0) {
            revert Bagholder__IncentiveNonexistent();
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        uint256 rewardPerToken_ = _rewardPerToken(
            incentiveInfo,
            lastTimeRewardApplicable
        );

        if (incentiveInfo.numberOfStakedTokens == 0) {
            // [lastUpdateTime, lastTimeRewardApplicable] was a period without any staked NFTs
            // accrue refund
            refundAmount +=
                incentiveInfo.rewardRatePerSecond *
                (lastTimeRewardApplicable - incentiveInfo.lastUpdateTime);
        }
        incentiveInfo.rewardPerTokenStored = rewardPerToken_;
        incentiveInfo.lastUpdateTime = lastTimeRewardApplicable.safeCastTo64();
        incentiveInfo.accruedRefund = 0;

        // update incentive state
        incentiveInfos[incentiveId] = incentiveInfo;

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // transfer refund to recipient
        key.rewardToken.safeTransfer(key.refundRecipient, refundAmount);

        emit ClaimRefund(msg.sender, incentiveId, refundAmount);
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /// @notice Computes the current rewardPerToken value of an incentive.
    /// @param key the incentive's key
    /// @return the rewardPerToken value
    function rewardPerToken(IncentiveKey calldata key)
        external
        view
        returns (uint256)
    {
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        return
            _rewardPerToken(
                incentiveInfos[key.compute()],
                lastTimeRewardApplicable
            );
    }

    /// @notice Computes the amount of reward tokens a staker has accrued
    /// from an incentive.
    /// @param key the incentive's key
    /// @param staker the staker's address
    /// @return the amount of reward tokens accrued
    function earned(IncentiveKey calldata key, address staker)
        external
        view
        returns (uint256)
    {
        bytes32 incentiveId = key.compute();
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        StakerInfo memory info = stakerInfos[incentiveId][staker];
        return
            _earned(
                info,
                _rewardPerToken(
                    incentiveInfos[key.compute()],
                    lastTimeRewardApplicable
                )
            );
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Updates the protocol fee and/or the protocol fee recipient.
    /// Only callable by the owner.
    /// @param protocolFeeInfo_ The new protocol fee info
    function ownerSetProtocolFee(ProtocolFeeInfo calldata protocolFeeInfo_)
        external
        virtual
        onlyOwner
    {
        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            revert Bagholder_ProtocolFeeRecipientIsZero();
        }
        protocolFeeInfo = protocolFeeInfo_;

        emit SetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _rewardPerToken(
        IncentiveInfo memory info,
        uint256 lastTimeRewardApplicable
    ) internal pure returns (uint256) {
        if (info.numberOfStakedTokens == 0) {
            return info.rewardPerTokenStored;
        }
        return
            info.rewardPerTokenStored +
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
                rewardPerToken_ - info.rewardPerTokenStored,
                PRECISION
            ) + info.totalRewardUnclaimed;
    }

    function _accrueRewards(
        IncentiveKey calldata key,
        StakerInfo memory stakerInfo,
        IncentiveInfo memory incentiveInfo
    ) internal view returns (StakerInfo memory, IncentiveInfo memory) {
        uint256 lastTimeRewardApplicable = min(block.timestamp, key.endTime);
        uint256 rewardPerToken_ = _rewardPerToken(
            incentiveInfo,
            lastTimeRewardApplicable
        );

        if (incentiveInfo.numberOfStakedTokens == 0) {
            // [lastUpdateTime, lastTimeRewardApplicable] was a period without any staked NFTs
            // accrue refund
            incentiveInfo.accruedRefund +=
                incentiveInfo.rewardRatePerSecond *
                (lastTimeRewardApplicable - incentiveInfo.lastUpdateTime);
        }
        incentiveInfo.rewardPerTokenStored = rewardPerToken_;
        incentiveInfo.lastUpdateTime = lastTimeRewardApplicable.safeCastTo64();

        stakerInfo.totalRewardUnclaimed = _earned(stakerInfo, rewardPerToken_)
            .safeCastTo192();
        stakerInfo.rewardPerTokenStored = rewardPerToken_;

        return (stakerInfo, incentiveInfo);
    }
}
