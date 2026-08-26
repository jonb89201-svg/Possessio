// SPDX-License-Identifier: MIT
// BUILD-PROOF: TEMPLATE_CODEHASH_PROBE_V1 — measures, in the CI terminal, the
// production-toolchain codehash of the FIXED PossessioPayments.
//
// WHY. The redeploy factory pins TEMPLATE_CODEHASH = keccak256(
// type(PossessioPayments).creationCode). That value is toolchain-dependent: this
// repo builds with via_ir, and creationCode differs between solc 0.8.27 (the web
// session's local compiler) and solc 0.8.35 (the production/CI compiler). The
// dry-run (test/StageRedeployDryRun.t.sol) logged the 0.8.27 value, which MUST
// NOT be shipped. This probe surfaces the 0.8.35 value in the `forge (solidity)`
// job log (which runs `forge test -vv`, so a passing test's console2 logs print),
// so the redeploy TEMPLATE_CODEHASH is a MEASURED number, not a placeholder.
//
// This does NOT assert against any pin (unlike GenTemplateArtifact.s.sol, which
// is a drift-guard hardwired to the OLD factory 0x0DD0… and reverts on change).
// The fixed Payments is EXPECTED to hash to a new value — that is the point of
// the redeploy. This probe just reports it.
//
// READ IT: grep the forge job log for TEMPLATE_CODEHASH_0835.

pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PossessioPayments} from "../src/PossessioPayments.sol";

contract TemplateCodehashProbe is Test {
    function test_probe_paymentsCreationCodehash() public pure {
        bytes memory cc = type(PossessioPayments).creationCode;
        bytes32 h = keccak256(cc);
        console2.log("TEMPLATE_CODEHASH_0835 creationCode bytes:", cc.length);
        console2.log("TEMPLATE_CODEHASH_0835 keccak256(creationCode):");
        console2.logBytes32(h);
        // Sanity floor only: a non-empty creation code. No pin assertion.
        assertGt(cc.length, 0, "creationCode must be non-empty");
    }
}
