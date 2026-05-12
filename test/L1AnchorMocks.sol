// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title L1Anchor Test Mocks
 * @notice Mock infrastructure for L1Anchor.sol and L1AnchorFactory.sol test
 *         suites.  Provides controllable implementations of every external
 *         interface the Anchor depends on:
 *
 *           - IMAVANEntry         (validator network entry contract)
 *           - IMorphoVault        (Bitwise-curated Morpho Blue ERC4626 vault)
 *           - IChainlinkFeed      (cbETH/ETH price oracle)
 *           - MockERC20           (cbETH and USDC token surface)
 *
 *         All mocks match L1Anchor.sol's interface declarations exactly.
 *         Contract-surface accuracy is the primary requirement: a test suite
 *         built against these mocks will compile against the real contract
 *         and exercise the same call paths.
 *
 *         Each mock supports:
 *           - Normal happy-path operation (configurable success returns)
 *           - Forced revert mode (for emergencyUnwind try/catch testing)
 *           - Forced silent failure mode (returns success but moves no value,
 *             for testing the contract's balance-delta verification logic)
 *           - State inspection helpers for invariant testing
 *
 *         These mocks are deliberately simple.  They do not simulate full
 *         partner-protocol behavior.  They simulate enough partner-protocol
 *         behavior to exercise the Anchor's call paths and validate the
 *         Anchor's defensive-design assumptions.  Where the real partner
 *         could exhibit behaviors the mock does not reproduce, those gaps
 *         must be documented in the test suite's Assumption Log per
 *         Amendment IV proof-aware validation.
 *
 *         Limitations documented per Amendment IV:
 *           - MockMAVANEntry: does not simulate slashing, validator queue
 *             delays, or network-level finality concerns.  Models stake/
 *             unstake as instant 1:1 share/asset accounting.
 *           - MockMorphoVault: does not simulate full Morpho Blue market
 *             curator decisions, isolated-market default conditions, or
 *             timelock-mediated parameter changes.  Models deposit/redeem
 *             as instant ERC4626 share accounting.
 *           - MockChainlinkFeed: does not simulate aggregator round
 *             progression at network speed.  Test code controls timestamps
 *             explicitly via setRoundData().
 *           - MockERC20: implements minimal ERC20 surface (transfer,
 *             transferFrom, approve, balanceOf, allowance).  Does not
 *             simulate fee-on-transfer, rebasing, or approve-race conditions.
 *
 *         Tests requiring behaviors outside these mocks must extend the
 *         mocks or substitute richer fixtures and document the substitution.
 */

// ═════════════════════════════════════════════════════════════════════════════
//                              MOCK ERC20 TOKEN
// ═════════════════════════════════════════════════════════════════════════════

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "MockERC20: insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                             MOCK MAVAN ENTRY
//
//   Matches L1Anchor.sol's IMAVANEntry interface exactly:
//     function stake(uint256 amount) external returns (uint256 shares);
//     function unstake(uint256 shares) external returns (uint256 cbEthReturned);
//     function sharesOf(address staker) external view returns (uint256);
//
//   Modeled as 1:1 stake-to-shares accounting for test simplicity.
//   Real MAVAN may use validator-set-share accounting with slashing
//   exposure; that is documented as out-of-scope for these mocks.
// ═════════════════════════════════════════════════════════════════════════════

contract MockMAVANEntry {
    MockERC20 public immutable cbETH;
    mapping(address => uint256) private _sharesOf;

    // Failure-injection toggles for test scenarios
    bool public stakeReverts;
    bool public unstakeReverts;
    bool public stakeSilentlyFails;     // returns success but moves no value
    bool public unstakeSilentlyFails;   // returns success but moves no value

    event Staked(address indexed staker, uint256 amount, uint256 shares);
    event Unstaked(address indexed staker, uint256 shares, uint256 cbEthReturned);

    constructor(MockERC20 _cbETH) {
        cbETH = _cbETH;
    }

    // ─── Failure injection (test-only) ──────────────────────────────────────

    function setStakeReverts(bool _reverts) external { stakeReverts = _reverts; }
    function setUnstakeReverts(bool _reverts) external { unstakeReverts = _reverts; }
    function setStakeSilentlyFails(bool _fails) external { stakeSilentlyFails = _fails; }
    function setUnstakeSilentlyFails(bool _fails) external { unstakeSilentlyFails = _fails; }

    // ─── Mocked external surface ────────────────────────────────────────────

    function stake(uint256 amount) external returns (uint256 shares) {
        if (stakeReverts) revert("MockMAVAN: stake reverted");

        if (stakeSilentlyFails) {
            // Return claimed shares without taking the tokens.  Tests the
            // Anchor's defensive design: trust balance delta, not return value.
            return amount;
        }

        require(
            cbETH.transferFrom(msg.sender, address(this), amount),
            "MockMAVAN: cbETH transfer failed"
        );
        _sharesOf[msg.sender] += amount;
        shares = amount;
        emit Staked(msg.sender, amount, shares);
    }

    function unstake(uint256 shares) external returns (uint256 cbEthReturned) {
        if (unstakeReverts) revert("MockMAVAN: unstake reverted");

        if (unstakeSilentlyFails) {
            // Return claimed amount without sending tokens.  Tests the
            // Anchor's defensive design: trust balance delta, not return value.
            return shares;
        }

        require(_sharesOf[msg.sender] >= shares, "MockMAVAN: insufficient shares");
        _sharesOf[msg.sender] -= shares;
        cbEthReturned = shares;
        require(
            cbETH.transfer(msg.sender, cbEthReturned),
            "MockMAVAN: cbETH return failed"
        );
        emit Unstaked(msg.sender, shares, cbEthReturned);
    }

    function sharesOf(address staker) external view returns (uint256) {
        return _sharesOf[staker];
    }

    // ─── Test inspection ────────────────────────────────────────────────────

    function totalCbEthHeld() external view returns (uint256) {
        return cbETH.balanceOf(address(this));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                            MOCK MORPHO VAULT
//
//   Matches L1Anchor.sol's IMorphoVault interface exactly (ERC4626 subset):
//     function deposit(uint256 assets, address receiver) external returns (uint256 shares);
//     function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
//     function balanceOf(address) external view returns (uint256);
//     function convertToAssets(uint256 shares) external view returns (uint256);
//
//   Modeled as 1:1 ERC4626 with no yield accrual for test simplicity.
//   Tests requiring yield accrual must override convertToAssets() via
//   setSharePriceMultiplier().
// ═════════════════════════════════════════════════════════════════════════════

contract MockMorphoVault {
    MockERC20 public immutable usdc;
    mapping(address => uint256) private _sharesOf;
    uint256 public totalShares;

    // Default 1:1 share-to-asset ratio; settable for yield-accrual tests
    uint256 public sharePriceNumerator = 1e18;
    uint256 public sharePriceDenominator = 1e18;

    // Failure-injection toggles
    bool public depositReverts;
    bool public redeemReverts;
    bool public depositSilentlyFails;
    bool public redeemSilentlyFails;

    event Deposit(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Redeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    // ─── Failure injection (test-only) ──────────────────────────────────────

    function setDepositReverts(bool _reverts) external { depositReverts = _reverts; }
    function setRedeemReverts(bool _reverts) external { redeemReverts = _reverts; }
    function setDepositSilentlyFails(bool _fails) external { depositSilentlyFails = _fails; }
    function setRedeemSilentlyFails(bool _fails) external { redeemSilentlyFails = _fails; }

    /// @notice Set the share-to-asset price for yield-accrual testing.
    ///         convertToAssets(shares) returns shares * num / denom.
    function setSharePrice(uint256 num, uint256 denom) external {
        require(denom != 0, "MockMorpho: zero denom");
        sharePriceNumerator = num;
        sharePriceDenominator = denom;
    }

    // ─── Mocked external surface ────────────────────────────────────────────

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (depositReverts) revert("MockMorpho: deposit reverted");

        if (depositSilentlyFails) {
            // Returns claimed shares without taking the assets.  Tests
            // Anchor defensive design.
            return assets;
        }

        require(
            usdc.transferFrom(msg.sender, address(this), assets),
            "MockMorpho: USDC transfer failed"
        );
        // 1:1 shares at base; setSharePrice() adjusts for accrual tests
        shares = assets;
        _sharesOf[receiver] += shares;
        totalShares += shares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        if (redeemReverts) revert("MockMorpho: redeem reverted");

        if (redeemSilentlyFails) {
            return convertToAssets(shares);
        }

        require(_sharesOf[owner] >= shares, "MockMorpho: insufficient shares");
        if (msg.sender != owner) {
            // Mock does not enforce ERC4626 allowance for redeem-on-behalf;
            // L1Anchor only redeems its own shares, so this path is
            // unexercised by the contract under test.
        }
        _sharesOf[owner] -= shares;
        totalShares -= shares;
        assets = convertToAssets(shares);
        require(usdc.transfer(receiver, assets), "MockMorpho: USDC return failed");
        emit Redeem(msg.sender, receiver, owner, assets, shares);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _sharesOf[account];
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * sharePriceNumerator) / sharePriceDenominator;
    }

    // ─── Test inspection ────────────────────────────────────────────────────

    function totalUsdcHeld() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//                          MOCK CHAINLINK FEED
//
//   Matches L1Anchor.sol's IChainlinkFeed interface exactly:
//     function latestRoundData() external view returns (
//         uint80 roundId,
//         int256 answer,
//         uint256 startedAt,
//         uint256 updatedAt,
//         uint80 answeredInRound
//     );
//     function decimals() external view returns (uint8);
//
//   The Anchor's constructor asserts decimals() == 18, so the mock is
//   constructed with that constraint by default.  Tests that need a
//   different decimals value must instantiate with a different value
//   and verify the constructor reverts as expected.
// ═════════════════════════════════════════════════════════════════════════════

contract MockChainlinkFeed {
    uint8 public immutable decimals;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    bool public latestRoundDataReverts;

    constructor(uint8 _decimals) {
        decimals = _decimals;
        // Default to a healthy 1:1 cbETH/ETH ratio with current timestamp
        _roundId = 1;
        _answer = int256(10 ** uint256(_decimals));  // 1.0 at native decimals
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    // ─── Test setters ───────────────────────────────────────────────────────

    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId += 1;
        _answeredInRound = _roundId;
    }

    function setStale(uint256 secondsAgo) external {
        _updatedAt = block.timestamp - secondsAgo;
    }

    function setReverts(bool _reverts) external {
        latestRoundDataReverts = _reverts;
    }

    // ─── Mocked external surface ────────────────────────────────────────────

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        if (latestRoundDataReverts) revert("MockChainlink: latestRoundData reverted");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
