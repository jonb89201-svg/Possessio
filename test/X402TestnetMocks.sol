// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal EIP-3009 USDC stand-in for the OFFLINE mode of
///         PossessioX402CoreTestnet.t.sol. Faithful to the FiatTokenV2
///         semantics the core actually leans on, so the SAME test assertions
///         run unchanged against real Base Sepolia USDC in fork mode:
///           - EIP-712 domain name "USDC", version "2" (matches the live
///             token's version() - verified on-chain 2026-07-06);
///           - receiveWithAuthorization requires to == msg.sender (the payee
///             check that closes the front-run);
///           - single-use nonce (replay burns - DoD #9's mechanism);
///           - 6 decimals.
///         NOT a full FiatToken: no roles, no blacklist, no permit - the core
///         touches none of those.
contract MockEIP3009USDC {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    bytes32 public immutable DOMAIN_SEPARATOR;

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "MockUSDC: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

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
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[from][nonce], "FiatTokenV2: authorization is used or canceled");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(
                    RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
                ))
            )
        );
        require(ecrecover(digest, v, r, s) == from, "FiatTokenV2: invalid signature");

        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _move(from, to, value);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockUSDC: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

interface ITransferFrom {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Minimal live infra-sink standing in for the Heart (PossessioPool):
///         the accounted door (receiveInfraFunds, pulls via transferFrom) plus
///         the isInfraSink() brick-guard marker. x402Core routes surplus here
///         exactly as it will to the real Heart (forceApprove + receiveInfraFunds).
///         USDC-agnostic (takes an address) so it works offline AND on a fork
///         where the pay token is real Base USDC.
contract MockInfraSink {
    address internal immutable usdc;
    uint256 public received;
    constructor(address u) { usdc = u; }
    function isInfraSink() external pure returns (bool) { return true; }
    function receiveInfraFunds(uint256 amount) external {
        ITransferFrom(usdc).transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

/// @notice A real contract WITHOUT the infra-sink marker — the brick-guard
///         must reject it as heartSink (has code, but isInfraSink() missing).
contract NotAnInfraSink {
    function ping() external pure returns (bool) { return true; }
}
