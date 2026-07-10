// SPDX-License-Identifier: MIT
// BUILD-PROOF: DEPLOY_L1ANCHORFACTORY_V1 - deploys L1AnchorFactory to ETHEREUM
// MAINNET (L1). This is the canonical Anchor factory: its address becomes the
// trust anchor for every L1Anchor's Institutional Identity Primitive.
//
// ─────────────────────────────────────────────────────────────────────────────
// READINESS POSTURE — "everything done except those addresses"
// ─────────────────────────────────────────────────────────────────────────────
// The L1AnchorFactory constructor takes five endpoint addresses. THREE are
// public, canonical Ethereum-mainnet contracts and are hardcoded + verified
// below. TWO are institutional endpoints only BitMine/Bitwise can supply, and
// are read from the environment at deploy time. The script REFUSES to deploy
// until both are provided (non-zero), so a deploy is mechanically impossible
// before the integration addresses exist — and trivial the moment they do.
//
//   KNOWN (hardcoded, source-verified):
//     - cbETH               0xBe9895146f7AF43049ca1c1AE358B0541Ea49704  (Etherscan)
//     - USDC                0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48  (Circle/Etherscan)
//     - Chainlink cbETH/ETH 0xF017fcB346A1885194689bA23Eff2fE6fA5C483b  (data.chain.link)
//
//   BLANK until BitMine/Bitwise supply them (env vars, gated below):
//     - MAVAN_ENTRY_ADDR       — MAVAN validator network entry contract  (BitMine)
//     - BITWISE_MORPHO_VAULT_ADDR — Bitwise-curated Morpho Blue USDC vault (Bitwise)
//
// DEPLOYMENT FEE: this v1 Factory is free (gas only). The fee for the
// fee-bearing version is TO BE DETERMINED BY FUNDSTRAT — the L1 rail's
// economics are a joint decision with the network operator, not set by
// POSSESSIO alone. No fee field exists on this contract to populate here.
//
// CAVEAT (interface, not address): the MAVAN leg in L1Anchor.sol is built
// against the IMAVANEntry PLACEHOLDER interface. This script readies the
// ADDRESS plumbing only. If MAVAN's real ABI differs in shape from the
// placeholder (stake/unstake/sharesOf signatures), L1Anchor.sol itself needs
// the real interface swapped in and re-tested — a Factory v2, per L1Anchor's
// own header. Supplying the address does not paper over an ABI-shape change.
//
// RUN (Ethereum L1 mainnet — only once both integration addresses are in hand):
//   MAVAN_ENTRY_ADDR=0x... \
//   BITWISE_MORPHO_VAULT_ADDR=0x... \
//   forge script script/DeployL1AnchorFactory.s.sol \
//     --rpc-url $MAINNET_RPC_URL \
//     --private-key $DEPLOYER_PK \
//     --broadcast -vvv 2>&1 | tee deploy_l1anchorfactory.txt

pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {L1AnchorFactory} from "../src/L1AnchorFactory.sol";

contract DeployL1AnchorFactory is Script {
    // ---- KNOWN: source-verified Ethereum-mainnet addresses ----
    address constant CBETH            = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704; // Coinbase Wrapped Staked ETH
    address constant USDC             = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Circle USDC
    address constant CBETH_ETH_ORACLE = 0xF017fcB346A1885194689bA23Eff2fE6fA5C483b; // Chainlink cbETH/ETH feed

    // ---- BLANK: institutional endpoints supplied by BitMine / Bitwise ----
    // Read from env at deploy time. The script cannot proceed until both are set.

    function run() external returns (address factoryAddr) {
        uint256 pk = vm.envUint("DEPLOYER_PK");

        // The two integration addresses only BitMine/Bitwise can give us.
        // vm.envAddress reverts if unset; the require makes the gate explicit.
        address mavanEntry  = vm.envAddress("MAVAN_ENTRY_ADDR");
        address morphoVault = vm.envAddress("BITWISE_MORPHO_VAULT_ADDR");

        require(
            mavanEntry != address(0),
            "MAVAN_ENTRY_ADDR not set - waiting on BitMine's MAVAN entry address"
        );
        require(
            morphoVault != address(0),
            "BITWISE_MORPHO_VAULT_ADDR not set - waiting on Bitwise's Morpho vault address"
        );

        vm.startBroadcast(pk);
        // Constructor order: (_morphoVault, _mavanEntry, _cbeth, _usdc, _cbethEthOracle)
        L1AnchorFactory factory = new L1AnchorFactory(
            morphoVault,
            mavanEntry,
            CBETH,
            USDC,
            CBETH_ETH_ORACLE
        );
        vm.stopBroadcast();

        factoryAddr = address(factory);

        console2.log("=== L1AnchorFactory DEPLOYED (Ethereum L1) ===");
        console2.log("  Factory address      :", factoryAddr);
        console2.log("  MAVAN_ENTRY          :", mavanEntry);
        console2.log("  BITWISE_MORPHO_VAULT :", morphoVault);
        console2.log("  cbETH                :", CBETH);
        console2.log("  USDC                 :", USDC);
        console2.log("  cbETH/ETH oracle     :", CBETH_ETH_ORACLE);
        console2.log("");
        console2.log("NEXT: this Factory address is the canonical trust anchor.");
        console2.log("      Publish it; counterparties recognize genuine Anchors");
        console2.log("      by calling factoryDeployer() and matching THIS address.");
        console2.log("      Confirm L1Anchor's IMAVANEntry matches MAVAN's real ABI");
        console2.log("      before any merchant routes cbETH (Factory v2 if not).");
    }
}
