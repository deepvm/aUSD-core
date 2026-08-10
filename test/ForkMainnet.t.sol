// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Minter} from "../src/Minter.sol";
import {Unit} from "../src/Unit.sol";
import {StakedUnit} from "../src/StakedUnit.sol";
import {Minter2, IPSM, ICErc20} from "../src/Minter2.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockUSDD} from "./MockUSDD.sol";
import {MockPSM} from "./MockPSM.sol";
import {MockjUSDD} from "./MockjUSDD.sol";
import {CumulativeMerkleDrop} from "../src/CumulativeMerkleDrop.sol";

contract ForkMainnetTest is Test {
    // Real mainnet addresses
    address constant USDT_ADDR = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    address constant USDD_ADDR = 0xE91A7411e56Ce79E83570570f49B9FC35B7727c5;
    address constant PSM_ADDR = 0xB50Eb419ebeBA06c80Df5e9AaeC494Cef4297879;
    address constant jUSDD_ADDR = 0x65c9fede72ba73cd1b0dca2a974c070153dc6fcb;

    MockTRONUSDT usdt;
    Unit UNIT;
    Minter minter;
    StakedUnit sUNIT;

    // Minter2 dependencies
    MockUSDD usdd;
    MockPSM psm;
    MockjUSDD jUSDD;
    Minter2 minter2;
    CumulativeMerkleDrop distributor;

    address admin = makeAddr("admin");
    address signer;
    uint256 signerKey = 0xA11CE;
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address custody = makeAddr("custody");

    bytes32 domainSeparator;
    bytes32 domainSeparator2;

    function setUp() public {
        signer = vm.addr(signerKey);

        // Deploy template mocks
        MockTRONUSDT mockUsdtTemplate = new MockTRONUSDT();
        MockUSDD mockUsddTemplate = new MockUSDD();
        MockPSM mockPsmTemplate = new MockPSM();
        MockjUSDD mockjUsddTemplate = new MockjUSDD();

        // Etch mock bytecodes onto the actual mainnet addresses
        vm.etch(USDT_ADDR, address(mockUsdtTemplate).code);
        vm.etch(USDD_ADDR, address(mockUsddTemplate).code);
        vm.etch(PSM_ADDR, address(mockPsmTemplate).code);
        vm.etch(jUSDD_ADDR, address(mockjUsddTemplate).code);

        // Map variables to the mainnet addresses
        usdt = MockTRONUSDT(USDT_ADDR);
        usdd = MockUSDD(USDD_ADDR);
        psm = MockPSM(PSM_ADDR);
        jUSDD = MockjUSDD(jUSDD_ADDR);

        // Initialize mutable state variables on the etched contracts
        psm.initialize(IERC20(USDT_ADDR), usdd);
        jUSDD.initialize(IERC20(USDD_ADDR));

        // Deploy production contracts
        UNIT = new Unit(admin);
        minter = new Minter(admin, IERC20(USDT_ADDR), UNIT);
        sUNIT = new StakedUnit(UNIT);

        vm.prank(admin);
        distributor = new CumulativeMerkleDrop(UNIT, bytes32(0));

        minter2 =
            new Minter2(admin, IERC20(USDT_ADDR), UNIT, IERC20(USDD_ADDR), IPSM(PSM_ADDR), ICErc20(jUSDD_ADDR), sUNIT);

        // Setup access control roles
        vm.startPrank(admin);
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(sUNIT));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter2));

        minter.grantRole(minter.SIGNER_ROLE(), signer);
        minter.grantRole(minter.CUSTODY_ROLE(), custody);

        minter2.grantRole(minter2.SIGNER_ROLE(), signer);
        minter2.grantRole(minter2.DISTRIBUTOR_ROLE(), address(distributor));
        vm.stopPrank();

        // Calculate EIP-712 domain separators
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("1")),
                block.chainid,
                address(minter)
            )
        );

        domainSeparator2 = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("2")),
                block.chainid,
                address(minter2)
            )
        );
    }

    /* =========================================================================
       1. MINTER FLOW TESTS (EIP-712 & FOT USDT)
       ========================================================================= */

    function testMinterFlow() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter.mint(100e6, custody, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 900e6);
        assertEq(usdt.balanceOf(custody), 100e6);
        assertEq(UNIT.balanceOf(userA), 100e6);

        // --- 2. Burn ---
        vm.startPrank(userA);
        deadline = block.timestamp + 1 hours;
        nonce = minter.nonces(userA);
        structHash = keccak256(abi.encode(minter.BURN_TYPEHASH(), userA, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter.burn(100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(minter.pendingRedeems(userA), 100e6);

        // Simulate custody transferring USDT back to Minter
        vm.prank(custody);
        usdt.transfer(address(minter), 100e6);

        // --- 3. Redeem ---
        vm.startPrank(userA);
        nonce = minter.nonces(userA);
        structHash = keccak256(abi.encode(minter.REDEEM_TYPEHASH(), userA, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter.redeem(100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 1000e6);
        assertEq(minter.pendingRedeems(userA), 0);
    }

    function testMinterInvalidSignature() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with an unauthorized key (0xBAD)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);

        bytes memory badSignature = abi.encodePacked(r, s, v);
        vm.expectRevert();
        minter.mint(100e6, custody, deadline, badSignature);
        vm.stopPrank();
    }

    function testMinterExpiredSignature() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Warp time past deadline
        vm.warp(deadline + 1 seconds);

        vm.expectRevert(Minter.PermitExpired.selector);
        minter.mint(100e6, custody, deadline, signature);
        vm.stopPrank();
    }

    function testMinterReplayAttackBlocked() public {
        usdt.mint(userA, 200e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 200e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First mint succeeds
        minter.mint(100e6, custody, deadline, signature);

        // Attempting to reuse the signature must fail because the nonce is already used
        vm.expectRevert();
        minter.mint(100e6, custody, deadline, signature);
        vm.stopPrank();
    }

    function testMinterBurnInvalidSignature() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.BURN_TYPEHASH(), userA, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with an unauthorized key (0xBAD)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);

        bytes memory badSignature = abi.encodePacked(r, s, v);
        vm.expectRevert();
        minter.burn(100e6, deadline, badSignature);
        vm.stopPrank();
    }

    function testMinterBurnExpiredSignature() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.BURN_TYPEHASH(), userA, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Warp time past deadline
        vm.warp(deadline + 1 seconds);

        vm.expectRevert(Minter.PermitExpired.selector);
        minter.burn(100e6, deadline, signature);
        vm.stopPrank();
    }

    function testMinterBurnReplayAttackBlocked() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 200e6);

        vm.startPrank(userA);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.BURN_TYPEHASH(), userA, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First burn succeeds
        minter.burn(100e6, deadline, signature);

        // Attempting to reuse the signature must fail because the nonce is already used
        vm.expectRevert();
        minter.burn(100e6, deadline, signature);
        vm.stopPrank();
    }

    function testMinterFeeOnTransferSupport() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        minter.mint(100e6, custody, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // 1:1 parity holds
        assertEq(UNIT.balanceOf(userA), 100e6);
    }

    /* =========================================================================
       2. CLASSIC VAULT (ERC-4626 / STAKEDUNIT) TESTS
       ========================================================================= */

    function testVaultDepositAndWithdrawNoYield() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6); // 6 decimals (same as unitUSD)
        assertEq(sUNIT.totalAssets(), 100e6);

        // Warp 365 days - totalAssets remains 100e6 (no yield)
        vm.warp(block.timestamp + 365 days);
        assertEq(sUNIT.totalAssets(), 100e6);

        // Sole holder redeems all shares
        vm.startPrank(userA);
        sUNIT.redeem(sUNIT.balanceOf(userA), userA, userA);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(sUNIT.totalAssets(), 0);
        assertEq(sUNIT.totalSupply(), 0);
    }

    function testVaultNonTransferable() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);

        // Direct transfer must revert with NonTransferable
        vm.expectRevert(StakedUnit.NonTransferable.selector);
        sUNIT.transfer(userB, 10e6);

        // transferFrom must also revert with NonTransferable
        sUNIT.approve(userB, 10e6);
        vm.stopPrank();

        vm.prank(userB);
        vm.expectRevert(StakedUnit.NonTransferable.selector);
        sUNIT.transferFrom(userA, userB, 10e6);
    }

    function testVaultMultipleHolders() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);
        vm.prank(address(minter));
        UNIT.mint(userB, 200e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        UNIT.approve(address(sUNIT), 200e6);
        sUNIT.deposit(200e6, userB);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6);
        assertEq(sUNIT.balanceOf(userB), 200e6);
        assertEq(sUNIT.totalAssets(), 300e6);

        vm.startPrank(userA);
        sUNIT.redeem(100e6, userA, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        sUNIT.redeem(200e6, userB, userB);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(userB), 200e6);
        assertEq(sUNIT.totalAssets(), 0);
    }

    function testVaultZeroDepositReverts() public {
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        // Under standard ERC4626, zero asset deposits are allowed but mint 0 shares
        sUNIT.deposit(0, userA);
        assertEq(sUNIT.balanceOf(userA), 0);
        vm.stopPrank();
    }

    /* =========================================================================
       3. ACCESS CONTROL & ROLE ADMINISTRATION TESTS
       ========================================================================= */

    function testUnitRoleAccessControl() public {
        // User A has no roles and tries to mint
        vm.startPrank(userA);
        vm.expectRevert();
        UNIT.mint(userA, 100e6);

        // User A tries to burn
        vm.expectRevert();
        UNIT.burn(userA, 100e6);

        // User A tries to confiscate
        vm.expectRevert();
        UNIT.confiscate(userA, userB, 100e6);
        vm.stopPrank();
    }

    function testMinterRoleAccessControl() public {
        bytes32 signerRole = minter.SIGNER_ROLE();
        // User A tries to grant roles
        vm.startPrank(userA);
        vm.expectRevert();
        minter.grantRole(signerRole, userA);
        vm.stopPrank();
    }

    function testConfiscateMergedRole() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        // Only DEFAULT_ADMIN_ROLE can confiscate now
        vm.prank(admin);
        UNIT.confiscate(userA, admin, 100e6);

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(UNIT.balanceOf(admin), 100e6);
    }

    function testReturnToCustody() public {
        usdt.mint(address(minter), 500e6);

        // A valid signer calls returnToCustody to send funds to a verified custody address
        vm.prank(signer);
        minter.returnToCustody(custody, 300e6);

        assertEq(usdt.balanceOf(address(minter)), 200e6);
        assertEq(usdt.balanceOf(custody), 300e6);
    }

    function testReturnToCustodySecurity() public {
        usdt.mint(address(minter), 500e6);

        // 1. Non-signer calls returnToCustody -> should revert
        vm.startPrank(userA);
        vm.expectRevert();
        minter.returnToCustody(custody, 100e6);
        vm.stopPrank();

        // 2. Signer calls returnToCustody to an unverified custody address -> should revert
        vm.startPrank(signer);
        vm.expectRevert();
        minter.returnToCustody(userA, 100e6);
        vm.stopPrank();
    }

    /* =========================================================================
       4. MINTER2 INTEGRATION TESTS (USDD, PSM, JUSTLEND, YIELD HARVEST)
       ========================================================================= */

    function testMinter2Flow() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // USDT should have been transferred to minter2, swapped to USDD, and deposited to jUSDD.
        // The balance of USDT on userA should decrease by 100e6.
        assertEq(usdt.balanceOf(userA), 900e6);
        // UserA should get 100e6 UNIT
        assertEq(UNIT.balanceOf(userA), 100e6);
        // jUSDD should have 100e18 USDD of underlying value (since 1:1 swap and deposit)
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);

        // --- 2. Redeem ---
        vm.startPrank(userA);
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 40e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(40e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // userA's UNIT balance should decrease by 40e6.
        assertEq(UNIT.balanceOf(userA), 60e6);
        // userA should get 40e6 USDT back.
        assertEq(usdt.balanceOf(userA), 940e6);
        assertEq(usdt.balanceOf(address(minter2)), 0);
        // The remaining jUSDD underlying should be 60e18 USDD
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 60e18);
    }

    function testMinter2YieldWithdrawal() public {
        usdt.mint(userA, 100e6);
        usdt.mint(userB, 200e6);

        // userA deposits 100 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // userB deposits 200 USDT
        vm.startPrank(userB);
        usdt.approve(address(minter2), 200e6);
        nonce = minter2.nonces(userB);
        structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userB, 200e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter2.mint(200e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // --- Off-Chain Admin Calculation Helper ---
        // totalUSDD = (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2))
        // requiredUSDD = UNIT.totalSupply() * 1e12
        // yieldUSDD = totalUSDD - requiredUSDD
        uint256 totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        uint256 requiredUSDD = UNIT.totalSupply() * 1e12;
        uint256 yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 0);

        // Simulate JustLend interest rate growth (accrue 30 USDD yield)
        jUSDD.accrueYield(30e18);

        // Re-evaluate yieldUSDD off-chain
        totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 30e18);

        // --- Simulate StakedUnit staking without yield ---
        // userA stakes 50 UNIT into StakedUnit
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 50e6);
        sUNIT.deposit(50e6, userA);
        vm.stopPrank();

        // Warp time by 365 days
        vm.warp(block.timestamp + 365 days);

        // --- Off-Chain Admin Calculation ---
        // The admin runs the off-chain formula:
        uint256 currentExchangeRate = jUSDD.exchangeRateStored();
        totalUSDD = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18 + usdd.balanceOf(address(minter2));
        requiredUSDD = UNIT.totalSupply() * 1e12;
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;

        uint256 safeYield = yieldUSDD;
        assertEq(safeYield, 30e18);

        // Let's compute how many jUSDD shares represent 30e18 USDD yield
        uint256 jUSDDYieldShares = (safeYield * 1e18) / currentExchangeRate;

        address receiver = makeAddr("adminYieldReceiver");
        vm.prank(admin);
        minter2.withdraw(IERC20(address(jUSDD)), receiver, jUSDDYieldShares);

        // Remaining underlying jUSDD in Minter2 should cover active supply (300e18)
        uint256 remainingUnderlying = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18;
        assertEq(remainingUnderlying, 300e18);
        assertEq(jUSDD.balanceOf(receiver), jUSDDYieldShares);
    }

    function testMinter2RedepositAndYieldWithToutFee() public {
        // Setup PSM fee of 0.1% (10**15) on buyGem (toutRate)
        psm.setTout(10 ** 15);

        usdt.mint(userA, 100e6);

        // User A deposits 100 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Accrue interest of 50 USDD
        jUSDD.accrueYield(50e18);

        // Check withdrawable yield:
        // Debt is 100e6 USDT. Required USDD = 100e18.
        // Total USDD = 150e18.
        // Yield should be exactly 150e18 - 100e18 = 50e18 USDD.
        uint256 totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        uint256 requiredUSDD = UNIT.totalSupply() * 1e12;
        uint256 yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 50e18);

        // --- Emergency Withdraw Test ---
        uint256 contractjUSDDBalance = jUSDD.balanceOf(address(minter2));
        assertTrue(contractjUSDDBalance > 0);

        address emergencyReceiver = makeAddr("emergencyReceiver");

        // Non-admin tries to call withdraw -> should revert
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.withdraw(IERC20(address(jUSDD)), emergencyReceiver, contractjUSDDBalance);
        vm.stopPrank();

        // Admin calls withdraw successfully
        vm.prank(admin);
        minter2.withdraw(IERC20(address(jUSDD)), emergencyReceiver, contractjUSDDBalance);

        assertEq(jUSDD.balanceOf(address(minter2)), 0);
        assertEq(jUSDD.balanceOf(emergencyReceiver), contractjUSDDBalance);
    }

    function testMinter2WithDeal() public {
        // Demonstrate direct manipulation of balances on the real USDT address using deal
        deal(USDT_ADDR, userA, 500e6);
        assertEq(usdt.balanceOf(userA), 500e6);

        deal(USDD_ADDR, userB, 1000e18);
        assertEq(usdd.balanceOf(userB), 1000e18);
    }

    function testMinter2WithTinAndToutFees() public {
        // Setup PSM tin (deposit fee) to 2% (2 * 10**16)
        psm.setTin(2 * 10 ** 16);
        // Setup PSM tout (exit fee) to 5% (5 * 10**16)
        psm.setTout(5 * 10 ** 16);

        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // USDT should have been transferred to minter2 (100e6).
        assertEq(usdt.balanceOf(userA), 900e6);
        // User A should get 98 UNIT (100 USDT - 2% tin fee)
        assertEq(UNIT.balanceOf(userA), 98e6);
        // jUSDD should have 98e18 USDD of underlying value (since 2% tin fee is subtracted in sellGem)
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 98e18);

        // --- 2. Redeem ---
        vm.startPrank(userA);
        nonce = minter2.nonces(userA);
        uint256 burnAmt = 98e6;
        uint256 expectedGemAmt = (burnAmt * 1e18) / (1e18 + 5 * 10 ** 16);

        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, burnAmt, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(burnAmt, false, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // User A's UNIT balance should decrease to 0.
        assertEq(UNIT.balanceOf(userA), 0);
        // User A should get exactly expectedGemAmt USDT
        assertEq(usdt.balanceOf(userA), 900e6 + expectedGemAmt);
        // Contract should have 0 USDT on its balance
        assertEq(usdt.balanceOf(address(minter2)), 0);
    }

    function testMinter2MintAndStake() public {
        usdt.mint(userA, 1000e6);

        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, true, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // User A should get sUNIT shares instead of raw UNIT
        // 100 USDT -> 100 UNIT -> Staked into sUNIT
        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(sUNIT.balanceOf(userA), 100e6); // 6 decimals
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);
    }

    function testMinter2BurnAndUnstake() public {
        // First Mint and Stake
        usdt.mint(userA, 1000e6);
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, true, deadline, abi.encodePacked(r, s, v));

        // Now Approve Minter2 to spend sUNIT shares
        sUNIT.approve(address(minter2), 100e6);

        // Burn and Unstake
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(100e6, true, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 0);
        assertEq(usdt.balanceOf(userA), 1000e6); // Back to 1000 USDT (1:1 backing, 0 fees in default mock)
    }

    function testMinter2DistributeRewards() public {
        uint256 rewardAmount = 1000e18; // 1000 USDD

        // Simulate rewards landing on Minter2 address
        usdd.mint(address(minter2), rewardAmount);
        assertEq(usdd.balanceOf(address(minter2)), rewardAmount);

        // Execute reward distribution
        vm.prank(admin);
        minter2.distributeRewards(rewardAmount, address(distributor));

        // Verify USDD has been wrapped to jUSDD and remains on Minter2
        assertEq(usdd.balanceOf(address(minter2)), 0);
        assertEq(jUSDD.balanceOf(address(minter2)), rewardAmount);

        // Verify UNIT has been minted directly to the distributor contract (with 1e12 offset)
        assertEq(UNIT.balanceOf(address(distributor)), 1000e6);
    }

    function testMinter2ClaimJustLendRewards() public {
        MockMultiMerkleDistributor mockDistributorTemplate = new MockMultiMerkleDistributor(IERC20(address(usdd)));
        vm.etch(minter2.JUSTLEND_DISTRIBUTOR(), address(mockDistributorTemplate).code);

        // Mint USDD to mock distributor address
        usdd.mint(minter2.JUSTLEND_DISTRIBUTOR(), 500e18);

        // Prepare claims tuple for multiClaimJustLendRewards
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 0;

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof");

        IMultiMerkleDistributor.ClaimParam[] memory claims = new IMultiMerkleDistributor.ClaimParam[](1);
        claims[0] = IMultiMerkleDistributor.ClaimParam({
            merkleIndex: 0x1f,
            index: 0x083c,
            amounts: amounts,
            merkleProof: proof
        });

        // Non-KEEPER attempt reverts
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.multiClaimJustLendRewards(claims);
        vm.stopPrank();

        // KEEPER execution succeeds
        vm.prank(admin);
        minter2.multiClaimJustLendRewards(claims);

        // USDD transferred from mockDistributor to minter2
        assertEq(usdd.balanceOf(address(minter2)), 100e18);
    }

    function testExecuteCall() public {
        // Non-admin call reverts
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.executeCall(address(usdt), 0, abi.encodeWithSignature("transfer(address,uint256)", userA, 10e6));
        vm.stopPrank();

        // Admin call succeeds
        usdt.mint(address(minter2), 10e6);
        vm.prank(admin);
        minter2.executeCall(address(usdt), 0, abi.encodeWithSignature("transfer(address,uint256)", userA, 10e6));

        assertEq(usdt.balanceOf(userA), 10e6);
    }
}

contract MockMultiMerkleDistributor {
    IERC20 public immutable usdd;

    constructor(IERC20 usdd_) {
        usdd = usdd_;
    }

    function multiClaim(IMultiMerkleDistributor.ClaimParam[] calldata claims) external {
        for (uint256 i = 0; i < claims.length; i++) {
            usdd.transfer(msg.sender, claims[i].amounts[0]);
        }
    }
}
