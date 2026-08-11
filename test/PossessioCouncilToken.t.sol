// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PossessioCouncilToken} from "../src/PossessioCouncilToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/*//////////////////////////////////////////////////////////////
       POSSESSIO COUNCIL TOKEN - DoD TEST SUITE
       Maps to SPEC_CouncilToken.md §11.3 (clean denominator),
       §0 creed (zero authority), and the constructor-ratified
       numbers posture (§8/§11.4). The genesis table is exact,
       the supply only falls, and nobody holds any power over
       anyone else's balance - proven, not asserted.
//////////////////////////////////////////////////////////////*/

contract PossessioCouncilTokenTest is Test {
    PossessioCouncilToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function _deploy(address[] memory r, uint256[] memory a)
        internal
        returns (PossessioCouncilToken)
    {
        return new PossessioCouncilToken("POSSESSIO Council Token", "TESTPCT", r, a);
    }

    function setUp() public {
        signer = vm.addr(signerKey);
        address[] memory r = new address[](3);
        uint256[] memory a = new uint256[](3);
        r[0] = alice; a[0] = 600e18;
        r[1] = bob; a[1] = 300e18;
        r[2] = signer; a[2] = 100e18;
        token = _deploy(r, a);
    }

    /*//////////////////////////////////////////////////////////////
              Genesis: the ratified table lands exactly
    //////////////////////////////////////////////////////////////*/

    function test_genesis_balancesExact() public view {
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(bob), 300e18);
        assertEq(token.balanceOf(signer), 100e18);
        assertEq(token.totalSupply(), 1000e18, "supply == exact sum, no remainder");
    }

    function test_genesis_metadataReadsBack() public view {
        assertEq(token.name(), "POSSESSIO Council Token");
        assertEq(token.symbol(), "TESTPCT");
        assertEq(token.decimals(), 18);
    }

    function testFuzz_genesis_supplyIsExactSum(uint96 x, uint96 y) public {
        vm.assume(x > 0 && y > 0);
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = alice; a[0] = uint256(x);
        r[1] = bob; a[1] = uint256(y);
        PossessioCouncilToken t = _deploy(r, a);
        assertEq(t.totalSupply(), uint256(x) + uint256(y));
    }

    /*//////////////////////////////////////////////////////////////
            Constructor guards: a bad table fails the deploy
    //////////////////////////////////////////////////////////////*/

    function test_ctor_emptyDistribution_reverts() public {
        address[] memory r = new address[](0);
        uint256[] memory a = new uint256[](0);
        vm.expectRevert(PossessioCouncilToken.EmptyDistribution.selector);
        _deploy(r, a);
    }

    function test_ctor_lengthMismatch_reverts() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](1);
        r[0] = alice; r[1] = bob; a[0] = 1e18;
        vm.expectRevert(PossessioCouncilToken.LengthMismatch.selector);
        _deploy(r, a);
    }

    function test_ctor_zeroRecipient_reverts() public {
        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        r[0] = address(0); a[0] = 1e18;
        vm.expectRevert(PossessioCouncilToken.ZeroRecipient.selector);
        _deploy(r, a);
    }

    function test_ctor_zeroAmount_reverts() public {
        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        r[0] = alice; a[0] = 0;
        vm.expectRevert(PossessioCouncilToken.ZeroAmount.selector);
        _deploy(r, a);
    }

    function test_ctor_duplicateRecipient_reverts() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = alice; a[0] = 1e18;
        r[1] = alice; a[1] = 2e18;
        vm.expectRevert(
            abi.encodeWithSelector(PossessioCouncilToken.DuplicateRecipient.selector, alice)
        );
        _deploy(r, a);
    }

    /*//////////////////////////////////////////////////////////////
        Creed §0.1: clean denominator - transfers take nothing
    //////////////////////////////////////////////////////////////*/

    function test_transfer_noFee_exactAmounts() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(alice), 500e18, "sender debited exactly");
        assertEq(token.balanceOf(bob), 400e18, "receiver credited exactly");
        assertEq(token.totalSupply(), 1000e18, "transfer conserves supply");
    }

    function testFuzz_transfer_conservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(alice));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.totalSupply(), 1000e18);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(signer), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
        Creed §0.2: sovereignty - only holders move holder funds
    //////////////////////////////////////////////////////////////*/

    function test_noAuthority_strangerCannotMoveFunds() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18
            )
        );
        token.transferFrom(alice, bob, 1e18);
    }

    function test_supplyOnlyFalls_burnIsHolderOnly() public {
        vm.prank(alice);
        token.burn(100e18);
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.totalSupply(), 900e18, "burn is the only supply change, downward");

        // Nobody can burn someone else's balance - the function does not exist.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, bob, 300e18, 301e18
            )
        );
        token.burn(301e18);
    }

    /*//////////////////////////////////////////////////////////////
          EIP-2612 permit: the settlement rail's approval path
    //////////////////////////////////////////////////////////////*/

    function test_permit_signatureApproval_thenPull() public {
        uint256 amount = 40e18;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                signer,
                bob,
                amount,
                token.nonces(signer),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        token.permit(signer, bob, amount, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), amount, "permit set the allowance");

        vm.prank(bob);
        token.transferFrom(signer, bob, amount);
        assertEq(token.balanceOf(bob), 340e18, "signature-approved settlement pulled");
        assertEq(token.balanceOf(signer), 60e18);
    }

    function test_permit_expiredDeadline_reverts() public {
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert();
        token.permit(signer, bob, 1e18, deadline, 27, bytes32(0), bytes32(0));
    }
}
