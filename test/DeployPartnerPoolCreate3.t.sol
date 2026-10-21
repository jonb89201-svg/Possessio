// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  The partner pool deploy script's own checks, tested like contract code
    through a harness. No test broadcasts or needs a key. */

import "forge-std/Test.sol";
import {DeployPartnerPoolCreate3} from "../script/DeployPartnerPoolCreate3.s.sol";
import {DeployFactoryCreate3} from "../script/DeployFactoryCreate3.s.sol";

contract PartnerPoolHarness is DeployPartnerPoolCreate3 {
    function partnerDestination(bool allowStub) external view returns (address) { return _partnerDestination(allowStub); }
    function requireContract(address dest) external view { _requireContract(dest); }
}

contract DeployPartnerPoolCreate3Test is Test {
    PartnerPoolHarness h;

    function setUp() public {
        h = new PartnerPoolHarness();
    }

    /// One test, in sequence, because PARTNER_DEST_ADDR is process-wide. The stub
    /// permission is a flag here, read from ALLOW_STUB_PARTNER only in run().
    function test_partnerDestination_realSafeOrAnExplicitStub() public {
        address safe = makeAddr("another-safe");
        address stub = h.PARTNER_DEST_STUB();

        // Unset: the partner's own Safe, as supplied on 2026-10-21, is the default.
        assertEq(h.partnerDestination(false), h.KUPIASEC_SAFE());
        assertEq(h.KUPIASEC_SAFE(), 0xD72Ac0679B7A6Dea42457A79769fB5E4e4D3eeEb);

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(safe));   // an override: accepted here, run() then requires code
        assertEq(h.partnerDestination(false), safe);

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(address(0)));
        vm.expectRevert(DeployPartnerPoolCreate3.PartnerDestinationMissing.selector);
        h.partnerDestination(false);                          // no address: refused

        vm.setEnv("PARTNER_DEST_ADDR", vm.toString(stub));
        vm.expectRevert(abi.encodeWithSelector(DeployPartnerPoolCreate3.StubPartnerDestination.selector, stub));
        h.partnerDestination(false);                          // the stub, not stated: refused

        assertEq(h.partnerDestination(true), stub);           // the stub, stated: staging may proceed
    }

    /// run() refuses a destination without code: a Safe is a contract, an EOA or
    /// a typo is not. The stub is exempt there (it is refused or logged on its own).
    function test_requireContract_refusesAnAddressWithoutCode() public {
        address eoa = makeAddr("typed-wrong");
        vm.expectRevert(abi.encodeWithSelector(DeployPartnerPoolCreate3.PartnerDestinationHasNoCode.selector, eoa));
        h.requireContract(eoa);

        vm.etch(eoa, hex"6000");                               // now a contract: accepted
        h.requireContract(eoa);
    }

    /// Both scripts name the same stub, so the factory pre-flight recognises the
    /// pool this script deploys.
    function test_stub_isTheSameInBothScripts() public {
        DeployFactoryCreate3 f = new DeployFactoryCreate3();
        assertEq(h.PARTNER_DEST_STUB(), f.PARTNER_DEST_STUB());
        assertEq(h.PARTNER_DEST_STUB(), 0x0000000000000000000000000000000000005aFE);
    }
}
