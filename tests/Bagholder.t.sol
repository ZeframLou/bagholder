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
    uint256 constant MAX_ERROR_PERCENT = 1e9; // 10**-9
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");
    address refundRecipient = makeAddr("Refund Recipient");

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
            bondAmount: BOND,
            refundRecipient: refundRecipient
        });
        token.mint(address(this), INCENTIVE_AMOUNT);
        token.approve(address(bagholder), type(uint256).max);
        bagholder.createIncentive(key, INCENTIVE_AMOUNT);

        // mint NFT
        nft.safeMint(alice, 1);
        nft.safeMint(alice, 2);
        nft.safeMint(bob, 11);
        nft.safeMint(bob, 12);
    }

    function test_stake() public {
        startHoax(alice);
        uint256 beforeBalance = alice.balance;
        bagholder.stake{value: BOND}(key, 1);

        // verify staker
        bytes32 incentiveId = key.compute();
        assertEq(bagholder.stakers(incentiveId, 1), alice, "staker incorrect");

        // verify stakerInfo
        {
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                incentiveId,
                alice
            );
            assertEq(numberOfStakedTokens, 1, "numberOfStakedTokens not 1");
        }

        // verify incentiveInfo
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                incentiveId
            );
            assertEq(numberOfStakedTokens, 1, "numberOfStakedTokens not 1");
        }

        // verify bond
        assertEqDecimal(
            beforeBalance - alice.balance,
            BOND,
            18,
            "didn't charge bond"
        );
    }

    function test_stakeMultiple() public {
        startHoax(alice);
        StakeMultipleInput[] memory inputs = new StakeMultipleInput[](2);
        inputs[0].key = key;
        inputs[0].nftId = 1;
        inputs[1].key = key;
        inputs[1].nftId = 2;
        uint256 beforeBalance = alice.balance;
        bagholder.stakeMultiple{value: BOND * 2}(inputs);

        // verify staker
        bytes32 incentiveId = key.compute();
        assertEq(
            bagholder.stakers(incentiveId, 1),
            alice,
            "staker 1 incorrect"
        );
        assertEq(
            bagholder.stakers(incentiveId, 2),
            alice,
            "staker 2 incorrect"
        );

        // verify stakerInfo
        {
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                incentiveId,
                alice
            );
            assertEq(numberOfStakedTokens, 2, "numberOfStakedTokens not 2");
        }

        // verify incentiveInfo
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                incentiveId
            );
            assertEq(numberOfStakedTokens, 2, "numberOfStakedTokens not 2");
        }

        // verify bond
        assertEqDecimal(
            beforeBalance - alice.balance,
            BOND * 2,
            18,
            "didn't charge bond"
        );
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
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                incentiveId,
                alice
            );
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
        }

        // verify incentiveInfo
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                incentiveId
            );
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
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
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                incentiveId,
                alice
            );
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
        }

        // verify incentiveInfo
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                incentiveId
            );
            assertEq(numberOfStakedTokens, 0, "numberOfStakedTokens not 0");
        }

        // verify bond
        assertEqDecimal(bob.balance, BOND, 18, "didn't receive bond");
    }

    function test_restake() public {
        // setup another incentive
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });
        token.mint(address(this), INCENTIVE_AMOUNT);
        bagholder.createIncentive(k, INCENTIVE_AMOUNT);

        // stake NFT 1 in the first incentive and restake NFT 2 in the second incentive
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        bagholder.restake(key, 1, k, 2, bob);

        // verify staker
        assertEq(
            bagholder.stakers(key.compute(), 1),
            address(0),
            "staker incorrect"
        );
        assertEq(bagholder.stakers(k.compute(), 2), alice, "staker incorrect");

        // verify stakerInfo
        {
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                key.compute(),
                alice
            );
            assertEq(
                numberOfStakedTokens,
                0,
                "unstaker numberOfStakedTokens not 0"
            );
        }
        {
            (, , uint64 numberOfStakedTokens) = bagholder.stakerInfos(
                k.compute(),
                alice
            );
            assertEq(
                numberOfStakedTokens,
                1,
                "staker numberOfStakedTokens not 1"
            );
        }

        // verify incentiveInfo
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                key.compute()
            );
            assertEq(
                numberOfStakedTokens,
                0,
                "unstake incentive numberOfStakedTokens not 0"
            );
        }
        {
            (, , uint64 numberOfStakedTokens, , ) = bagholder.incentiveInfos(
                k.compute()
            );
            assertEq(
                numberOfStakedTokens,
                1,
                "stake incentive numberOfStakedTokens not 1"
            );
        }

        // verify bond
        assertEqDecimal(bob.balance, BOND / 2, 18, "didn't receive bond");
    }

    function test_stakeAndWait() public {
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);

        // skip 1/3 of the incentive time
        skip(INCENTIVE_LENGTH / 3);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT / 3,
            1e9,
            "reward amount incorrect"
        );

        // skip to the end of the incentive
        skip((INCENTIVE_LENGTH * 2) / 3);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT,
            1e9,
            "reward amount incorrect"
        );

        // skip to 2x the incentive time
        skip(INCENTIVE_LENGTH);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT,
            1e9,
            "still earning reward after incentive end"
        );

        // claim rewards
        uint256 beforeBalance = token.balanceOf(alice);
        uint256 rewardAmount = bagholder.claimRewards(key, alice);

        // verify reward amount
        assertApproxEqRel(
            rewardAmount,
            INCENTIVE_AMOUNT,
            1e9,
            "claimed reward incorrect"
        );
        assertApproxEqRel(
            token.balanceOf(alice) - beforeBalance,
            INCENTIVE_AMOUNT,
            1e9,
            "actual claimed reward incorrect"
        );
    }

    function test_twoStakersAndWait() public {
        /**
            Alice stakes NFT 1
            Bob stakes NFTs 11, 12
            Both wait for 1/3 of the incentive length
         */
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        bagholder.stake{value: BOND}(key, 11);
        bagholder.stake{value: BOND}(key, 12);
        skip(INCENTIVE_LENGTH / 3);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT / 3 / 3,
            MAX_ERROR_PERCENT,
            "alice reward amount incorrect"
        );
        assertApproxEqRel(
            bagholder.earned(key, bob),
            (INCENTIVE_AMOUNT * 2) / 3 / 3,
            MAX_ERROR_PERCENT,
            "bob reward amount incorrect"
        );
    }

    function test_twoIncentivesAndWait() public {
        // setup another incentive
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });
        token.mint(address(this), INCENTIVE_AMOUNT);
        bagholder.createIncentive(k, INCENTIVE_AMOUNT);

        /**
            Alice stakes NFT 1 in the first incentive
            and stakes NFT 2 in the second incentive
            Wait for 1/4 of the incentive length
         */
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        bagholder.stake{value: BOND / 2}(k, 2);
        skip(INCENTIVE_LENGTH / 4);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT / 4,
            MAX_ERROR_PERCENT,
            "alice reward amount from the first incentive is incorrect"
        );
        assertApproxEqRel(
            bagholder.earned(k, alice),
            INCENTIVE_AMOUNT / 4,
            MAX_ERROR_PERCENT,
            "alice reward amount from the second incentive is incorrect"
        );
    }

    function test_twoIntersectingStakes() public {
        /**
            Alice stakes NFT 1 from time 1/4 to 3/4
            Bob stakes NFT 11 from time 2/4 to 1
         */
        startHoax(alice);
        skip(INCENTIVE_LENGTH / 4);
        bagholder.stake{value: BOND}(key, 1);
        skip(INCENTIVE_LENGTH / 4);
        bagholder.stake{value: BOND}(key, 11);
        skip(INCENTIVE_LENGTH / 4);
        bagholder.unstake(key, 1, alice);
        skip(INCENTIVE_LENGTH / 4);

        // verify reward amount
        assertApproxEqRel(
            bagholder.earned(key, alice),
            INCENTIVE_AMOUNT / 4 + INCENTIVE_AMOUNT / 8,
            MAX_ERROR_PERCENT,
            "alice reward amount incorrect"
        );
        assertApproxEqRel(
            bagholder.earned(key, bob),
            INCENTIVE_AMOUNT / 8 + INCENTIVE_AMOUNT / 4,
            MAX_ERROR_PERCENT,
            "bob reward amount incorrect"
        );

        // claim refund
        uint256 refundAmount = bagholder.claimRefund(key);

        // verify refund amount
        assertApproxEqRel(
            refundAmount,
            INCENTIVE_AMOUNT / 4,
            MAX_ERROR_PERCENT,
            "refund amount incorrect"
        );
        assertEqDecimal(
            token.balanceOf(refundRecipient),
            refundAmount,
            18,
            "didn't receive refund"
        );

        // try claiming refund again
        refundAmount = bagholder.claimRefund(key);

        // verify refund amount
        assertApproxEqRel(
            refundAmount,
            0,
            MAX_ERROR_PERCENT,
            "second refund amount incorrect"
        );
    }

    function test_claimRefund() public {
        startHoax(alice);
        skip(INCENTIVE_LENGTH / 3);
        bagholder.stake{value: BOND}(key, 1);
        skip(INCENTIVE_LENGTH / 3);
        bagholder.unstake(key, 1, alice);
        skip(INCENTIVE_LENGTH / 3);

        // claim refund
        uint256 refundAmount = bagholder.claimRefund(key);

        // verify refund amount
        assertApproxEqRel(
            refundAmount,
            (INCENTIVE_AMOUNT * 2) / 3,
            MAX_ERROR_PERCENT,
            "refund amount incorrect"
        );
    }

    function test_claimRefundNoStakes() public {
        // skip the incentive period without any staking
        skip(INCENTIVE_LENGTH);

        // claim refund
        uint256 refundAmount = bagholder.claimRefund(key);

        // verify refund amount
        assertApproxEqRel(
            refundAmount,
            INCENTIVE_AMOUNT,
            MAX_ERROR_PERCENT,
            "refund amount incorrect"
        );
    }

    function testFail_stakeAndTransferAndUnstake() public {
        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        nft.safeTransferFrom(alice, bob, 1);
        bagholder.unstake(key, 1, alice);
    }

    function testFail_stakeInNonexistentIncentive() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        startHoax(alice);
        bagholder.stake{value: BOND / 2}(k, 1);
    }

    function testFail_stakeMultipleInNonexistentIncentive() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        startHoax(alice);
        StakeMultipleInput[] memory inputs = new StakeMultipleInput[](2);
        inputs[0].key = key;
        inputs[0].nftId = 1;
        inputs[1].key = k;
        inputs[1].nftId = 2;
        bagholder.stakeMultiple{value: (BOND * 3) / 2}(inputs);
    }

    function testFail_restakeInNonexistentIncentive() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        bagholder.restake(key, 1, k, 2, bob);
    }

    function testFail_unstakeFromNonexistentIncentive() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        bagholder.unstake(k, 1, alice);
    }

    function testFail_claimRewardsFromNonexistentIncentive() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        startHoax(alice);
        bagholder.stake{value: BOND}(key, 1);
        skip(INCENTIVE_LENGTH);
        bagholder.claimRewards(k, alice);
    }

    function testFail_createIncentiveWithZeroReward() public {
        IncentiveKey memory k = IncentiveKey({
            nft: nft,
            rewardToken: token,
            startTime: block.timestamp,
            endTime: block.timestamp + INCENTIVE_LENGTH,
            bondAmount: BOND / 2,
            refundRecipient: refundRecipient
        });

        bagholder.createIncentive(k, 0);
    }

    function testFail_createDuplicateIncentive() public {
        token.mint(address(this), INCENTIVE_AMOUNT);
        bagholder.createIncentive(key, INCENTIVE_AMOUNT);
    }

    function testFail_slashNonPaperHand() public {
        hoax(alice);
        bagholder.stake{value: BOND}(key, 1);

        hoax(bob);
        bagholder.slashPaperHand(key, 1, bob);
    }
}
