// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PossessioPayments} from "../src/PossessioPayments.sol";

/// @notice Construction helper for the FACTORY-SHAPED Account constructor.
///
///         PossessioPayments takes `(address owner, bytes initArgs)` because
///         PossessioFactory appends exactly that to a pinned template's
///         initCode (PossessioFactory.sol:256). Tests still want to express a
///         configuration as a `DeployParams` struct, so this free function
///         performs the same encode the factory does.
///
///         It deliberately mirrors the factory: `p.owner` is passed as the
///         first argument, which is the value the constructor honours, and the
///         copy inside `initArgs` is discarded. Every test therefore exercises
///         the REAL constructor path a launched Account will take — not a
///         convenience overload that only exists in tests.
function deployPayments(PossessioPayments.DeployParams memory p)
    returns (PossessioPayments)
{
    return new PossessioPayments(p.owner, abi.encode(p));
}
