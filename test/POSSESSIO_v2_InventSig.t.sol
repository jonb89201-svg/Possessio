// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
    PRE-FREEZE HOOK EDIT — Council Signer coverage (council 2026-07-20)

  Exercises the three items built into PossessioHook's invent path:
    1. F3 amount-binding: executeInvent requires
       proposalHash == keccak256(abi.encode(address(this), amount, metadata)).
    2. approveInventBySig: gasless EIP-712 seat approval, replay-protected
       cross-deployment (domain) AND across re-propose (instance expiry).
    3. Execute-path replay (regression): a proposal executes at most once.

  Inherits the invariants harness (mocks + STEEL) and stands up a PARALLEL hook
  whose four council seats are KEYPAIRS (vm.addr) so signatures can be produced —
  the production seats (0x6584… etc.) have no known key.
//////////////////////////////////////////////////////////////*/

import {PossessioHook, STEEL} from "../src/POSSESSIO_v2-6-3.sol";
import {POSSESSIO_v2_Invariants_t} from "./POSSESSIO_v2_Invariants.t.sol";

contract POSSESSIO_v2_InventSig is POSSESSIO_v2_Invariants_t {
    PossessioHook internal sigHook;
    uint256[4] internal seatPk;
    address[4] internal seat;

    function setUp() public override {
        super.setUp(); // mocks + STEEL + the real-council hook

        for (uint256 i = 0; i < 4; i++) {
            seatPk[i] = uint256(keccak256(abi.encode("council-seat", i)));
            seat[i] = vm.addr(seatPk[i]);
        }
        address[4] memory council = [seat[0], seat[1], seat[2], seat[3]];

        PossessioHook.DeployParams memory params = PossessioHook.DeployParams({
            deployer:        deployer,
            steel:           address(steel),
            poolManager:     address(pm),
            treasury:        treasury,
            cbETH_:          address(cbeth),
            chainlinkCbETH:  address(cbethFeed),
            aeroRouter:      address(aeroRouter),
            weth:            address(weth),
            council:         council
        });
        vm.startPrank(deployer);
        sigHook = new PossessioHook(params);
        vm.stopPrank();

        _seedSig(100 ether);
    }

    // ---- helpers --------------------------------------------------------

    function _seedSig(uint256 amount) internal {
        vm.startPrank(deployer);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        steel.transfer(treasury, amount);
        vm.stopPrank();
        vm.startPrank(treasury);
        steel.approve(address(sigHook), amount);
        sigHook.savDeposit(amount);
        vm.stopPrank();
    }

    /// The canonical invent hash — the SAME formula the contract's binding uses.
    /// This function is the test-side "single source"; the cross-source parity
    /// proof is that a hash built here is accepted by executeInvent (happy path).
    function _inventHash(uint256 amount, bytes memory metadata) internal view returns (bytes32) {
        return keccak256(abi.encode(address(sigHook), amount, metadata));
    }

    /// OZ EIP-712 default domain for a hook (name "PossessioHook", version "1").
    function _domainSep(address hookAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PossessioHook")),
            keccak256(bytes("1")),
            block.chainid,
            hookAddr
        ));
    }

    /// Sign an ApproveInvent(proposalHash, expiry) for a given verifyingContract.
    function _signApproval(uint256 pk, bytes32 proposalHash, uint256 expiry, address hookAddr)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("ApproveInvent(bytes32 proposalHash,uint256 expiry)"),
            proposalHash, expiry
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSep(hookAddr), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _expiryOf(bytes32 hash) internal view returns (uint256 expiry) {
        (, expiry, ) = sigHook.proposals(hash);
    }

    // =====================================================================
    //  F3 AMOUNT-BINDING
    // =====================================================================

    function test_F3_executeWithBoundHash_succeeds() public {
        uint256 amount = 40 ether;
        bytes memory meta = "legitimate work item";
        bytes32 hash = _inventHash(amount, meta);

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        vm.prank(seat[0]); sigHook.approveInvent(hash);
        vm.prank(seat[1]); sigHook.approveInvent(hash);
        vm.prank(seat[2]); sigHook.approveInvent(hash);

        uint256 tBefore = steel.balanceOf(treasury);
        vm.prank(treasury);
        sigHook.executeInvent(amount, hash, meta);
        // cross-source parity: the hash built by _inventHash was accepted.
        assertEq(steel.balanceOf(treasury) - tBefore, amount, "bound execution transferred the amount");
    }

    function test_F3_executeWithMismatchedAmount_reverts() public {
        uint256 approved = 40 ether;
        bytes memory meta = "approved for 40";
        bytes32 hash = _inventHash(approved, meta);

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        vm.prank(seat[0]); sigHook.approveInvent(hash);
        vm.prank(seat[1]); sigHook.approveInvent(hash);
        vm.prank(seat[2]); sigHook.approveInvent(hash);

        // Architect tries to execute a DIFFERENT amount against the same hash.
        vm.prank(treasury);
        vm.expectRevert(PossessioHook.ProposalHashMismatch.selector);
        sigHook.executeInvent(50 ether, hash, meta);
    }

    function test_F3_executeWithMismatchedMetadata_reverts() public {
        uint256 amount = 40 ether;
        bytes32 hash = _inventHash(amount, "the approved reason");

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        vm.prank(seat[0]); sigHook.approveInvent(hash);
        vm.prank(seat[1]); sigHook.approveInvent(hash);
        vm.prank(seat[2]); sigHook.approveInvent(hash);

        vm.prank(treasury);
        vm.expectRevert(PossessioHook.ProposalHashMismatch.selector);
        sigHook.executeInvent(amount, hash, "a different reason");
    }

    function test_F3_replay_executesAtMostOnce() public {
        uint256 amount = 40 ether;
        bytes memory meta = "once";
        bytes32 hash = _inventHash(amount, meta);

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        vm.prank(seat[0]); sigHook.approveInvent(hash);
        vm.prank(seat[1]); sigHook.approveInvent(hash);
        vm.prank(seat[2]); sigHook.approveInvent(hash);

        vm.prank(treasury);
        sigHook.executeInvent(amount, hash, meta);

        // second execution of the same approved hash must revert (p.executed).
        vm.prank(treasury);
        vm.expectRevert(PossessioHook.ProposalAlreadyExecuted.selector);
        sigHook.executeInvent(amount, hash, meta);
    }

    // =====================================================================
    //  approveInventBySig — the gasless path + replay protection
    // =====================================================================

    function test_sig_fullFlow_bySig_thenExecute() public {
        uint256 amount = 40 ether;
        bytes memory meta = "gasless approvals";
        bytes32 hash = _inventHash(amount, meta);

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry = _expiryOf(hash);

        // three seats approve by signature; a random relayer submits each.
        for (uint256 i = 0; i < 3; i++) {
            bytes memory sig = _signApproval(seatPk[i], hash, expiry, address(sigHook));
            sigHook.approveInventBySig(hash, expiry, sig); // msg.sender is this test (a relayer)
        }
        (uint8 approvals,,) = sigHook.proposals(hash);
        assertEq(approvals, 3, "three gasless approvals recorded");

        uint256 tBefore = steel.balanceOf(treasury);
        vm.prank(treasury);
        sigHook.executeInvent(amount, hash, meta);
        assertEq(steel.balanceOf(treasury) - tBefore, amount, "executed after gasless quorum");
    }

    function test_sig_wrongDomain_reverts() public {
        uint256 amount = 40 ether;
        bytes32 hash = _inventHash(amount, "x");
        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry = _expiryOf(hash);

        // sign with the PARENT hook as verifyingContract — wrong deployment.
        bytes memory sig = _signApproval(seatPk[0], hash, expiry, address(hook));
        // recovered signer != any sigHook seat -> OnlyCouncilMember.
        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        sigHook.approveInventBySig(hash, expiry, sig);
    }

    function test_sig_rePropose_replayReverts() public {
        uint256 amount = 40 ether;
        bytes32 hash = _inventHash(amount, "x");

        // round 1
        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry1 = _expiryOf(hash);
        bytes memory sig1 = _signApproval(seatPk[0], hash, expiry1, address(sigHook));

        // let round 1 expire, re-propose (round 2 gets a fresh expiry)
        vm.warp(block.timestamp + 31 days);
        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry2 = _expiryOf(hash);
        assertTrue(expiry2 != expiry1, "re-propose changed the instance expiry");

        // replay the captured round-1 signature -> instance-scope check catches it.
        vm.expectRevert(PossessioHook.StaleApprovalSignature.selector);
        sigHook.approveInventBySig(hash, expiry1, sig1);
    }

    function test_sig_nonCouncilSigner_reverts() public {
        uint256 amount = 40 ether;
        bytes32 hash = _inventHash(amount, "x");
        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry = _expiryOf(hash);

        uint256 strangerPk = uint256(keccak256("not-a-seat"));
        bytes memory sig = _signApproval(strangerPk, hash, expiry, address(sigHook));
        vm.expectRevert(PossessioHook.OnlyCouncilMember.selector);
        sigHook.approveInventBySig(hash, expiry, sig);
    }

    function test_sig_doubleApprove_reverts() public {
        uint256 amount = 40 ether;
        bytes32 hash = _inventHash(amount, "x");
        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry = _expiryOf(hash);

        bytes memory sig = _signApproval(seatPk[0], hash, expiry, address(sigHook));
        sigHook.approveInventBySig(hash, expiry, sig);
        // same seat, same round -> AlreadyApproved.
        vm.expectRevert(PossessioHook.AlreadyApproved.selector);
        sigHook.approveInventBySig(hash, expiry, sig);
    }

    function test_sig_mixedDirectAndBySig_reachesThreshold() public {
        uint256 amount = 40 ether;
        bytes memory meta = "mixed quorum";
        bytes32 hash = _inventHash(amount, meta);

        vm.prank(seat[0]); sigHook.proposeInvent(hash);
        uint256 expiry = _expiryOf(hash);

        // seat 0 direct, seats 1 & 2 by sig — a seat that voted direct cannot
        // also vote by sig (hasApproved dedup).
        vm.prank(seat[0]); sigHook.approveInvent(hash);
        bytes memory sig0 = _signApproval(seatPk[0], hash, expiry, address(sigHook));
        vm.expectRevert(PossessioHook.AlreadyApproved.selector);
        sigHook.approveInventBySig(hash, expiry, sig0);

        sigHook.approveInventBySig(hash, expiry, _signApproval(seatPk[1], hash, expiry, address(sigHook)));
        sigHook.approveInventBySig(hash, expiry, _signApproval(seatPk[2], hash, expiry, address(sigHook)));

        (uint8 approvals,,) = sigHook.proposals(hash);
        assertEq(approvals, 3, "direct + bySig both count once per seat");

        vm.prank(treasury);
        sigHook.executeInvent(amount, hash, meta); // reaches threshold, executes
    }
}
