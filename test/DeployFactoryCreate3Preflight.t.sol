// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployFactoryCreate3} from "../script/DeployFactoryCreate3.s.sol";

/*//////////////////////////////////////////////////////////////
        DEPLOY SCRIPT PRE-FLIGHT (review 2026-10-17, F-2 / F-6 / F-7)
        The CREATE3 deploy is one shot at a permanent address, so the
        script's checks are tested like contract code. No test calls
        run(): it needs the anchor key. The checks are exposed through a
        harness and exercised against mock pools.
//////////////////////////////////////////////////////////////*/

/// A pool stand-in with every probe the pre-flight reads made settable.
contract PreflightPool {
    bool public infra = true;
    uint256 public FLOOR_PER_UNIT;
    mapping(address => bool) public isAuthorizedSource;
    constructor(uint256 fpu) { FLOOR_PER_UNIT = fpu; }
    function isInfraSink() external view returns (bool) { return infra; }
    function setInfra(bool v) external { infra = v; }
    function authorize(address who) external { isAuthorizedSource[who] = true; }
}

/// Has code, but none of the pool's doors.
contract PreflightNoDoor {
    uint256 public x;
}

contract PreflightHarness is DeployFactoryCreate3 {
    function partnerConfig() external view returns (address, uint256) { return _partnerConfig(); }
    function livePool(address pool) external view { _requireLivePool(pool); }
    function cutClearsFloor(address pool, uint256 cut) external view { _requireCutClearsFloor(pool, cut); }
    function predicted() external pure returns (address) { return PREDICTED_FACTORY; }
}

contract DeployFactoryCreate3PreflightTest is Test {
    PreflightHarness h;
    address factory;

    function setUp() public {
        h = new PreflightHarness();
        factory = h.predicted();
    }

    /// One test, in sequence, because env vars are process-wide.
    function test_preflight_partnerIsAnExplicitYesOrNo() public {
        address sink = makeAddr("partner-pool");
        vm.setEnv("PARTNER_SINK_ADDR", vm.toString(sink));
        vm.setEnv("PARTNER_BPS", "5000");

        vm.setEnv("WITH_PARTNER", "false");                 // no: the partner vars are ignored
        (address s, uint256 b) = h.partnerConfig();
        assertEq(s, address(0));
        assertEq(b, 0);

        vm.setEnv("WITH_PARTNER", "true");                  // yes: both are read
        (s, b) = h.partnerConfig();
        assertEq(s, sink);
        assertEq(b, 5000);

        vm.setEnv("PARTNER_BPS", "0");                      // yes, but a zero share: refused
        vm.expectRevert(abi.encodeWithSelector(DeployFactoryCreate3.PartnerConfigIncomplete.selector, sink, 0));
        h.partnerConfig();

        vm.setEnv("PARTNER_BPS", "5000");
        vm.setEnv("PARTNER_SINK_ADDR", vm.toString(address(0)));
        vm.expectRevert(abi.encodeWithSelector(DeployFactoryCreate3.PartnerConfigIncomplete.selector, address(0), 5000));
        h.partnerConfig();                                  // yes, but no pool: refused

        vm.setEnv("WITH_PARTNER", "");                      // not stated: refuses to run (F-2)
        vm.expectRevert();
        h.partnerConfig();

        vm.setEnv("WITH_PARTNER", "maybe");                 // not a yes or a no: refuses to run
        vm.expectRevert();
        h.partnerConfig();
    }

    function test_preflight_refusesAnAddressWithoutCode() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(DeployFactoryCreate3.FeeSinkPoolNotLive.selector, eoa));
        h.livePool(eoa);
    }

    function test_preflight_refusesCodeWithoutTheDoor() public {
        address noDoor = address(new PreflightNoDoor());
        vm.expectRevert(abi.encodeWithSelector(DeployFactoryCreate3.PoolInterfaceMismatch.selector, noDoor));
        h.livePool(noDoor);
    }

    function test_preflight_refusesAPoolThatDeniesTheDoor() public {
        PreflightPool pool = new PreflightPool(1);
        pool.authorize(factory);
        pool.setInfra(false);
        vm.expectRevert(abi.encodeWithSelector(DeployFactoryCreate3.PoolInterfaceMismatch.selector, address(pool)));
        h.livePool(address(pool));
    }

    /// F-7: the constructor's F-L3 check, run before the one-shot deploy.
    function test_preflight_refusesAPoolThatRefusesTheFactory() public {
        PreflightPool pool = new PreflightPool(1);
        pool.authorize(makeAddr("some-other-factory"));
        vm.expectRevert(
            abi.encodeWithSelector(DeployFactoryCreate3.PoolRefusesFactory.selector, address(pool), factory)
        );
        h.livePool(address(pool));
    }

    function test_preflight_acceptsALivePoolThatListsTheFactory() public {
        PreflightPool pool = new PreflightPool(1);
        pool.authorize(factory);
        h.livePool(address(pool));                          // no revert
    }

    /// F-6: a cut below the pool's dust gate never raises its floor.
    function test_preflight_cutMustClearTheFloorUnit() public {
        PreflightPool pool = new PreflightPool(1_000_000);  // $1 per unit
        vm.expectRevert(
            abi.encodeWithSelector(DeployFactoryCreate3.CutBelowFloorUnit.selector, address(pool), 999_999, 1_000_000)
        );
        h.cutClearsFloor(address(pool), 999_999);
        h.cutClearsFloor(address(pool), 1_000_000);         // equal clears the gate
        h.cutClearsFloor(address(pool), 50_000_000);
    }
}
