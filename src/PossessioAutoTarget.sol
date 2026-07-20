// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////
                      POSSESSIO AUTO-TARGET
                 v0.1 - built to spec (SPEC_AutoTarget.md)

  Human-pick, rule-exit, pay-per-trade. The AI radar pre-screens a live
  board; the human picks ONE candidate and clicks a target button; a hard
  -10% stop is ALWAYS attached; the user pays a per-transaction fee. A
  bounded keeper fires the deterministic exit trigger when price crosses
  target or stop.

  DELIBERATE INVERSION OF THE AUTOMATED LOOP: the forward ledger proved the
  unattended entry+exit loop loses (avg -9.1%, no edge, gaps to -82%). This
  contract does NOT automate the trade. It records the human's pick + rule
  immutably, charges the fee on-chain (provable revenue), and authorizes the
  exit mechanically. The losing part - the loop deciding what to buy - is gone.

  ARCHITECTURAL INVARIANTS (structural, not conventions)
    1. STOP IS UN-REMOVABLE. Every Intent has stopBps == STOP_BPS (1000). No
       parameter, setter, or code path sets it otherwise. resolveIntent
       enforces the stop even on a +50% target.
    2. NON-CUSTODIAL. This contract never calls transfer/transferFrom on the
       traded `token`. The only asset it touches is the transient per-tx USDC
       fee, routed to the Heart in the SAME tx -> its USDC balance is 0 after
       every openIntent. It is a trigger + fee + discipline layer, not custody.
    3. FEE ATOMICITY. If the Heart route reverts (this contract not an
       authorized source, or a Heart bug), the whole openIntent unwinds - the
       user is NEVER charged for a failed open (same law as the factory edit).
    4. FRONT-RUN-CLOSED FEE. to == address(this) in the EIP-3009 auth; no
       third party can settle the user's authorization elsewhere.
    5. KEEPER IS TRIGGER-ONLY. The keeper can resolveIntent (emit an authorized
       exit) but has NO authority over funds here. Worst case a rogue keeper
       emits a premature/late trigger, which the on-chain target/stop math
       price-gates (NotTriggered); the swap rail applies its own slippage bound.
    6. LINEAR LIFECYCLE. An Open intent goes to exactly one of Resolved (then
       Executed) or Cancelled. Executed/Cancelled are terminal - no re-fire,
       no double-exit. resolveIntent needs Open; markExecuted needs Resolved.

  The token->USDC SWAP is NOT in this contract. It runs KEEPER-SIDE via the
  user's bounded, revocable Base-Account spend permission + a DEX (Option A,
  keeper-side - SPEC_AutoTarget.md §3), driven by the ExitAuthorized trigger;
  the keeper then calls markExecuted to record the proceeds on-chain. This keeps
  the contract non-custodial (it never touches the traded token) and free of
  DEX/MEV surface. The -10% stop is a THRESHOLD, not a fill guarantee: on a rug
  the rail fills worse. This contract enforces discipline and speed of trigger;
  it cannot beat gapping liquidity (SPEC_AutoTarget.md §6).

  NON-PROVEN until forge says so - see PossessioAutoTarget.t.sol (DoD),
  PossessioAutoTargetAdversarial.t.sol, PossessioAutoTargetFork.t.sol.
//////////////////////////////////////////////////////////////*/

interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @notice The Heart's accounted inflow door (Option A). This contract approves
///         and the Heart PULLS the fee, crediting poolBalance. A raw push would
///         strand it (the pool has no sync door, Pool DoD #14).
interface IPossessioPool {
    function receiveInfraFunds(uint256 amount) external;
    function isInfraSink() external view returns (bool);
}

contract PossessioAutoTarget is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroFee();
    error FeeSinkInterfaceMismatch();
    error ZeroTokenRef();
    error ZeroChainTag();
    error ZeroEntryPrice();
    error ZeroPrice();
    error BadTarget(uint16 got);
    error NotKeeper(address caller);
    error NotIntentOwner(address caller);
    error IntentNotOpen(uint256 id);
    error IntentNotResolved(uint256 id);
    error NotTriggered(uint256 observedPrice, uint256 targetPrice, uint256 stopPrice);
    error UnknownIntent(uint256 id);

    /*//////////////////////////////////////////////////////////////
                        FEE AUTHORIZATION (EIP-3009)
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-3009 `receiveWithAuthorization` parameters for the caller's
    ///         USDC fee. `from` is msg.sender and `to` is this contract (both
    ///         fixed by openIntent, not passed here).
    struct FeeAuth {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The always-on stop, in basis points below entry (10%). Applied to
    ///         EVERY intent regardless of the target chosen. Invariant 1.
    uint16 public constant STOP_BPS = 1000;

    uint16 private constant BPS = 10_000;

    // The three target buttons (bps above entry). No other target is accepted.
    uint16 private constant TARGET_SCALP = 1000; // +10%
    uint16 private constant TARGET_MID = 2500; // +25%
    uint16 private constant TARGET_HIGH = 5000; // +50%

    /// @notice Chain tags for `Intent.chainTag`. This contract does NOT interpret
    ///         them — it records them as opaque routing metadata the keeper reads
    ///         to pick the right rail (EVM Base-Account spend permission, or a
    ///         Solana SPL delegate). EVM chains use their chainId; Solana uses the
    ///         SPL cluster id. One Base ledger, many chains (SPEC_AutoTarget §3).
    uint32 public constant CHAIN_BASE = 8453; // Base mainnet (EVM rail)
    uint32 public constant CHAIN_SOLANA = 101; // Solana mainnet-beta (SPL cluster id)

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC as EIP-3009 (fee settle) and as ERC20 (Heart route).
    IERC3009 public immutable payToken;
    IERC20 public immutable payTokenERC20;

    /// @notice The Heart the per-tx fee is routed INTO via receiveInfraFunds
    ///         (Option A). Must be in the Heart's authorizedSources or every
    ///         openIntent reverts (Invariant 3).
    address public immutable feeSink;

    /// @notice Bounded trigger authority. Can resolveIntent; has NO fund
    ///         authority here (Invariant 5). Compute-only, like the salt keeper.
    address public immutable keeper;

    /// @notice The fixed per-transaction fee, in USDC (6 decimals). No setter.
    uint256 public immutable PER_TX_FEE;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    enum Status {
        None,
        Open,
        Resolved,
        Executed,
        Cancelled
    }

    enum ExitKind {
        None,
        Target,
        Stop
    }

    struct Intent {
        address user;
        bytes32 tokenRef; // the picked token: a padded EVM address OR a Solana mint pubkey
        uint32 chainTag; // which chain the token lives on (keeper routes on this)
        uint256 entryPrice;
        uint16 targetBps;
        uint16 stopBps;
        Status status;
        ExitKind exitKind;
        uint256 usdcReturned; // set at markExecuted — the on-chain proceeds receipt
    }

    /// @notice Intent registry. id 0 is never used (ids start at 1).
    mapping(uint256 => Intent) public intents;

    /// @notice Monotonic id counter; also the total intents ever opened.
    uint256 public intentCount;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event IntentOpened(
        uint256 indexed id,
        address indexed user,
        bytes32 indexed tokenRef,
        uint32 chainTag,
        uint256 entryPrice,
        uint16 targetBps
    );
    event FeeRouted(uint256 indexed id, uint256 amount);
    event ExitAuthorized(uint256 indexed id, ExitKind kind, uint256 observedPrice);
    event ExitExecuted(uint256 indexed id, ExitKind kind, uint256 usdcReturnedToUser);
    event IntentCancelled(uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _payToken, address _feeSink, address _keeper, uint256 _perTxFee) {
        if (_payToken == address(0) || _feeSink == address(0) || _keeper == address(0)) {
            revert ZeroAddress();
        }
        if (_perTxFee == 0) revert ZeroFee();

        // BRICK GUARD (council, same vector as PossessioFactory): feeSink must be
        // a live contract that implements the accounted door, else every
        // openIntent reverts forever. A code-length check is insufficient (a
        // real-but-wrong contract has code but not the door). The pool must be
        // live before this desk deploys. code-length pre-check handles the EOA
        // case (no-code call reverts on return-decode outside try/catch).
        if (_feeSink.code.length == 0) revert FeeSinkInterfaceMismatch();
        try IPossessioPool(_feeSink).isInfraSink() returns (bool ok) {
            if (!ok) revert FeeSinkInterfaceMismatch();
        } catch {
            revert FeeSinkInterfaceMismatch();
        }

        payToken = IERC3009(_payToken);
        payTokenERC20 = IERC20(_payToken);
        feeSink = _feeSink;
        keeper = _keeper;
        PER_TX_FEE = _perTxFee;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN (the paid product)
    //////////////////////////////////////////////////////////////*/

    /// @notice Open a managed target intent for the caller's picked token. One
    ///         signature, one transaction: fee settle -> route fee into the
    ///         Heart -> record the intent with an un-removable -10% stop.
    /// @param tokenRef    the picked token, chain-agnostic: a padded EVM address
    ///                    (`bytes32(uint256(uint160(addr)))`) OR a Solana mint's
    ///                    32-byte pubkey. This Base ledger records it; the keeper
    ///                    routes on (tokenRef, chainTag). SPEC_AutoTarget §3.
    /// @param chainTag    which chain the token lives on — CHAIN_BASE, CHAIN_SOLANA,
    ///                    or any EVM chainId. Opaque to this contract; keeper reads it.
    /// @param entryPrice  the reference entry price (caller-supplied units; the
    ///                    keeper's observedPrice must be in the SAME units). Only
    ///                    the ratio matters - target/stop are bps of this.
    /// @param targetBps   one of {1000, 2500, 5000} (the +10/+25/+50 buttons).
    /// @param feeAuth     EIP-3009 authorization for PER_TX_FEE, to == this.
    /// @return id         the new intent id (>= 1).
    function openIntent(
        bytes32 tokenRef,
        uint32 chainTag,
        uint256 entryPrice,
        uint16 targetBps,
        FeeAuth calldata feeAuth
    ) external nonReentrant returns (uint256 id) {
        // 1. Validate the pick + the button. A wrong target reverts cost-free.
        if (tokenRef == bytes32(0)) revert ZeroTokenRef();
        if (chainTag == 0) revert ZeroChainTag();
        if (entryPrice == 0) revert ZeroEntryPrice();
        if (targetBps != TARGET_SCALP && targetBps != TARGET_MID && targetBps != TARGET_HIGH) {
            revert BadTarget(targetBps);
        }

        // 2. Fee settle. Front-run-closed: only THIS contract can settle its own
        //    authorization because to == address(this) (Invariant 4).
        payToken.receiveWithAuthorization(
            msg.sender,
            address(this),
            PER_TX_FEE,
            feeAuth.validAfter,
            feeAuth.validBefore,
            feeAuth.nonce,
            feeAuth.v,
            feeAuth.r,
            feeAuth.s
        );

        // 3. Route the fee INTO the Heart via its accounted pull door (Option A).
        //    forceApprove exact, then the Heart pulls it and credits poolBalance.
        //    If this contract is not in the Heart's authorizedSources the call
        //    reverts - unwinding the whole open, fee included (Invariant 3).
        payTokenERC20.forceApprove(feeSink, PER_TX_FEE);
        IPossessioPool(feeSink).receiveInfraFunds(PER_TX_FEE);

        // 4. Record the intent. The stop is written from the constant - it is
        //    NOT a caller input (Invariant 1). id starts at 1.
        id = ++intentCount;
        intents[id] = Intent({
            user: msg.sender,
            tokenRef: tokenRef,
            chainTag: chainTag,
            entryPrice: entryPrice,
            targetBps: targetBps,
            stopBps: STOP_BPS,
            status: Status.Open,
            exitKind: ExitKind.None,
            usdcReturned: 0
        });

        emit IntentOpened(id, msg.sender, tokenRef, chainTag, entryPrice, targetBps);
        emit FeeRouted(id, PER_TX_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                        RESOLVE (the mechanical exit)
    //////////////////////////////////////////////////////////////*/

    /// @notice Keeper fires the deterministic exit when price crosses the target
    ///         or the always-on stop. Emits the AUTHORITATIVE ExitAuthorized the
    ///         swap rail acts on. The keeper moves no funds (Invariant 5).
    /// @param id             the intent to resolve.
    /// @param observedPrice  current price, SAME units as entryPrice.
    function resolveIntent(uint256 id, uint256 observedPrice) external onlyKeeper nonReentrant {
        Intent storage it = intents[id];
        if (it.status != Status.Open) revert IntentNotOpen(id);
        if (observedPrice == 0) revert ZeroPrice();

        uint256 tPrice = _targetPrice(it.entryPrice, it.targetBps);
        uint256 sPrice = _stopPrice(it.entryPrice); // always -10%

        ExitKind kind;
        if (observedPrice >= tPrice) {
            kind = ExitKind.Target;
        } else if (observedPrice <= sPrice) {
            kind = ExitKind.Stop;
        } else {
            revert NotTriggered(observedPrice, tPrice, sPrice);
        }

        it.status = Status.Resolved;
        it.exitKind = kind;
        emit ExitAuthorized(id, kind, observedPrice);
    }

    /*//////////////////////////////////////////////////////////////
              EXECUTION CLOSE (the on-chain receipt of the swap)

      The token->USDC swap itself runs KEEPER-SIDE, off this contract, via
      the user's bounded Base-Account spend permission + a DEX (Option A,
      keeper-side — SPEC_AutoTarget.md §3). That keeps the money-path
      non-custodial and free of DEX/MEV surface. After the keeper executes
      the swap it calls markExecuted to close the lifecycle on-chain:
      IntentOpened -> ExitAuthorized -> ExitExecuted(proceeds). This makes
      every managed trade a provable public receipt (the business model's
      proof-of-operation) WITHOUT this contract ever touching the funds.

      The keeper cannot fabricate a profit for itself here: it moves no funds
      in this call; usdcReturnedToUser is a recorded figure, and the swap it
      references was bounded by the user's revocable spend permission and its
      proceeds hardcoded to the user's own wallet by the swap rail.
    //////////////////////////////////////////////////////////////*/

    /// @notice Keeper closes an executed exit on-chain after the off-chain swap.
    /// @param id                  a Resolved intent (its exit already authorized).
    /// @param usdcReturnedToUser  the USDC the swap returned to the user (receipt).
    function markExecuted(uint256 id, uint256 usdcReturnedToUser) external onlyKeeper nonReentrant {
        Intent storage it = intents[id];
        if (it.status != Status.Resolved) revert IntentNotResolved(id);

        it.status = Status.Executed;
        it.usdcReturned = usdcReturnedToUser;
        emit ExitExecuted(id, it.exitKind, usdcReturnedToUser);
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL (the human bail-out)
    //////////////////////////////////////////////////////////////*/

    /// @notice The user can always bail an open intent manually.
    function cancelIntent(uint256 id) external nonReentrant {
        Intent storage it = intents[id];
        if (it.status == Status.None) revert UnknownIntent(id);
        if (it.user != msg.sender) revert NotIntentOwner(msg.sender);
        if (it.status != Status.Open) revert IntentNotOpen(id);

        it.status = Status.Cancelled;
        emit IntentCancelled(id);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    function getIntent(uint256 id) external view returns (Intent memory) {
        if (intents[id].status == Status.None) revert UnknownIntent(id);
        return intents[id];
    }

    /// @notice The price at which the target fires (entry * (1 + targetBps)).
    function targetPrice(uint256 id) external view returns (uint256) {
        Intent storage it = intents[id];
        if (it.status == Status.None) revert UnknownIntent(id);
        return _targetPrice(it.entryPrice, it.targetBps);
    }

    /// @notice The price at which the stop fires (entry * (1 - 10%)). Always on.
    function stopPrice(uint256 id) external view returns (uint256) {
        Intent storage it = intents[id];
        if (it.status == Status.None) revert UnknownIntent(id);
        return _stopPrice(it.entryPrice);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _targetPrice(uint256 entryPrice, uint16 targetBps) internal pure returns (uint256) {
        return entryPrice * (BPS + targetBps) / BPS;
    }

    function _stopPrice(uint256 entryPrice) internal pure returns (uint256) {
        return entryPrice * (BPS - STOP_BPS) / BPS;
    }
}
