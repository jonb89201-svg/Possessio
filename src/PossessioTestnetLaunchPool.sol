// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PossessioTestnetLaunchPool
/// @notice Base Sepolia ONLY. Aggregates faucet-dripped testnet ETH and tokens into one
///         on-chain pool; operator-gated stipend draws fuel console-initiated testnet
///         launches (gas + factory fee). The pool address IS the faucet destination:
///         open receive() so drips land here directly from any source.
/// @dev Substrate-honest guards, in the SaltPool tradition:
///      - WrongChain(): constructor refuses to exist off 84532. A free-money contract
///        is structurally impossible to deploy on mainnet.
///      - RoleSeparationViolation(): owner != operator at construction; sweep targets
///        may never be the operator (money-destination separation).
///      - PoolEmpty(): honest revert, never a silent partial send.
///      - OWNER_ROLE is self-administered; no DEFAULT_ADMIN_ROLE holder exists.
///        Deploy with owner_ = Base Account and the deployer retires holding nothing.
contract PossessioTestnetLaunchPool is AccessControl {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- roles
    /// @dev Protocol-wide constant. keccak256("OWNER_ROLE") =
    ///      0xb19546dff01e856fb3f010c267a7b1c60363cf8a4664e21cc89c26224620214e
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ---------------------------------------------------------------- config
    uint256 public constant TESTNET_CHAIN_ID = 84532; // Base Sepolia

    /// @notice Wei sent per ETH draw.
    uint256 public ethStipendWei;
    /// @notice Per-recipient cooldown, seconds. ETH and each token track cooldowns
    ///         independently so one launch can draw gas AND fee in the same session.
    uint256 public cooldownSecs;
    /// @notice Per-draw amount for an enabled token (0 = token disabled).
    mapping(address token => uint256) public tokenStipend;

    mapping(address recipient => uint256) public lastEthDrawAt;
    mapping(address token => mapping(address recipient => uint256)) public lastTokenDrawAt;

    // ---------------------------------------------------------------- errors
    error WrongChain(uint256 actual);
    error RoleSeparationViolation();
    error PoolEmpty();
    error CooldownActive(uint256 readyAt);
    error TokenNotEnabled(address token);
    error ZeroAddress();
    error EthSendFailed();

    // ---------------------------------------------------------------- events
    event Refilled(address indexed from, uint256 amount);
    event DrawnEth(address indexed to, uint256 amount);
    event DrawnToken(address indexed token, address indexed to, uint256 amount);
    event EthStipendSet(uint256 weiAmount);
    event TokenStipendSet(address indexed token, uint256 amount);
    event CooldownSet(uint256 secs);
    event Swept(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------- setup
    /// @param owner_    Durable owner (intended: Base Account 0x6cfe...9203).
    /// @param operator_ Throwaway testnet key held by the Worker dripper. NEVER the
    ///                  wave PK, never a mainnet-privileged key.
    constructor(
        address owner_,
        address operator_,
        uint256 ethStipendWei_,
        uint256 cooldownSecs_
    ) {
        if (block.chainid != TESTNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (owner_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        if (owner_ == operator_) revert RoleSeparationViolation();

        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);       // self-administered; no hidden admin
        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);    // owner hires/fires operators
        _grantRole(OWNER_ROLE, owner_);
        _grantRole(OPERATOR_ROLE, operator_);

        ethStipendWei = ethStipendWei_;
        cooldownSecs = cooldownSecs_;
        emit EthStipendSet(ethStipendWei_);
        emit CooldownSet(cooldownSecs_);
    }

    /// @notice Open refill. Point every faucet claim straight at this address.
    receive() external payable {
        emit Refilled(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- draws
    /// @notice Send the ETH gas stipend to a launch wallet. Operator-gated.
    function drawEth(address to) external onlyRole(OPERATOR_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 readyAt = lastEthDrawAt[to] + cooldownSecs;
        if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        lastEthDrawAt[to] = block.timestamp; // effects before interaction

        uint256 amount = ethStipendWei;
        if (address(this).balance < amount) revert PoolEmpty();
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit DrawnEth(to, amount);
    }

    /// @notice Send an enabled token's stipend (e.g. 100 testnet USDC for the factory
    ///         fee) to a launch wallet. Operator-gated. Independent cooldown from ETH.
    function drawToken(address token, address to) external onlyRole(OPERATOR_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = tokenStipend[token];
        if (amount == 0) revert TokenNotEnabled(token);

        uint256 readyAt = lastTokenDrawAt[token][to] + cooldownSecs;
        if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        lastTokenDrawAt[token][to] = block.timestamp; // effects before interaction

        if (IERC20(token).balanceOf(address(this)) < amount) revert PoolEmpty();
        IERC20(token).safeTransfer(to, amount);
        emit DrawnToken(token, to, amount);
    }

    // ---------------------------------------------------------------- owner ops
    function setEthStipend(uint256 weiAmount) external onlyRole(OWNER_ROLE) {
        ethStipendWei = weiAmount;
        emit EthStipendSet(weiAmount);
    }

    function setTokenStipend(address token, uint256 amount) external onlyRole(OWNER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        tokenStipend[token] = amount;
        emit TokenStipendSet(token, amount);
    }

    function setCooldown(uint256 secs) external onlyRole(OWNER_ROLE) {
        cooldownSecs = secs;
        emit CooldownSet(secs);
    }

    /// @notice Testnet cleanup. Sweep target may never be the operator.
    function sweepEth(address payable to) external onlyRole(OWNER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (hasRole(OPERATOR_ROLE, to)) revert RoleSeparationViolation();
        uint256 bal = address(this).balance;
        (bool ok, ) = to.call{value: bal}("");
        if (!ok) revert EthSendFailed();
        emit Swept(address(0), to, bal);
    }

    /// @notice Testnet cleanup for tokens. Same operator-destination guard.
    function sweepToken(address token, address to) external onlyRole(OWNER_ROLE) {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (hasRole(OPERATOR_ROLE, to)) revert RoleSeparationViolation();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
        emit Swept(token, to, bal);
    }
}
