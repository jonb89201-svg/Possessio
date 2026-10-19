// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  The partner pool deploy script's own checks, tested like contract code
    through a harness. No test broadcasts or needs a key. */

import "forge-std/Test.sol";
import {DeployPartnerPoolCreate3} from "../script/DeployPartnerPoolCreate3.s.sol";
import {DeployFactoryCreate3} from "../script/DeployFactoryCreate3.s.sol";

contract PartnerPoolHarness is DeployPartnerPoolCreate3 {
    function partnerDestination(bool allowStub) external view returns (address) { return _partnerDestination(allowStub); }
}

contract DeployPartnerPoolCreate3Test is Test {
    PartnerPoolHarness h;

    function setUp() public {
        h = new PartnerPoolHarness();
    }

    /// One test, in sequence, because PARTNER_DEST_ADDR is process-wide. The stub
    /// permission is a flag here, read from ALLOW_STUB_PARTNER only in run().
    function test_partnerDestination_realSafeOrAnExplicitStub() public {
        address safe = makeAddr("kupiasec-safe");
        address stub = h.PARTNER_DEST_STUB();

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(safe));   // the partner's Safe: accepted
        assertEq(h.partnerDestination(false), safe);

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(address(0)));
        vm.expectRevert(DeployPartnerPoolCreate3.PartnerDestinationMissing.selector);
        h.partnerDestination(false);                          // no address: refused

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(stub));
        vm.expectRevert(abi.encodeWithSelector(DeployPartnerPoolCreate3.StubPartnerDestination.selector, stub));
        h.partnerDestination(false);                          // the stub, not stated: refused

        assertEq(h.partnerDestination(true), stub);           // the stub, stated: staging may proceed
    }

    /// Both scripts name the same stub, so the factory pre-flight recognises the
    /// pool this script deploys.
    function test_stub_isTheSameInBothScripts() public {
        DeployFactoryCreate3 f = new DeployFactoryCreate3();
        assertEq(h.PARTNER_DEST_STUB(), f.PARTNER_DEST_STUB());
        assertEq(h.PARTNER_DEST_STUB(), 0x0000000000000000000000000000000000005aFE);
    }
}
