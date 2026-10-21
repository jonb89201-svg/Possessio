// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  The partner's Safe, as the partner pool script names it, read on Base mainnet:
    it must be a contract whose singleton is SafeL2 1.4.1, report VERSION "1.4.1",
    and hold a multi-owner threshold. Gated on BASE_RPC_URL (skips when unset). RUN:
      BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/PartnerSafeFork.t.sol -vv */

import "forge-std/Test.sol";
import {DeployPartnerPoolCreate3} from "../script/DeployPartnerPoolCreate3.s.sol";

interface ISafeProbe {
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

contract PartnerSafeForkTest is Test {
    /// Safe's canonical SafeL2 v1.4.1 singleton, the same address on every chain.
    address constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    function test_fork_partnerSafe_isASafeOnBase() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        require(block.chainid == 8453, "not Base");

        address safe = new DeployPartnerPoolCreate3().KUPIASEC_SAFE();
        assertGt(safe.code.length, 0, "partner destination has no code on Base");
        // A Safe proxy keeps its singleton in storage slot 0.
        assertEq(address(uint160(uint256(vm.load(safe, bytes32(0))))), SAFE_L2_141, "singleton is not SafeL2 1.4.1");
        assertEq(ISafeProbe(safe).VERSION(), "1.4.1");

        uint256 threshold = ISafeProbe(safe).getThreshold();
        uint256 owners    = ISafeProbe(safe).getOwners().length;
        assertGe(threshold, 2, "a one-signature Safe is not a multisig");
        assertGe(owners, threshold, "fewer owners than the threshold");
        emit log_named_address("partner Safe", safe);
        emit log_named_uint("threshold", threshold);
        emit log_named_uint("owners", owners);
    }
}
