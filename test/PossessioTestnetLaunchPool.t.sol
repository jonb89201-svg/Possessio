// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PossessioTestnetLaunchPool} from "../src/PossessioTestnetLaunchPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "mUSDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract PossessioTestnetLaunchPoolTest is Test {
    PossessioTestnetLaunchPool internal pool;
    MockUSDC internal usdc;

    address internal owner = address(0xB0B0);      // stands in for the Base Account
    address internal operator = address(0x0DD0);   // stands in for the Worker dripper key
    address internal alice = address(0xA11CE);     // a launch wallet
    address internal rando = address(0xBAD);

    uint256 internal constant STIPEND = 0.02 ether;
    uint256 internal constant COOLDOWN = 12 hours;
    uint256 internal constant USDC_STIPEND = 100e6; // $100 factory fee tier

    bytes32 internal constant PROTOCOL_OWNER_ROLE =
        0xb19546dff01e856fb3f010c267a7b1c60363cf8a4664e21cc89c26224620214e;

    function setUp() public {
        // Foundry defaults to chainid 31337; the pool structurally refuses that.
        vm.chainId(84532);
        // Foundry also defaults block.timestamp to 1, which puts a FRESH address's
        // readyAt (0 + cooldownSecs) in the future - a test-env artifact only, since
        // real chain timestamps dwarf any cooldown. Warp past the cooldown epoch so
        // first draws behave as they do on-chain. (Repo-side fix; contract untouched.)
        vm.warp(1_000_000);
        pool = new PossessioTestnetLaunchPool(owner, operator, STIPEND, COOLDOWN);
        usdc = new MockUSDC();

        vm.deal(address(this), 100 ether);
        (bool ok, ) = address(pool).call{value: 1 ether}("");
        assertTrue(ok, "refill failed");

        usdc.mint(address(pool), 1_000e6);
        vm.prank(owner);
        pool.setTokenStipend(address(usdc), USDC_STIPEND);
    }

    // ------------------------------------------------------------ construction
    function test_Constructor_RevertsOnMainnetChainId() public {
        vm.chainId(8453);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioTestnetLaunchPool.WrongChain.selector, 8453)
        );
        new PossessioTestnetLaunchPool(owner, operator, STIPEND, COOLDOWN);
    }

    function test_Constructor_RevertsOnOwnerOperatorCollision() public {
        vm.expectRevert(PossessioTestnetLaunchPool.RoleSeparationViolation.selector);
        new PossessioTestnetLaunchPool(owner, owner, STIPEND, COOLDOWN);
    }

    function test_Constructor_RevertsOnZeroAddresses() public {
        vm.expectRevert(PossessioTestnetLaunchPool.ZeroAddress.selector);
        new PossessioTestnetLaunchPool(address(0), operator, STIPEND, COOLDOWN);
        vm.expectRevert(PossessioTestnetLaunchPool.ZeroAddress.selector);
        new PossessioTestnetLaunchPool(owner, address(0), STIPEND, COOLDOWN);
    }

    function test_OwnerRoleHash_MatchesProtocolConstant() public view {
        assertEq(pool.OWNER_ROLE(), PROTOCOL_OWNER_ROLE, "OWNER_ROLE drifted from protocol");
    }

    function test_NoHiddenAdmin_DefaultAdminRoleUnheld() public view {
        assertFalse(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), owner));
        assertFalse(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), operator));
        assertFalse(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(pool.getRoleAdmin(pool.OWNER_ROLE()), pool.OWNER_ROLE());
        assertEq(pool.getRoleAdmin(pool.OPERATOR_ROLE()), pool.OWNER_ROLE());
    }

    // ------------------------------------------------------------ refill
    function test_Receive_OpenRefill_AnyoneEmitsEvent() public {
        vm.deal(rando, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit PossessioTestnetLaunchPool.Refilled(rando, 0.5 ether);
        vm.prank(rando);
        (bool ok, ) = address(pool).call{value: 0.5 ether}("");
        assertTrue(ok);
    }

    // ------------------------------------------------------------ drawEth
    function test_DrawEth_OperatorOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                rando,
                pool.OPERATOR_ROLE()
            )
        );
        vm.prank(rando);
        pool.drawEth(alice);
    }

    function test_DrawEth_SendsStipend() public {
        uint256 before = alice.balance;
        vm.prank(operator);
        pool.drawEth(alice);
        assertEq(alice.balance - before, STIPEND);
    }

    function test_DrawEth_CooldownEnforced_WithHonestReadyAt() public {
        vm.prank(operator);
        pool.drawEth(alice);
        uint256 readyAt = block.timestamp + COOLDOWN;
        vm.expectRevert(
            abi.encodeWithSelector(PossessioTestnetLaunchPool.CooldownActive.selector, readyAt)
        );
        vm.prank(operator);
        pool.drawEth(alice);

        vm.warp(readyAt);
        vm.prank(operator);
        pool.drawEth(alice); // succeeds exactly at readyAt
    }

    function test_DrawEth_RevertsPoolEmpty() public {
        vm.startPrank(owner);
        pool.sweepEth(payable(alice)); // drain
        vm.stopPrank();
        vm.expectRevert(PossessioTestnetLaunchPool.PoolEmpty.selector);
        vm.prank(operator);
        pool.drawEth(rando);
    }

    // ------------------------------------------------------------ drawToken
    function test_DrawToken_NotEnabled_Reverts() public {
        address ghost = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(PossessioTestnetLaunchPool.TokenNotEnabled.selector, ghost)
        );
        vm.prank(operator);
        pool.drawToken(ghost, alice);
    }

    function test_DrawToken_SendsStipend() public {
        vm.prank(operator);
        pool.drawToken(address(usdc), alice);
        assertEq(usdc.balanceOf(alice), USDC_STIPEND);
    }

    function test_DrawEthAndToken_IndependentCooldowns_SameSession() public {
        // One launch needs gas AND fee back-to-back; cooldowns must not collide.
        vm.startPrank(operator);
        pool.drawEth(alice);
        pool.drawToken(address(usdc), alice);
        vm.stopPrank();
        assertEq(alice.balance, STIPEND);
        assertEq(usdc.balanceOf(alice), USDC_STIPEND);
    }

    // ------------------------------------------------------------ owner ops
    function test_Setters_OwnerOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                pool.OWNER_ROLE()
            )
        );
        vm.prank(operator);
        pool.setEthStipend(1 ether);
    }

    function test_SweepEth_OperatorDestinationBlocked() public {
        vm.expectRevert(PossessioTestnetLaunchPool.RoleSeparationViolation.selector);
        vm.prank(owner);
        pool.sweepEth(payable(operator));
    }

    function test_SweepToken_OperatorDestinationBlocked() public {
        vm.expectRevert(PossessioTestnetLaunchPool.RoleSeparationViolation.selector);
        vm.prank(owner);
        pool.sweepToken(address(usdc), operator);
    }
}
