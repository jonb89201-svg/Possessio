# POSSESSIO — Reproduction Instructions
**Version:** V2 — 104/104 certified

Anyone can reproduce the certified test results in under 5 minutes.

---

## Requirements

```
· Any device with a terminal
  (including mobile via Termux)
· Internet connection
· Git
```

---

## Steps

```bash
# 1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup

# 2. Clone the repo
git clone https://github.com/jonb89201-svg/Possessio
cd Possessio

# 3. Install dependencies
forge install OpenZeppelin/openzeppelin-contracts

# 4. Run the full test suite
forge test -vvv
```

---

## Expected Result

```
Suite result: ok. 16 passed; 0 failed; 0 skipped  (Gauntlet.t.sol)
Suite result: ok. 88 passed; 0 failed; 0 skipped  (PLATE.t.sol)

Ran 2 test suites: 104 tests passed, 0 failed, 0 skipped
```

---

## Exact Toolchain

```
Solc:          0.8.33
Foundry:       latest stable (foundryup)
OpenZeppelin:  forge install (latest compatible)
Optimizer:     true — optimizer_runs = 200
```

The `foundry.toml` in the repo root contains the exact optimizer configuration used for the certified deployment.

---

## Verify Deployed Contract

```
Network:   Base Sepolia
Address:   0xa37De136d30F9bFBD79499F392f0349548Af31FF
Explorer:  https://sepolia.basescan.org/address/0xa37De136d30F9bFBD79499F392f0349548Af31FF
```

---

## Notes

```
· The build was done entirely on a smartphone
· Any device with a terminal will reproduce
  the same 104/104 result
· No special hardware required
· No cloud services required
· Total reproduction time: ~3 minutes
```

---

*If your result differs from 104 tests passed, 0 failed — please open an issue on the repo.*
