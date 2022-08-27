// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import "../src/lib/Structs.sol";
import {Bagholder} from "../src/Bagholder.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {IncentiveId} from "../src/lib/IncentiveId.sol";

contract BagholderTest is Test {
    using IncentiveId for IncentiveKey;

    TestERC721 nft;
    TestERC20 token;
    Bagholder bagholder;
    IncentiveKey key;
    uint256 constant BOND = 0.01 ether;
    uint256 constant INCENTIVE_LENGTH = 30 days;
    uint256 constant INCENTIVE_AMOUNT = 1000 ether;
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");

    function setUp() public {
        // deploy Bagholder
        bagholder = new Bagholder();

        // deploy mock NFT
        nft = new TestERC721();

        // deploy mock token
        token = new TestERC20();

        // setup incentive
        key = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND
        });
        token.mint(address(this), INCENTIVE_AMOUNT);
        token.approve(address(bagholder), type(uint256).max);
        bagholder.createIncentive(key, INCENTIVE_AMOUNT);

        // mint NFT
        nft.safeMint(alice, 1);
        nft.safeMint(bob, 2);
    }

    function test_stake() public {
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);

        // verify staker
        bytes32 incentiveId = key.compute();
        assertEq(bagholder.stakers(incentiveId, 1), alice, "staker incorrect");

        // verify stakerInfo
        {
            (
                uint256 totalRewardUnclaimed,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens
            ) = bagholder.stakerInfos(incentiveId, alice);
            assertEq(totalRewardUnclaimed, 0, "totalRewardUnclaimed not 0");
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 1, "numberOfStakedTokens not 1");
        }

        // verify incentiveInfo
        {
            (
                uint256 rewardRatePerSecond,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens,
                uint64 lastUpdateTime
            ) = bagholder.incentiveInfos(incentiveId);
            assertEq(rewardRatePerSecond, INCENTIVE_AMOUNT / INCENTIVE_LENGTH);
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 1, "numberOfStakedTokens not 1");
            assertEq(
                lastUpdateTime,
                block.timestamp,
                "lastUpdateTime incorrect"
            );
        }
    }

    function test_stakeAndUnstake() public {
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        uint256 beforeBalance = alice.balance;
        bagholder.unstake(key, 1, alice);

        // verify staker
        bytes32 incentiveId = key.compute();
        assertEq(
            bagholder.stakers(incentiveId, 1),
            address(0),
            "staker incorrect"
        );

        // verify stakerInfo
        {
            (
                uint256 totalRewardUnclaimed,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens
            ) = bagholder.stakerInfos(incentiveId, alice);
            assertEq(totalRewardUnclaimed, 0, "totalRewardUnclaimed not 0");
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
        }

        // verify incentiveInfo
        {
            (
                uint256 rewardRatePerSecond,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens,
                uint64 lastUpdateTime
            ) = bagholder.incentiveInfos(incentiveId);
            assertEq(rewardRatePerSecond, INCENTIVE_AMOUNT / INCENTIVE_LENGTH);
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
            assertEq(
                lastUpdateTime,
                block.timestamp,
                "lastUpdateTime incorrect"
            );
        }

        // verify bond
        assertEqDecimal(
            alice.balance - beforeBalance,
            BOND,
            18,
            "didn't receive bond"
        );
    }

    function test_stakeAndSlash() public {
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        nft.safeTransferFrom(alice, bob, 1);

        changePrank(bob);
        bagholder.slashPaperHand(key, 1, bob);

        // verify staker
        bytes32 incentiveId = key.compute();
        assertEq(
            bagholder.stakers(incentiveId, 1),
            address(0),
            "staker incorrect"
        );

        // verify stakerInfo
        {
            (
                uint256 totalRewardUnclaimed,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens
            ) = bagholder.stakerInfos(incentiveId, alice);
            assertEq(totalRewardUnclaimed, 0, "totalRewardUnclaimed not 0");
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
        }

        // verify incentiveInfo
        {
            (
                uint256 rewardRatePerSecond,
                uint128 rewardPerTokenStored,
                uint64 numberOfStakedTokens,
                uint64 lastUpdateTime
            ) = bagholder.incentiveInfos(incentiveId);
            assertEq(rewardRatePerSecond, INCENTIVE_AMOUNT / INCENTIVE_LENGTH);
            assertEq(rewardPerTokenStored, 0, "rewardPerTokenStored not 0");
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
            assertEq(
                lastUpdateTime,
                block.timestamp,
                "lastUpdateTime incorrect"
            );
        }

        // verify bond
        assertEqDecimal(bob.balance, BOND, 18, "didn't receive bond");
    }
}
