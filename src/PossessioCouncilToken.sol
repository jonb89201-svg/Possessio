// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/*//////////////////////////////////////////////////////////////
                 POSSESSIO COUNCIL TOKEN
              v0.1 - built to council spec
        (SPEC_CouncilToken.md §1 / §6 / §11.3 / §0 creed)

  The settlement asset of the council economy (§1): the base pair
  every V3 launch initializes against (enforced by
  PossessioLaunchFactory, not by this contract), and the unit
  council-to-council primitive trade denominates in (§6).

  §11.3 DEFAULT POSITION, EMBODIED: the token carries NO fee
  mechanics, no hooks, no reflection, no tax. It is a clean
  denominator - fee engines belong to LAUNCHES (the owner's 2%
  hook), never to the settlement asset. A market's measuring
  stick must not bend with each measurement.

  NUMBERS ARE NOT INVENTED HERE (spec §8 / §11.4): supply,
  distribution, name and symbol are CONSTRUCTOR PARAMETERS -
  stated in full in the deploy transaction, ratified by the
  Architect at broadcast, immutable after. The contract is the
  machine; the numbers arrive with the Architect's signature.

  CREED CHECK (§0, in order):
    1. Non-extraction: no fee on transfer, no tax, no skim. The
       token takes nothing from anyone, ever.
    2. Sovereignty: no owner, no admin, no minter, no pauser, no
       blacklist, no upgrade path. After construction the ONLY
       authorities are holders over their own balances (transfer,
       approve, permit, burn). Enforced by absence of code.
    3. Immutable & deterministic: fixed supply minted once at
       construction to a distribution stated in calldata; total
       supply can only ever decrease (holder burns). CREATE3-
       deployable for an address predictable before it exists.
    4. On-chain transparency: the entire genesis distribution is
       readable from the deploy transaction forever; DistributionMinted
       events emit every (recipient, amount) pair at birth.

  SEAT ALLOCATIONS (§6): this contract does NOT touch SAV or any
  allocation math. If council seats receive council tokens, they
  appear as ordinary genesis recipients in the ratified
  distribution - visible, equal-treatment, nothing special-cased.
  Rule 6 (Architect ratification of seat-directed transactions)
  is custody policy, enforced at the key layer, not here.

  EIP-2612 PERMIT: included for the settlement rail - agent
  commerce (x402-style flows) settles better with signature-based
  approvals than with two-transaction approve/transferFrom. Adds
  zero authority surface: only a holder's own signature moves a
  holder's own allowance.

  NON-PROVEN until forge says so - see PossessioCouncilToken.t.sol.
  Cold-seat re-audit before ratification. Deploy gated on §9
  sequencing and §3 pool-funding provenance.
//////////////////////////////////////////////////////////////*/

contract PossessioCouncilToken is ERC20, ERC20Permit {
    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error EmptyDistribution();
    error LengthMismatch();
    error ZeroRecipient();
    error ZeroAmount();
    error DuplicateRecipient(address recipient);

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice One event per genesis recipient - the full distribution,
    ///         on the record at birth (creed §0.4).
    event DistributionMinted(address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param name_       Token name (Architect-ratified at broadcast).
    /// @param symbol_     Token symbol (Architect-ratified at broadcast).
    /// @param recipients  Genesis distribution addresses. No duplicates,
    ///                    no zeros - every entry is a deliberate line in
    ///                    the ratified table.
    /// @param amounts     Genesis amounts (18 decimals), one per recipient,
    ///                    all nonzero. Total supply = the exact sum; no
    ///                    hidden remainder, no deployer default.
    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory recipients,
        uint256[] memory amounts
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyDistribution();
        if (n != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < n; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            if (to == address(0)) revert ZeroRecipient();
            if (amount == 0) revert ZeroAmount();
            // O(n^2) duplicate guard - genesis tables are short and a
            // duplicate line in a ratified distribution is a drafting
            // error that must fail the deploy, not merge two lines.
            for (uint256 j = 0; j < i; j++) {
                if (recipients[j] == to) revert DuplicateRecipient(to);
            }
            _mint(to, amount);
            emit DistributionMinted(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                      HOLDER-ONLY SUPPLY REDUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn from the caller's own balance. The only supply
    ///         change possible after construction, and only downward,
    ///         and only by a holder over their own tokens (creed §0.2).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
