// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_TRADING_DESK_CREATE3_V1 — the pinned, ordered runbook for
// the AI trading desk (AutoTarget → FundingVault → Rail). Closes AUDIT_20260724
// finding S-1: the three organs had no scripted, address-pinned deploy path, and
// the vault↔Rail prewire is IMMUTABLE — a mistake bricks the pair forever.
//
// PREWIRE (the whole reason this is scripted): the vault's `trader` AND
// `tradeDestination` are immutable and must equal the Rail; the Rail needs the
// vault at construction. The cycle is broken by CREATE3 prediction — predict the
// Rail address, deploy the vault pointed at it, deploy the Rail into that slot.
// Only the Rail needs CREATE3; AutoTarget and the vault are plain CREATE.
//
// ORDER (V2): AutoTarget (feeSink = TOLL_SINK address, plain push — NOT the
// Heart: the desk ctor rejects an accounted pool as sink) → Vault
// (prewired to predicted Rail) → Rail (CREATE3 at the predicted address).
//
// SALT: mine a msg.sender-locked salt for the desk EOA with MineCreate3Salt, set
// RAIL_SALT + RAIL_PREDICTED. Proven offline by test/TradingDeskCreate3.t.sol.
//
// RUN (fork first — NEVER blind-fire an immutable prewire):
//   DEPLOYER_PK=<desk EOA> USDC=0x833589.. TOLL_SINK=0x.. KEEPER=0x.. DEX_ROUTER=0x.. \
//   VAULT_OWNER=0x.. AT_PER_TX_FEE=.. MAX_PER_TRADE=.. MAX_OUTSTANDING=.. DAILY_DRAW_CAP=.. \
//   RAIL_SALT=0x.. RAIL_PREDICTED=0x.. \
//   forge script script/DeployTradingDeskCreate3.s.sol --rpc-url $BASE_RPC_URL -vvv

pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossessioFundingVault} from "../src/PossessioFundingVault.sol";
import {PossessioAutoTarget} from "../src/PossessioAutoTarget.sol";
import {PossessioRail, IFundingVault, IAutoTarget, ISwapRouter} from "../src/PossessioRail.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

interface IInfraSink { function isInfraSink() external view returns (bool); }

contract DeployTradingDeskCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    error WrongChain(uint256 got);
    error KeyMismatch(address got);
    error SaltNotSenderLocked();
    error PredictionMismatch(address computed, address pinned);
    error TollSinkIsAccountedPool(address feeSink);
    error TollSinkZero();
    error DeployedMismatch(address deployed, address predicted);
    error PrewireBroken(address vaultTrader, address rail);

    function run() external returns (address at, address vault, address rail) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);

        uint256 pk        = vm.envUint("DEPLOYER_PK");
        address usdc      = vm.envAddress("USDC");
        address tollSink  = vm.envAddress("TOLL_SINK");      // V2 fee destination: operator EOA /
                                                             // Payments account — NEVER the Heart
                                                             // (plain push there is dead weight;
                                                             // ctor + this guard both reject it)
        address keeper    = vm.envAddress("KEEPER");
        address dexRouter = vm.envAddress("DEX_ROUTER");
        address vOwner    = vm.envAddress("VAULT_OWNER");
        uint256 perTxFee  = vm.envUint("AT_PER_TX_FEE");
        uint256 maxPer    = vm.envUint("MAX_PER_TRADE");
        uint256 maxOut    = vm.envUint("MAX_OUTSTANDING");
        uint256 daily     = vm.envUint("DAILY_DRAW_CAP");
        bytes32 railSalt  = vm.envBytes32("RAIL_SALT");
        address railPinned = vm.envAddress("RAIL_PREDICTED");

        address deployer = vm.addr(pk);

        // ── Pre-flight guards (fail before ANY irreversible deploy) ──────────
        // salt must be msg.sender-locked to the deployer: [20 deployer][0x00][11].
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(railSalt)) != deployer || railSalt[20] != 0x00) revert SaltNotSenderLocked();

        bytes32 gs = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), railSalt));
        address predicted = CREATEX.computeCreate3Address(gs);
        if (predicted != railPinned) revert PredictionMismatch(predicted, railPinned);

        // V2 sink rules, mirrored from the desk ctor so a bad wire fails before
        // any gas is spent broadcasting: any EOA or plain contract is a valid
        // TOLL_SINK; an accounted pool (isInfraSink()==true) is rejected — a
        // plain push there strands the fee uncredited.
        if (tollSink == address(0)) revert TollSinkZero();
        if (tollSink.code.length > 0) {
            try IInfraSink(tollSink).isInfraSink() returns (bool isPool) {
                if (isPool) revert TollSinkIsAccountedPool(tollSink);
            } catch { /* plain contract — fine */ }
        }

        vm.startBroadcast(pk);

        // 1. AutoTarget V2 (independent; the inverted sink guard runs in its ctor).
        at = address(new PossessioAutoTarget(usdc, tollSink, keeper, perTxFee));

        // 2. Vault, immutably prewired to the PREDICTED Rail address.
        vault = address(new PossessioFundingVault(
            IERC20(usdc), vOwner, predicted, predicted, maxPer, maxOut, daily
        ));

        // 3. Rail via CREATE3 into the predicted slot.
        bytes memory initCode = abi.encodePacked(
            type(PossessioRail).creationCode,
            abi.encode(usdc, vault, at, keeper, dexRouter)
        );
        rail = CREATEX.deployCreate3(railSalt, initCode);

        vm.stopBroadcast();

        // ── Post-deploy verification (the prewire MUST hold) ─────────────────
        if (rail != predicted) revert DeployedMismatch(rail, predicted);
        if (PossessioFundingVault(vault).trader() != rail
            || PossessioFundingVault(vault).tradeDestination() != rail) {
            revert PrewireBroken(PossessioFundingVault(vault).trader(), rail);
        }

        console.log("AutoTarget:", at);
        console.log("FundingVault:", vault);
        console.log("Rail:", rail);
    }
}
