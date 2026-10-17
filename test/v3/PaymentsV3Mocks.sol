// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
        Mocks for the PossessioPayments v3.0 suites (the auction sweep).
        Copied from the Gauntlet's mocks where a mock exists there, so the
        carried-over behaviours are tested against the same stand-ins.
//////////////////////////////////////////////////////////////*/

contract MockUSDC_V3 {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8  public constant decimals = 6;
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;
    mapping(address => bool) public blocked;   // Circle-style blocklist

    function mint(address to, uint256 amt) external { _balances[to] += amt; }
    function burn(address from, uint256 amt) external { _balances[from] -= amt; }
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function approve(address s, uint256 a) external returns (bool) { _allowances[msg.sender][s] = a; return true; }
    function allowance(address o, address s) external view returns (uint256) { return _allowances[o][s]; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[msg.sender] && !blocked[to], "blocked");
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a; _balances[to] += a; return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(!blocked[from] && !blocked[to], "blocked");
        require(_balances[from] >= a, "insuf");
        require(_allowances[from][msg.sender] >= a, "not approved");
        _allowances[from][msg.sender] -= a; _balances[from] -= a; _balances[to] += a; return true;
    }
}

/// cbETH stand-in. `shortBy` makes transferFrom deliver less than asked (a
/// fee-on-transfer or a lying token): the balance-delta checks must catch it.
contract MockCbETH_V3 {
    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;
    uint256 public shortBy;
    function mint(address to, uint256 amt) external { _balances[to] += amt; }
    function setShortBy(uint256 s) external { shortBy = s; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function approve(address s, uint256 a) external returns (bool) { _allowances[msg.sender][s] = a; return true; }
    function allowance(address o, address s) external view returns (uint256) { return _allowances[o][s]; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(_balances[msg.sender] >= a, "insuf");
        _balances[msg.sender] -= a; _balances[to] += a; return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(_balances[from] >= a, "insuf");
        require(_allowances[from][msg.sender] >= a, "not approved");
        _allowances[from][msg.sender] -= a;
        _balances[from] -= a;
        _balances[to] += a - (shortBy > a ? a : shortBy);
        return true;
    }
}

contract MockFeed_V3 {
    int256 public _answer;
    uint256 public _updatedAt;
    uint80  public _roundId;
    uint80  public _answeredInRound;
    bool    public _reverts;
    uint8   public _decimals;
    constructor(int256 a, uint8 decimals_) {
        _answer = a; _updatedAt = block.timestamp; _roundId = 1; _answeredInRound = 1; _decimals = decimals_;
    }
    function setAnswer(int256 a) external { _answer = a; _updatedAt = block.timestamp; _roundId++; _answeredInRound = _roundId; }
    function setUpdatedAt(uint256 t) external { _updatedAt = t; }
    /// Class-appropriate staleness: past the 25 h window for the 18-dec feed,
    /// past the 1 h window for an 8-dec feed.
    function setStale() external { _updatedAt = _decimals == 18 ? block.timestamp - 100_000 : block.timestamp - 7_200; }
    function setReverts(bool r) external { _reverts = r; }
    function setIncomplete() external { _answeredInRound = _roundId - 1; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!_reverts, "MockFeed: reverts");
        return (_roundId, _answer, 0, _updatedAt, _answeredInRound);
    }
    function decimals() external view returns (uint8) { return _decimals; }
}

contract MockLST_V3 {
    uint256 public cbEthRate = 1.05e18;
    bool public reverts;
    function setCbEthRate(uint256 v) external { cbEthRate = v; }
    function setReverts(bool r) external { reverts = r; }
    function cbEthToEth(uint256 c) external view returns (uint256) { require(!reverts, "lst"); return (c * cbEthRate) / 1e18; }
}

/// ERC4626-shaped USDC vault. `leakageMode` consumes one unit less than
/// declared; `depositReverts` refuses; `yieldBps` lets convertToAssets grow.
contract MockVault_V3 {
    MockUSDC_V3 public usdc;
    mapping(address => uint256) public _shares;
    uint256 public totalShares;
    uint256 public totalAssets_;
    bool    public depositReverts;
    bool    public leakageMode;
    bool    public convertReverts;
    bool    public mintNothing;      // consumes the USDC but mints no shares
    constructor(address usdc_) { usdc = MockUSDC_V3(usdc_); }
    function setDepositReverts(bool b) external { depositReverts = b; }
    function setMintNothing(bool b) external { mintNothing = b; }
    function setLeakageMode(bool b) external { leakageMode = b; }
    function setConvertReverts(bool b) external { convertReverts = b; }
    function addYield(uint256 usdcAmt) external { usdc.mint(address(this), usdcAmt); totalAssets_ += usdcAmt; }
    function asset() external view returns (address) { return address(usdc); }
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!depositReverts, "MockVault: deposit reverts");
        uint256 consumeAmt = leakageMode ? (assets - 1) : assets;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transferFrom(msg.sender, address(this), consumeAmt);
        if (mintNothing) { totalAssets_ += consumeAmt; return 0; }
        shares = totalShares == 0 ? consumeAmt : (consumeAmt * totalShares) / totalAssets_;
        _shares[receiver] += shares; totalShares += shares; totalAssets_ += consumeAmt;
    }
    function balanceOf(address a) external view returns (uint256) { return _shares[a]; }
    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!convertReverts, "MockVault: convert reverts");
        if (totalShares == 0) return shares;
        return (shares * totalAssets_) / totalShares;
    }
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "MockVault: not owner");
        require(_shares[owner] >= shares, "MockVault: insuf shares");
        assets = (shares * totalAssets_) / totalShares;
        _shares[owner] -= shares; totalShares -= shares; totalAssets_ -= assets;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(receiver, assets);
    }
}

interface IPaymentsForTaker {
    function take() external;
    function kick() external;
    function takeWithCallback(bytes calldata data) external;
    function sendUSDC(uint256 amount, address to) external;
}

/// An honest callback taker: it holds cbETH and delivers exactly what is
/// required (or `deliver` if set lower, to test short delivery).
contract HonestTaker_V3 {
    MockCbETH_V3 public cbeth;
    uint256 public deliverOverride;   // 0 = deliver what is required
    uint256 public lastUsdcOut;
    uint256 public lastRequired;
    constructor(address cbeth_) { cbeth = MockCbETH_V3(cbeth_); }
    function setDeliverOverride(uint256 v) external { deliverOverride = v; }
    function possessioTake(uint256 usdcOut, uint256 cbEthRequired, bytes calldata) external {
        lastUsdcOut = usdcOut; lastRequired = cbEthRequired;
        uint256 amt = deliverOverride == 0 ? cbEthRequired : deliverOverride;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        cbeth.transfer(msg.sender, amt);
    }
    function go(address payments, bytes calldata data) external { IPaymentsForTaker(payments).takeWithCallback(data); }
}

/// A taker that re-enters during the callback: into take, kick, or a second
/// takeWithCallback. Every path must hit the reentrancy guard.
contract ReentrantTaker_V3 {
    MockCbETH_V3 public cbeth;
    uint8 public mode;   // 1 = take, 2 = kick, 3 = takeWithCallback
    bool public reentered;
    bytes public innerRevert;
    constructor(address cbeth_) { cbeth = MockCbETH_V3(cbeth_); }
    function setMode(uint8 m) external { mode = m; }
    function possessioTake(uint256, uint256 cbEthRequired, bytes calldata) external {
        if (!reentered) {
            reentered = true;
            bytes memory call_ = mode == 1 ? abi.encodeWithSignature("take()")
                : mode == 2 ? abi.encodeWithSignature("kick()")
                : abi.encodeWithSignature("takeWithCallback(bytes)", bytes(""));
            (bool ok, bytes memory ret) = msg.sender.call(call_);
            require(!ok, "reentry succeeded");
            innerRevert = ret;
        }
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        cbeth.transfer(msg.sender, cbEthRequired);
    }
    function go(address payments) external { IPaymentsForTaker(payments).takeWithCallback(""); }
}
