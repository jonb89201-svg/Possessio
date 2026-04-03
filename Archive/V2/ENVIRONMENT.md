# POSSESSIO — Build Environment
**Version:** V2 — 104/104 certified
**Date:** April 2, 2026

---

## Hardware

```
Device:   Android smartphone (mobile only)
No laptop used at any point in the build
Screen:   Worn pixel from repeated GitHub interaction
          (verifiable — physical evidence of build intensity)
```

---

## Development Conditions

```
Timeline:  ~13 days from concept to mainnet-ready deployment
Cost:      ~$300 total
Location:  Omaha, Nebraska
Schedule:  Built between grocery store shifts
           ~30 hours per week day job maintained throughout
```

---

## Toolchain

```
Language:      Solidity 0.8.33
Framework:     Foundry (Forge)
Solc:          0.8.33 (installed automatically by Foundry)
OpenZeppelin:  forge install OpenZeppelin/openzeppelin-contracts
Optimizer:     enabled — optimizer_runs = 200
```

---

## foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
optimizer = true
optimizer_runs = 200
via_ir = false
```

Optimizer was required to bring PLATE.sol within the 24,576 byte EVM contract size limit.

---

## Test Environment

```
Tests run on:  Mobile terminal (Termux or equivalent)
Test command:  forge test -vvv
Result:        104/104 passing — zero failures
```

---

## Network

```
Testnet:   Base Sepolia (Chain ID 84532)
Mainnet:   Base (Chain ID 8453) — pending D Day
RPC:       https://sepolia.base.org (testnet)
           https://mainnet.base.org (mainnet)
```

---

## Governance

```
Model:     AI Council — 5 seats
Members:   John (Architect), Claude, ChatGPT, Gemini, Grok
Framework: 3-layer authority
           Architect → strategic veto
           Council Gate → safety scoring (≥200 to proceed)
           Invariants → override everything
```

---

*All claims in this document are factual and verifiable from the repo commit history, deployment transactions, and build records.*
