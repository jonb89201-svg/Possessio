// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20}    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}     from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast}  from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager}    from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}         from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary}   from "v4-core/types/PoolId.sol";
import {Currency}        from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary}    from "v4-core/libraries/StateLibrary.sol";
import {FullMath}        from "v4-core/libraries/FullMath.sol";
import {TickMath}        from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/*//////////////////////////////////////////////////////////////
                POSSESSIO LAUNCH TEMPLATE
       v0.1 - built to SPEC_LaunchTemplate.md (option A, POL gate ON)
  The V3 launchpad's frozen artifact: a launch owner's own ERC20 coin
  that is ALSO its own Uniswap v4 hook (spec §5.1, ratified by the
  merged PossessioLaunchFactory: hooks = launch, currency = launch).
  Every launch pairs against COUNCIL_TOKEN and captures a 2% fee to
  the launch OWNER (spec §1). Non-STEEL: no cbETH legs, no Automation,
  no X-LINK, no embedded SAV - the small-business V3. Coin, pair, fee,
  owner.

  F-H5 (cold-seat re-audit 2026-09-01): the prior audit could not find
  this template's source and flagged that, without it, an unverified
  beforeInitialize could let a third party open extra pools hooked to
  a launch (launch/WETH etc.), bypassing the §4 pairing invariant.
  This is that source. beforeInitialize is the closure: it accepts
  exactly ONE call, ever, from exactly the pinned FACTORY, for exactly
  the (COUNCIL_TOKEN, this) pair - COUNCIL_TOKEN and the PoolManager
  are read live from the factory's own immutables (SPEC_LaunchTemplate
  §4.2's "pin the factory as a constant" carried to its minimum: only
  ONE address needs pinning, everything else the factory already
  knows is derived from it, so factory and template can never drift).

  ONE PINNED CONSTANT (FACTORY) - the constellation dance, minimized:
  predict the factory's CREATE3 address -> freeze this file with that
  constant -> hash it -> deploy the factory with that codehash. The
  placeholder below MUST be replaced with the real prediction before
  this file is hashed and pinned into a live PossessioLaunchFactory;
  deploying with the placeholder still in place is a build error, not
  a security property - see BUILD-PROOF below.

  WIRING CONSTRAINTS this design satisfies (spec §4):
  1. One salt, one artifact - ERC20 + hook in a single contract
     (option A). The factory's pair key (hooks = launch, currency =
     launch) is only correct for a single-contract template.
  2. Atomic, unspoofable pairing - beforeInitialize IS the atomic
     pairing check; the launch learns its own PoolKey at birth, in
     the SAME transaction the factory deploys it and calls
     PoolManager.initialize. No post-deploy registration step, no
     window where an un-paired launch exists.
  3. Salt flags match this template's callbacks exactly: beforeInit-
     ialize (bit 13) | beforeAddLiquidity (bit 11) | beforeSwap
     (bit 7) | afterSwap (bit 6) | beforeSwapReturnDelta (bit 3) =
     0x28C8 | 0x2000's sibling class already referenced in
     PossessioLaunchFactory.sol's salt-mining comments.

  POL GATE ON (spec §5.2, sovereign pools): only this contract may add
  liquidity (mirrors STEEL's beforeAddLiquidity gate exactly). Nobody
  else can dilute the owner's position; liquidity walks only if the
  owner walks (owner-gated addLiquidity/removeLiquidity below).

  GENESIS (spec §5.3): the factory opens the pool DRY at the owner's
  chosen sqrtPriceX96 (deployLaunch takes no atomic seed amount - the
  ratified, merged, already-deployed-shape of that function). The
  owner seeds afterward via addLiquidity, at their own pace, with
  their own capital - "their coin, their market" stays literally true
  even at the moment of birth: nothing is escrowed by the factory.

  FEE (spec §1/§2): 2% (FEE_BPS = 200) captured via the Balanced Delta
  pattern (v2.5 STEEL mechanism, unchanged: positive BeforeSwapDelta +
  take(), net-zero in PoolManager's accounting, physically moves the
  fee into this contract's own balance). Always denominated in
  COUNCIL_TOKEN (spec §2's "fee-in-the-denominator" property: every
  trading launch makes its owner an accumulator of the council token).
  When COUNCIL_TOKEN is not the specified currency, the specified
  amount is converted to a council-token-equivalent using the pool's
  live sqrtPriceX96 (Uniswap's own convention: price = currency1 per
  currency0; converting a currency1 amount to currency0-equivalent
  divides by price, the reverse multiplies - see the derivation and
  the empirical proof against a REAL local PoolManager+swap in
  PossessioLaunchTemplate.t.sol's price-direction test).

  OWNER SURFACE (spec §3, "smallest owner surface that honors
  sovereignty"): claimFees, addLiquidity, removeLiquidity,
  transferOwnership. Nothing else - no routing config, no oracle set,
  no upgrade path, no pause. Single-step ownership (even smaller than
  STEEL's Ownable2Step): a sovereign owner can hand the coin to a new
  address, that address controls it from the next block.

  STILL PROPOSED - NON-PROVEN until forge says so. See
  PossessioLaunchTemplate.t.sol. COLD-SEAT re-audit before ratification
  - the seat that wrote this does not certify it.
*/
interface IPossessioLaunchFactory {
    function COUNCIL_TOKEN() external view returns (address);
    function poolManager() external view returns (address);
}

contract PossessioLaunchTemplate is ERC20, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using BalanceDeltaLibrary for BalanceDelta;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/
    error NotFactory(address sender);
    error WrongPair(address currency0, address currency1);
    error AlreadyInitialized();
    error PoolNotInitialized();
    error OnlyPoolManager();
    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ExternalLiquidityDenied();
    error NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/
    event LaunchPaired(PoolKey key, uint256 timestamp);
    event FeeCaptured(address indexed sender, uint256 feeCouncilTokenEquivalent, uint256 accumulated);
    event FeesClaimed(address indexed to, uint256 amount);
    event LiquidityAdded(uint256 amountCouncil, uint256 amountLaunch, uint256 timestamp);
    event LiquidityRemoved(uint256 amountCouncil, uint256 amountLaunch, address indexed to);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                        THE ONE PINNED CONSTANT
    //////////////////////////////////////////////////////////////*/

    /// @dev PLACEHOLDER. Must equal PossessioLaunchFactory's predicted CREATE3
    ///      address (computed BEFORE this file is hashed and pinned as
    ///      templateCodehash - SPEC_LaunchTemplate.md §4.2). Everything else
    ///      this template needs (COUNCIL_TOKEN, the PoolManager) is read live
    ///      from that factory's own public immutables in beforeInitialize, so
    ///      only this one address ever needs substituting.
    address public constant FACTORY = 0x00000000000000000000000000000000facaDE01;

    uint24 internal constant FEE_BPS = 200;      // 2% - spec §1
    uint24 internal constant FEE_DENOM = 10_000;

    /*//////////////////////////////////////////////////////////////
                            OWNER SURFACE
    //////////////////////////////////////////////////////////////*/
    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            PAIRING STATE
      Set exactly once, by beforeInitialize, atomically with the
      factory's own deploy+pair transaction. Nothing else can set
      these; there is no setter.
    //////////////////////////////////////////////////////////////*/
    bool public poolInitialized;
    PoolKey public poolKey;
    address public council;
    bool public councilIsCurrency0;
    IPoolManager public poolManagerContract;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManagerContract)) revert OnlyPoolManager();
        _;
    }

    uint256 public accumulatedCouncilFees;

    /*//////////////////////////////////////////////////////////////
                        UNLOCK CALLBACK TYPES
    //////////////////////////////////////////////////////////////*/
    enum Action { ADD_LIQUIDITY, REMOVE_LIQUIDITY }

    struct CallbackData {
        Action  action;
        uint256 amount0;
        uint256 amount1;      // ignored for REMOVE (liquidity, not amounts, is specified)
        uint128 liquidity;    // used only for REMOVE
        address recipient;    // used only for REMOVE (proceeds destination)
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
      Factory-written convention (deployLaunch step 6): creation code
      = pinned template ++ abi.encode(owner, initArgs). initArgs here
      decodes to (string name, string symbol, uint256 initialSupply) -
      the owner's OWN choice, not a protocol-fixed number: "their coin"
      means they set its parameters, same as any ERC20 they'd deploy
      themselves. 100% of supply mints to them; nothing is retained by
      the factory or this contract beyond the one-time deploy fee
      already settled in USDC before this constructor ever runs.
    //////////////////////////////////////////////////////////////*/
    constructor(address owner_, bytes memory initArgs)
        ERC20(_decodeName(initArgs), _decodeSymbol(initArgs))
    {
        if (owner_ == address(0)) revert ZeroAddress();
        (, , uint256 initialSupply) = abi.decode(initArgs, (string, string, uint256));
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        if (initialSupply > 0) _mint(owner_, initialSupply);
    }

    function _decodeName(bytes memory initArgs) private pure returns (string memory n) {
        (n, , ) = abi.decode(initArgs, (string, string, uint256));
    }

    function _decodeSymbol(bytes memory initArgs) private pure returns (string memory s) {
        (, s, ) = abi.decode(initArgs, (string, string, uint256));
    }

    /*//////////////////////////////////////////////////////////////
                    HOOK PERMISSIONS (v4 address bits)
      Matches the mined salt class exactly: beforeInitialize (pairing
      closure) + beforeAddLiquidity (POL gate) + beforeSwap/afterSwap/
      beforeSwapReturnDelta (2% capture, Balanced Delta pattern).
    //////////////////////////////////////////////////////////////*/
    function getHookPermissions() external pure returns (
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool,
        bool, bool
    ) {
        return (
            true,  false,   // beforeInitialize (pairing closure), afterInitialize
            true,  false,   // beforeAddLiquidity (POL gate), afterAddLiquidity
            false, false,   // beforeRemoveLiquidity, afterRemoveLiquidity
            true,  true,    // beforeSwap + afterSwap
            false, false,   // beforeDonate, afterDonate
            true,  false,   // beforeSwapReturnDelta (fee capture), afterSwapReturnDelta
            false, false    // afterAddLiquidityReturnDelta, afterRemoveLiquidityReturnDelta
        );
    }

    /*//////////////////////////////////////////////////////////////
                  HOOK: beforeInitialize - THE PAIRING CLOSURE
      F-H5 close. Accepts exactly one call, from exactly FACTORY, for
      exactly the (COUNCIL_TOKEN, this) pair. Any other sender or any
      other key reverts - there is no path to a second pool hooked to
      this launch, ever, at any fee tier or tick spacing, because
      nobody but FACTORY can ever get past the sender check, and
      FACTORY's own deployLaunch calls PoolManager.initialize exactly
      once per launch, atomically, in the same transaction that
      deploys it.
    //////////////////////////////////////////////////////////////*/
    function beforeInitialize(address sender, PoolKey calldata key, uint160 /* sqrtPriceX96 */)
        external returns (bytes4)
    {
        if (poolInitialized) revert AlreadyInitialized();
        if (sender != FACTORY) revert NotFactory(sender);

        address councilToken = IPossessioLaunchFactory(FACTORY).COUNCIL_TOKEN();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool pairOk = (c0 == address(this) && c1 == councilToken)
                   || (c0 == councilToken && c1 == address(this));
        if (!pairOk) revert WrongPair(c0, c1);

        poolKey = key;
        council = councilToken;
        councilIsCurrency0 = (c0 == councilToken);
        poolManagerContract = IPoolManager(IPossessioLaunchFactory(FACTORY).poolManager());
        poolInitialized = true;

        emit LaunchPaired(key, block.timestamp);
        return this.beforeInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                     HOOK: beforeAddLiquidity (POL gate)
      Only this contract's own addLiquidity may add - mirrors STEEL's
      gate exactly. External LPers are rejected; the owner's position
      cannot be diluted.
    //////////////////////////////////////////////////////////////*/
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata /* key */,
        IPoolManager.ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert ExternalLiquidityDenied();
        return this.beforeAddLiquidity.selector;
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK: beforeSwap
      2% capture, always denominated in COUNCIL_TOKEN (spec §2). When
      the launch token is the specified currency, convert to a
      council-equivalent via the pool's live price first.
    //////////////////////////////////////////////////////////////*/
    function beforeSwap(
        address /* sender */,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (!poolInitialized) revert PoolNotInitialized();

        uint256 absSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Specified currency is currency0 when: zeroForOne && exactIn (spending
        // currency0), or !zeroForOne && exactOut (receiving currency0).
        bool specifiedIsCurrency0 = (params.zeroForOne  && params.amountSpecified < 0) ||
                                    (!params.zeroForOne && params.amountSpecified > 0);
        bool specifiedIsCouncil = (specifiedIsCurrency0 == councilIsCurrency0);

        uint256 feeCouncil;
        if (specifiedIsCouncil) {
            feeCouncil = (absSpecified * FEE_BPS) / FEE_DENOM;
        } else {
            // Specified is the launch token - convert to a council-equivalent.
            //
            // Uniswap convention: sqrtPriceX96 = sqrt(price)*2^96, price =
            // currency1 amount per unit of currency0 (price = reserve1/reserve0).
            // priceX96 below = price * 2^96 (Q96).
            //
            //   councilIsCurrency0 == true  -> specified is currency1 (launch).
            //     Converting a currency1 amount to a currency0-equivalent
            //     DIVIDES by price: councilEquiv = launchAmt * 2^96 / priceX96.
            //   councilIsCurrency0 == false -> specified is currency0 (launch).
            //     Converting a currency0 amount to a currency1-equivalent
            //     MULTIPLIES by price: councilEquiv = launchAmt * priceX96 / 2^96.
            //
            // (Squaring staged through FullMath's 512-bit mulDiv per the M-1
            // fix precedent in POSSESSIO_v2-6-3.sol - sqrtPriceX96 can reach
            // ~2^160, so a bare uint256 square overflows Solidity's checked math.)
            (uint160 sqrtPriceX96, , , ) =
                StateLibrary.getSlot0(poolManagerContract, PoolIdLibrary.toId(key));
            uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);

            uint256 councilEquivalent = councilIsCurrency0
                ? FullMath.mulDiv(absSpecified, 1 << 96, priceX96)
                : FullMath.mulDiv(absSpecified, priceX96, 1 << 96);

            feeCouncil = (councilEquivalent * FEE_BPS) / FEE_DENOM;
        }

        if (feeCouncil == 0) {
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), uint24(0));
        }

        Currency councilCurrency = councilIsCurrency0 ? key.currency0 : key.currency1;
        poolManagerContract.take(councilCurrency, address(this), feeCouncil);
        accumulatedCouncilFees += feeCouncil;

        // Balanced Delta: the compensating +feeCouncil delta lands on whichever
        // slot (specified/unspecified) COUNCIL_TOKEN actually occupies for this
        // swap - net delta zero, unlock invariant holds, fee resides in this hook.
        BeforeSwapDelta delta = specifiedIsCouncil
            ? toBeforeSwapDelta(feeCouncil.toInt256().toInt128(), int128(0))
            : toBeforeSwapDelta(int128(0), feeCouncil.toInt256().toInt128());

        emit FeeCaptured(msg.sender, feeCouncil, accumulatedCouncilFees);
        return (this.beforeSwap.selector, delta, uint24(0));
    }

    /// @notice No-op afterSwap. Fee capture happens entirely in beforeSwap via
    ///         the Balanced Delta pattern; this is a permission placeholder.
    function afterSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) external view onlyPoolManager returns (bytes4, int128) {
        return (this.afterSwap.selector, int128(0));
    }

    /*//////////////////////////////////////////////////////////////
                    OWNER: claim the captured fee
    //////////////////////////////////////////////////////////////*/
    function claimFees() external onlyOwner nonReentrant {
        uint256 amount = accumulatedCouncilFees;
        if (amount == 0) revert NothingToClaim();
        accumulatedCouncilFees = 0;
        IERC20(council).safeTransfer(owner, amount);
        emit FeesClaimed(owner, amount);
    }

    /*//////////////////////////////////////////////////////////////
                OWNER: manage liquidity (spec §5.2 POL gate)
      "Liquidity walks only if the owner walks" - the owner can seed
      and later withdraw their own position; nobody else can touch it.
    //////////////////////////////////////////////////////////////*/

    /// @notice Add full-range liquidity, pulling both sides from the caller
    ///         (owner must pre-approve). Callable any number of times.
    function addLiquidity(uint256 amountCouncil, uint256 amountLaunch) external onlyOwner nonReentrant {
        if (!poolInitialized) revert PoolNotInitialized();
        if (amountCouncil == 0 && amountLaunch == 0) revert ZeroAmount();

        if (amountCouncil > 0) IERC20(council).safeTransferFrom(msg.sender, address(this), amountCouncil);
        if (amountLaunch > 0) IERC20(address(this)).safeTransferFrom(msg.sender, address(this), amountLaunch);

        (uint256 amount0Max, uint256 amount1Max) = councilIsCurrency0
            ? (amountCouncil, amountLaunch)
            : (amountLaunch, amountCouncil);

        bytes memory result = poolManagerContract.unlock(abi.encode(CallbackData({
            action: Action.ADD_LIQUIDITY,
            amount0: amount0Max,
            amount1: amount1Max,
            liquidity: 0,
            recipient: address(0)
        })));
        (uint256 settled0, uint256 settled1) = abi.decode(result, (uint256, uint256));

        // getLiquidityForAmounts bounds liquidity by whichever side is more
        // constraining at the pool's live price - at any ratio other than
        // exactly the pool's own, one side is over-supplied. Refund the
        // un-consumed remainder rather than leave it as unaccounted residue
        // sitting in this contract's balance.
        (uint256 settledCouncil, uint256 settledLaunch) = councilIsCurrency0
            ? (settled0, settled1)
            : (settled1, settled0);
        if (amountCouncil > settledCouncil) IERC20(council).safeTransfer(msg.sender, amountCouncil - settledCouncil);
        if (amountLaunch > settledLaunch) IERC20(address(this)).safeTransfer(msg.sender, amountLaunch - settledLaunch);

        emit LiquidityAdded(settledCouncil, settledLaunch, block.timestamp);
    }

    /// @notice Withdraw `liquidityToRemove` units of the owner's full-range
    ///         position; proceeds settle straight to `to`.
    function removeLiquidity(uint128 liquidityToRemove, address to) external onlyOwner nonReentrant {
        if (!poolInitialized) revert PoolNotInitialized();
        if (liquidityToRemove == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        poolManagerContract.unlock(abi.encode(CallbackData({
            action: Action.REMOVE_LIQUIDITY,
            amount0: 0,
            amount1: 0,
            liquidity: liquidityToRemove,
            recipient: to
        })));
    }

    function _fullRangeTicks() internal view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = poolKey.tickSpacing;
        tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManagerContract)) revert OnlyPoolManager();

        CallbackData memory cb = abi.decode(data, (CallbackData));
        (int24 tickLower, int24 tickUpper) = _fullRangeTicks();

        if (cb.action == Action.ADD_LIQUIDITY) {
            (uint160 sqrtPriceCurrent, , , ) =
                StateLibrary.getSlot0(poolManagerContract, PoolIdLibrary.toId(poolKey));

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceCurrent,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                cb.amount0,
                cb.amount1
            );

            (BalanceDelta delta, ) = poolManagerContract.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );

            // Settle EXACTLY what modifyLiquidity measured as owed (delta is
            // <= 0 on a side we're adding to) - never the caller's nominal
            // request, which getLiquidityForAmounts may not fully consume on
            // the less-constraining side at a non-1:1 price.
            uint256 owed0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
            uint256 owed1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
            _settle(poolKey.currency0, owed0);
            _settle(poolKey.currency1, owed1);

            return abi.encode(owed0, owed1);

        } else {
            // REMOVE_LIQUIDITY: negative liquidityDelta frees currency owed to
            // us. modifyLiquidity's own return value is the measured amount
            // owed on each side (a positive component = owed TO us) - never a
            // caller-supplied figure. Take both sides straight to the
            // recipient; no funds ever pass through this contract's balance.
            int256 liquidityDelta = -int256(uint256(cb.liquidity));
            (BalanceDelta delta, ) = poolManagerContract.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta,
                    salt: bytes32(0)
                }),
                ""
            );

            uint256 owed0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            uint256 owed1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            if (owed0 > 0) poolManagerContract.take(poolKey.currency0, cb.recipient, owed0);
            if (owed1 > 0) poolManagerContract.take(poolKey.currency1, cb.recipient, owed1);

            (uint256 outCouncil, uint256 outLaunch) = councilIsCurrency0
                ? (owed0, owed1)
                : (owed1, owed0);
            emit LiquidityRemoved(outCouncil, outLaunch, cb.recipient);
        }

        return "";
    }

    /// @dev Pays owed currency INTO the pool (adding liquidity): sync -> ERC20
    ///      transfer -> settle, per the v4 protocol. Neither currency is ever
    ///      native ETH (spec §2: the council economy never touches ETH).
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManagerContract.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManagerContract), amount);
        poolManagerContract.settle();
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP
      Single-step, deliberately smaller than STEEL's Ownable2Step -
      the smallest owner surface that still lets a sovereign owner
      hand their coin to a new address (spec §3).
    //////////////////////////////////////////////////////////////*/
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
