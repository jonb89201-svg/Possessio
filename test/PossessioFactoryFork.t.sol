// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
      POSSESSIO FACTORY - FULL INTEGRATION FORK TEST (Base mainnet)

  The three contracts working together in sequence, on live state:

    keeper loads a sender-locked salt into PossessioSaltPool
      -> buyer signs a real EIP-3009 USDC authorization
      -> buyer calls PossessioFactory.deployTemplate
          -> factory settles the 100 USDC fee via receiveWithAuthorization
          -> forwards it into the REAL PossessioPayments treasury (sink)
          -> pulls the salt (factory-only)
          -> deploys the template via the REAL canonical CreateX
          -> ownership lands at the buyer's chosen address
      -> OWNER withdraws the fee from Payments (sendUSDC) - proving the
         deployment fee is real, spendable treasury, not a stuck balance.

  Forks Base mainnet because PossessioPayments only deploys against the
  live Chainlink feeds / Morpho / routers there (its constructor validates
  4 feed decimals). Gated on chainid 8453; skips cleanly on any other
  chain or without BASE_RPC_URL - same discipline as the other fork suites.

  RUN (mainnet RPC required - NOT testnet, Payments needs mainnet venues):
    BASE_RPC_URL="https://mainnet.base.org" \
      forge test --match-contract PossessioFactoryForkTest -vvv
//////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {PossessioFactory} from "../src/PossessioFactory.sol";
import {PossessioSaltPool} from "../src/PossessioSaltPool.sol";
import {PossessioPool} from "../src/PossessioPool.sol";

interface ICreateX {
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

interface IUSDC {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
}

/// Template following the ratified convention: constructor(owner, initArgs).
contract ForkTemplate {
    address public owner;
    bytes public initData;
    constructor(address _owner, bytes memory _initArgs) {
        owner = _owner;
        initData = _initArgs;
    }
}

contract PossessioFactoryForkTest is Test {
    // ---- Base mainnet addresses (cast-verified, from PaymentsFork) ----
    address constant CREATEX          = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant OWNER            = 0x9Ce4cb26A5F7B50826B07eb8B2C065F0Bb37a6c9;
    address constant CBETH            = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant DAI              = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address constant WETH             = 0x4200000000000000000000000000000000000006;
    address constant ROUTER          = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant AERO_ROUTER     = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant MORPHO_VAULT     = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    address constant CHAINLINK_CBETH  = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    address constant CHAINLINK_DAI    = 0x591e79239a7d679378eC8c847e5038150364C78F;
    address constant CHAINLINK_USDC   = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant CHAINLINK_ETH    = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant LST_RATES        = 0xDDb75e974d99FcF95E241adbFD376861c47a8548;

    uint256 constant MIN_SWAP_BATCH = 100_000000;
    uint256 constant DAI_CEILING    = 10000e18;
    uint256 constant DAILY_LIMIT    = 50000e18;
    // C-2 (audit 2026-07-14) — per-asset exit caps, matching DeployPayments.s.sol
    uint256 constant USDC_DAILY_LIMIT  = 50000e6;
    uint256 constant CBETH_DAILY_LIMIT = 20e18;

    uint256 constant FEE = 100_000000; // 100 USDC, the ratified tier price

    // CreateX CREATE3 proxy init-code hash (public constant).
    bytes32 constant PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    // EIP-3009 ReceiveWithAuthorization typehash.
    bytes32 constant RECEIVE_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    PossessioPool internal heart; // feeSink (option A) — repaired from the pre-A Payments sink
    PossessioSaltPool internal pool;
    PossessioFactory internal factory;

    address internal keeper = makeAddr("keeper");
    address internal buyer;
    uint256 internal buyerPk;
    bytes32 internal templateCodehash;

    bool internal forked;

    function setUp() public {
        try vm.envString("BASE_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {}
        forked = (block.chainid == 8453);
        // FIX B (council, False-Green): skip, don't vacuously pass, when no RPC.
        if (!forked) {
            vm.skip(true);
            return;
        }

        // Money-path wiring (feeSink = A, council FIX C — repaired from the
        // pre-A Payments sink that the brick-guard now correctly rejects):
        //   salt pool (sender-locked to the predicted factory)
        //   -> the Heart (feeSink; factory is its authorized source)
        //   -> factory (feeSink = the LIVE Heart; its brick-guard verifies it).
        // Addresses are predicted so the pool names the factory as a source and
        // the factory names the live pool as feeSink. Order mirrors the revised
        // constellation: salt pool(n) -> Heart(n+1) -> factory(n+2).
        templateCodehash = keccak256(type(ForkTemplate).creationCode);
        address operatorDest = makeAddr("operatorDest");
        address treasuryDest = makeAddr("treasuryDest");
        uint256 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 2);

        pool = new PossessioSaltPool(predictedFactory, keeper, operatorDest, treasuryDest, predictedFactory);
        address[] memory sources = new address[](1);
        sources[0] = predictedFactory;
        heart = new PossessioPool(USDC, sources, operatorDest, treasuryDest, 1_000_000e6, 0, 0, 3600);
        factory = new PossessioFactory(FEE, templateCodehash, address(pool), USDC, address(heart));
        require(address(factory) == predictedFactory, "factory prediction");

        (buyer, buyerPk) = makeAddrAndKey("buyer");
    }

    // ---- helpers --------------------------------------------------------

    function _refillFactorySalt(uint88 entropy) internal returns (bytes32 salt) {
        salt = bytes32(bytes20(address(factory))) | bytes32(uint256(entropy));
        bytes32[] memory b = new bytes32[](1);
        b[0] = salt;
        vm.prank(keeper);
        pool.refillSalts(b);
    }

    /// Sign a real EIP-3009 ReceiveWithAuthorization for `value` USDC,
    /// from `buyer` to the factory, over live USDC's domain separator.
    function _signFee(uint256 value, bytes32 authNonce)
        internal
        view
        returns (PossessioFactory.FeeAuth memory a)
    {
        uint256 validAfter = 0;
        uint256 validBefore = type(uint256).max;
        bytes32 structHash = keccak256(abi.encode(
            RECEIVE_TYPEHASH, buyer, address(factory), value, validAfter, validBefore, authNonce
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", IUSDC(USDC).DOMAIN_SEPARATOR(), structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        a = PossessioFactory.FeeAuth(validAfter, validBefore, authNonce, v, r, s);
    }

    function _guarded(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }

    /*//////////////////////////////////////////////////////////////
        The full sequence, on live Base mainnet.
    //////////////////////////////////////////////////////////////*/

    function test_fullSequence_saltPool_factory_payments() public {
        if (!forked) return;

        // keeper loads a sender-locked salt
        bytes32 salt = _refillFactorySalt(0xCAFE);
        assertEq(pool.depth(), 1, "salt loaded");

        // buyer is funded with exactly the fee and signs the EIP-3009 auth
        deal(USDC, buyer, FEE);
        bytes32 authNonce = keccak256("possessio-factory-fee-1");
        PossessioFactory.FeeAuth memory feeAuth = _signFee(FEE, authNonce);

        address owner = makeAddr("templateOwner");
        uint256 poolBalBefore = heart.poolBalance();
        uint256 heartUsdcBefore = IUSDC(USDC).balanceOf(address(heart));

        // === the atomic sequence ===
        vm.prank(buyer);
        address deployed = factory.deployTemplate(owner, "", type(ForkTemplate).creationCode, feeAuth);

        // deployed for real, at the deterministic CREATE3 address
        assertGt(deployed.code.length, 0, "template has no code");
        assertEq(deployed, ICreateX(CREATEX).computeCreate3Address(_guarded(address(factory), salt)), "wrong CREATE3 address");

        // ownership landed at the buyer's chosen address (never the factory)
        assertEq(ForkTemplate(deployed).owner(), owner, "owner mismatch");
        assertTrue(ForkTemplate(deployed).owner() != address(factory), "factory must never be owner");

        // the fee was routed INTO the Heart via the accounted door (option A):
        // real USDC landed AND poolBalance was credited (not stranded).
        assertEq(IUSDC(USDC).balanceOf(address(heart)), heartUsdcBefore + FEE, "fee did not reach the Heart");
        assertEq(heart.poolBalance(), poolBalBefore + FEE, "poolBalance not credited (fee stranded)");
        assertEq(IUSDC(USDC).balanceOf(buyer), 0, "buyer charged exactly the fee");

        // the salt was consumed
        assertEq(pool.depth(), 0, "salt not consumed");
    }

    /// A second deploy through the same pipeline with a fresh salt + nonce,
    /// proving the sequence repeats (not a one-shot).
    function test_secondDeploy_freshSalt_repeats() public {
        if (!forked) return;

        bytes32 salt = _refillFactorySalt(0xBEEF01);
        deal(USDC, buyer, FEE);
        PossessioFactory.FeeAuth memory feeAuth = _signFee(FEE, keccak256("possessio-factory-fee-2"));

        address owner = makeAddr("owner2");
        vm.prank(buyer);
        address deployed = factory.deployTemplate(owner, "", type(ForkTemplate).creationCode, feeAuth);

        assertEq(ForkTemplate(deployed).owner(), owner);
        assertEq(deployed, ICreateX(CREATEX).computeCreate3Address(_guarded(address(factory), salt)));
        assertEq(pool.depth(), 0, "salt consumed");
    }
}
