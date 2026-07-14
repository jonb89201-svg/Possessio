// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * ╔═══════════════════════════════════════════════════════════════════════╗
 * ║  ⚠️  DEPRECATED — SUPERSEDED v1. DO NOT DEPLOY.                        ║
 * ╚═══════════════════════════════════════════════════════════════════════╝
 *
 * Part of the superseded v1 PLATE set (see src/PLATE.sol's deprecation
 * header). POSSESSIO v2 eliminated this contract entirely — the v2.6.3 hook
 * (src/POSSESSIO_v2-6-3.sol) carries its SAV council logic inline and its
 * header records: "STAKING REMOVED: PLATEStaking was ceremony over burn —
 * eliminated from v2." The standalone ServiceAccountabilityVault.sol that
 * references IPLATEStaking is part of the same superseded v1 set; the v2.6.3
 * SAV is separate and does not use this contract. Retained in-tree ONLY for
 * lineage and the historical SAV.t.sol / SAVGauntlet.t.sol suites.
 *
 * KNOWN ACCOUNTING DEFECT, ACKNOWLEDGED NOT FIXED (audit 2026-07-14, C-6):
 *   emergencyWithdraw() zeroes totalStaked but leaves every per-member
 *   staked[] entry populated. If the contract is ever re-used after an
 *   emergency withdrawal, a later stake() double-counts in getStaked()
 *   (staked[] resumes accumulating on top of the stale pre-withdrawal
 *   values while totalStaked restarts from zero). Deprecation is the fix:
 *   this contract must not be deployed or re-used, so the defect is
 *   documented rather than patched. Do NOT rely on getStaked() after any
 *   emergencyWithdraw().
 *
 * @title PLATEStaking
 * @notice Internal protocol lock mechanism for the POSSESSIO council allocation.
 *         Called exclusively by the ServiceAccountabilityVault (SAV).
 *         No public staking interface. No yield. No reward distribution.
 *         Non-upgradeable. Deployed once.
 *
 * @dev Deployment sequence:
 *      1. Deploy PLATEStaking(PLATE_TOKEN, TREASURY_SAFE)
 *      2. Deploy SAV
 *      3. Treasury Safe calls setSAV(SAV_ADDRESS) — permanently locked
 */
contract PLATEStaking {

    // ── Immutables ───────────────────────────────────────────────────────────

    IERC20  public immutable PLATE_TOKEN;
    address public immutable TREASURY_SAFE;

    // ── One-Time Settable ────────────────────────────────────────────────────

    address public SAV_CONTRACT;
    bool    public savLocked;

    // ── State ────────────────────────────────────────────────────────────────

    mapping(address => uint256) public staked;
    uint256 public totalStaked;

    // ── Events ───────────────────────────────────────────────────────────────

    event SAVLocked(address indexed sav);
    event Staked(address indexed member, uint256 amount);
    event EmergencyWithdraw(uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error OnlySAV();
    error OnlyTreasury();
    error SAVAlreadyLocked();
    error InvalidAddress();
    error SAVNotSet();
    error NothingToWithdraw();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlySAV() {
        if (msg.sender != SAV_CONTRACT) revert OnlySAV();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != TREASURY_SAFE) revert OnlyTreasury();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _plate, address _treasury) {
        if (_plate    == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        PLATE_TOKEN   = IERC20(_plate);
        TREASURY_SAFE = _treasury;
    }

    // ── One-Time SAV Registration ────────────────────────────────────────────

    /**
     * @notice Called once by Treasury Safe after SAV is deployed.
     *         Permanently locks SAV_CONTRACT — cannot be changed after this call.
     * @param _sav Address of the deployed ServiceAccountabilityVault
     */
    function setSAV(address _sav) external onlyTreasury {
        if (savLocked)          revert SAVAlreadyLocked();
        if (_sav == address(0)) revert InvalidAddress();
        SAV_CONTRACT = _sav;
        savLocked    = true;
        emit SAVLocked(_sav);
    }

    // ── Core Function ────────────────────────────────────────────────────────

    /**
     * @notice Called by SAV only. Transfers PLATE from SAV to this contract
     *         and records the staked amount per council member.
     * @param member Council member address whose claimable is being staked
     * @param amount Amount of PLATE to stake
     */
    function stake(address member, uint256 amount) external onlySAV {
        if (!savLocked)          revert SAVNotSet();
        if (member == address(0)) revert InvalidAddress();
        PLATE_TOKEN.transferFrom(msg.sender, address(this), amount);
        staked[member] += amount;
        totalStaked    += amount;
        emit Staked(member, amount);
    }

    // ── Emergency Recovery ───────────────────────────────────────────────────

    /**
     * @notice Emergency recovery callable by Treasury Safe only.
     *         Returns all PLATE to Treasury Safe and resets all staked mappings.
     *         Should only be used in an emergency — coordinate with council first.
     */
    function emergencyWithdraw() external onlyTreasury {
        uint256 balance = PLATE_TOKEN.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();
        totalStaked = 0;
        // Note: individual staked[] mappings are not reset in loop to avoid
        // gas issues with large member counts. totalStaked = 0 is the
        // authoritative accounting signal.
        // ⚠️ C-6 (audit 2026-07-14): because staked[] stays populated, any
        // stake() AFTER this call double-counts in getStaked(). This contract
        // is DEPRECATED (see file header) — the defect is documented, not
        // patched; the contract must not be re-used post-emergencyWithdraw.
        PLATE_TOKEN.transfer(TREASURY_SAFE, balance);
        emit EmergencyWithdraw(balance);
    }

    // ── View ─────────────────────────────────────────────────────────────────

    function getStaked(address member) external view returns (uint256) {
        return staked[member];
    }

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }
}
