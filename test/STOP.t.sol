// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {STOP} from "../src/STOP.sol";

contract STOPTest is Test {
    STOP token;

    function setUp() public {
        token = new STOP();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Stoploss");
        assertEq(token.symbol(), "STOP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_exactTransferAndAllowance(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.approve(address(123), amount);
        vm.prank(address(123));
        assertTrue(token.transferFrom(address(this), address(456), amount));
        assertEq(token.balanceOf(address(456)), amount);
        assertEq(token.allowance(address(this), address(123)), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
    }

    function test_unauthorizedTransferAndZeroRecipientFail() public {
        vm.expectRevert();
        vm.prank(address(123));
        token.transferFrom(address(this), address(456), 1);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.expectRevert();
        vm.prank(address(456));
        token.transfer(address(123), 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[10] memory names = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < names.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(names[i], address(this), 1 ether));
            assertFalse(ok);
            vm.prank(address(0xBAD));
            (ok,) = address(token).call(abi.encodeWithSignature(names[i], address(0xBAD), 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
