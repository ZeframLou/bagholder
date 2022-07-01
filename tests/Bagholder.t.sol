// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract BagholderTest is Test {
    function setUp() public {}

    function testExample() public {
        vm.startPrank(address(0xB0B));
        console2.log("Hello world!");
        assertTrue(true);
    }
}
