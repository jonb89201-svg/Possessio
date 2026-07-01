// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
                      POSSESSIO SALT POOL
                    v0.1 - built to council spec
                  (SPEC_PossessioSaltPool.md)

  PURPOSE
    Holds pre-mined CREATE3 salts - each valid for the factory's
    fixed deployer address and satisfying the 0x8C8 hook-flag
    suffix - so a user deploy never waits on live mining.
    Factory pulls one salt per deploy. A keeper refills the pool
    off-chain. Deploy fees fund the keeper's mining cost (same
    self-funding shape as the x402 operating pool).

  ARCHITECTURAL INVARIANTS (must hold, not just compile)
    1. Pull is factory-only.
    2. Refill is keeper-only.
    3. Keeper is compute-only - structurally incapable of touching
       money. refillSalts accepts only bytes32[]; NO value-transfer
       path exists anywhere in this contract.
    4. Keeper is a distinct wallet from every money-destination
       address. Enforced at construction, not by convention.
    5. Empty-pool behavior is honest: pull on empty reverts
       PoolEmpty(). No fabricated salt, no silent degrade, no
       on-chain mining fallback.

  QUEUE ORDER
    LIFO (pop from end) - salts are fungible (any unused salt is
    as good as any other), so pull order doesn't matter
    functionally and LIFO is gas-cheaper than FIFO shifting.

  OPEN QUESTIONS - FLAGGED FOR COUNCIL, NOT DECIDED HERE
    (Q1, from spec §Refill) Should refillSalts validate each salt
        on-chain (recompute the CREATE3 address, confirm the 0x8C8
        suffix) before accepting it into the queue? Adds gas per
        refill; converts "keeper trusted to mine correctly" into
        "keeper trusted to try, contract verifies the result" - a
        strictly stronger guarantee. Council decision before freeze.
    (Q1b, cold-seat finding, distinct from Q1) Even with Q1's
        on-chain validation, each salt is only proven individually
        valid - nothing catches the keeper pushing the SAME salt
        twice. A duplicate is not a vulnerability HERE; it reverts
        one layer up when the factory attempts a second CREATE3
        deploy to an already-used deterministic address. Named
        separately so it is not assumed-solved by Q1's fix.
        Options if council wants it closed here: a consumed-salt
        mapping check at refill (gas per salt) or keeper-side
        dedup (off-chain, trusted). Council decision.
    (Q2, surfaced during build) The spec zero-checks only _factory
        and _keeper. If ALL THREE money-destination addresses are
        passed as zero, the Invariant-4 separation check becomes
        vacuous (keeper != 0 != 0 trivially). Should the
        constructor also reject zero for the three destinations,
        so the integrity check can never be satisfied trivially?
        Built to spec (no such check); flagged for council review.
    (Q3, cold-seat finding) The constructor never checks
        _keeper == _factory. The spec's invariants only require the
        keeper to be money-clean, and the factory is not a money
        destination in this contract - so keeper==factory may be
        acceptable. But it concentrates refill AND pull in one
        address (mine-your-own, consume-your-own, no separate
        pulling party). Currently SILENT, not decided.
        Characterized in test_Q3_KNOWN_LIMIT_*; council to decide
        whether to add the guard before freeze.

  NON-PROVEN until forge says so - see PossessioSaltPool.t.sol
  for the DoD suite. Cold-seat re-audit before ratification, per
  spec status line.
//////////////////////////////////////////////////////////////*/

contract PossessioSaltPool {
    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error KeeperIntegrityViolation();
    error UnauthorizedCall();
    error PoolEmpty();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every successful pull. `remaining` is the
    ///         queue depth AFTER this salt was removed.
    event SaltPulled(bytes32 salt, uint256 remaining);

    /// @notice Emitted on every successful refill. `newDepth` is the
    ///         queue depth AFTER the batch was added.
    event PoolRefilled(uint256 added, uint256 newDepth);

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice ONLY address permitted to pull salts.
    address public immutable factory;

    /// @notice ONLY address permitted to refill salts. Compute-only:
    ///         this contract offers the keeper no path to any value.
    address public immutable keeper;

    /// @dev Pre-mined, unused salts. LIFO via push/pop.
    bytes32[] private saltQueue;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
        Structural keeper separation (Invariant 4): the keeper is
        compute-only and must never coincide with any address that
        receives or moves pool/treasury funds elsewhere in the
        protocol. Enforced here, not assumed operationally - same
        discipline as the deploymentFeeSource / operator / treasury
        separation in PossessioX402Core.

        The three money-destination addresses are used ONLY for this
        constructor-time check. They are not stored and not
        referenced elsewhere - this contract has no money paths.
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _factory,
        address _keeper,
        address _operatorDestination,
        address _treasuryDestination,
        address _deploymentFeeSource
    ) {
        if (_factory == address(0) || _keeper == address(0)) {
            revert ZeroAddress();
        }

        if (
            _keeper == _operatorDestination ||
            _keeper == _treasuryDestination ||
            _keeper == _deploymentFeeSource
        ) revert KeeperIntegrityViolation();

        factory = _factory;
        keeper = _keeper;
    }

    /*//////////////////////////////////////////////////////////////
                        PULL (factory-only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Remove and return one pre-mined salt. Factory-only.
    /// @dev LIFO: returns the most recently pushed unconsumed salt.
    ///      Reverts PoolEmpty() on an empty queue - honest edge, no
    ///      fallback (keeper-side depth polling keeps this rare; see
    ///      spec Design Note - that policy is off-chain, not here).
    function pullSalt() external returns (bytes32 salt) {
        if (msg.sender != factory) revert UnauthorizedCall();
        if (saltQueue.length == 0) revert PoolEmpty();

        salt = saltQueue[saltQueue.length - 1];
        saltQueue.pop();

        emit SaltPulled(salt, saltQueue.length);
    }

    /*//////////////////////////////////////////////////////////////
                        REFILL (keeper-only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Batch-push newly mined salts. Keeper-only.
    /// @dev Accepts only bytes32 values - the keeper's entire
    ///      capability surface in this contract is "add salts."
    ///      No value transfer of any kind exists here (Invariant 3).
    ///      Salt validity (0x8C8 suffix under CREATE3) is currently
    ///      trusted to the keeper's off-chain mining - see OPEN
    ///      QUESTION Q1 in the header; council to decide before
    ///      freeze whether validation moves on-chain.
    function refillSalts(bytes32[] calldata newSalts) external {
        if (msg.sender != keeper) revert UnauthorizedCall();

        uint256 len = newSalts.length;
        for (uint256 i = 0; i < len; ) {
            saltQueue.push(newSalts[i]);
            unchecked { ++i; }
        }

        emit PoolRefilled(len, saltQueue.length);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPTH (public read - keeper's polling target)
    //////////////////////////////////////////////////////////////*/

    /// @notice Current number of unused salts in the pool.
    function depth() external view returns (uint256) {
        return saltQueue.length;
    }
}
