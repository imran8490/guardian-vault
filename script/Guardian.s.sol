// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { MockToken } from "../src/MockToken.sol";
import { MockPool } from "../src/MockPool.sol";
import { RiskOracle } from "../src/RiskOracle.sol";
import { GuardianVault } from "../src/GuardianVault.sol";
import { GuardianReactive } from "../src/GuardianReactive.sol";

/// Deployment order (details in README, "Week 2"):
///   1 DeployMarket            Base Sepolia   tokens + pool + oracle
///   2 DeployGuardianReactive  Lasna          needs ORACLE_ADDRESS
///   3 DeployVault             Base Sepolia   needs G_REACTIVE_ADDRESS, VOL/STABLE/POOL
///   4 LinkVault               Lasna          needs G_REACTIVE_ADDRESS, VAULT_ADDRESS
///   5 SeedVault               Base Sepolia   deposit VOL into the vault
/// Demo helpers: PublishRisk, CrashPool, RecoverPool (Base Sepolia).

abstract contract GuardianScript is Script {
    /// @dev Must be called after vm.startBroadcast(): returns the broadcasting (keystore) address.
    function _me() internal returns (address me) {
        (, me,) = vm.readCallers();
    }
}

/// 1. forge script script/Guardian.s.sol:DeployMarket --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
/// Optional env: AI_SIGNER_ADDRESS (default: the deployer), POOL_LIQUIDITY_WEI (default 10_000e18 per side).
contract DeployMarket is GuardianScript {
    function run() external {
        uint256 liq = vm.envOr("POOL_LIQUIDITY_WEI", uint256(10_000 ether));

        vm.startBroadcast();
        address me = _me();
        address signer = vm.envOr("AI_SIGNER_ADDRESS", me);

        MockToken vol = new MockToken("Guardian Volatile", "gVOL");
        MockToken stable = new MockToken("Guardian Stable", "gUSD");
        MockPool pool = new MockPool(vol, stable);

        vol.mint(me, liq);
        stable.mint(me, liq);
        vol.approve(address(pool), liq);
        stable.approve(address(pool), liq);
        pool.addLiquidity(liq, liq);

        RiskOracle oracle = new RiskOracle(signer);
        vm.stopBroadcast();

        console.log("VOL_ADDRESS=%s", address(vol));
        console.log("STABLE_ADDRESS=%s", address(stable));
        console.log("POOL_ADDRESS=%s", address(pool));
        console.log("ORACLE_ADDRESS=%s", address(oracle));
        console.log("AI signer:", signer);
    }
}

/// 2. forge script script/Guardian.s.sol:DeployGuardianReactive --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
/// Needs ORACLE_ADDRESS. Optional: HIGH_THRESHOLD (70), LOW_THRESHOLD (30), COOLDOWN_SECONDS (60),
/// MAX_AGE_SECONDS (600), REACTIVE_FUND_WEI (1 ether of lREACT).
contract DeployGuardianReactive is GuardianScript {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 chainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(84532));
        uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(84532));
        uint8 high = uint8(vm.envOr("HIGH_THRESHOLD", uint256(70)));
        uint8 low = uint8(vm.envOr("LOW_THRESHOLD", uint256(30)));
        uint256 cooldown = vm.envOr("COOLDOWN_SECONDS", uint256(60));
        uint256 maxAge = vm.envOr("MAX_AGE_SECONDS", uint256(600));
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(1 ether));

        vm.startBroadcast();
        GuardianReactive r = new GuardianReactive{ value: fund }(
            chainId, oracle, destChainId, high, low, cooldown, maxAge
        );
        vm.stopBroadcast();

        console.log("G_REACTIVE_ADDRESS=%s", address(r));
    }
}

/// 3. forge script script/Guardian.s.sol:DeployVault --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
/// Needs G_REACTIVE_ADDRESS, VOL_ADDRESS, STABLE_ADDRESS, POOL_ADDRESS, ORACLE_ADDRESS.
/// Optional (keep equal to the reactive contract's): HIGH_THRESHOLD (70), LOW_THRESHOLD (30),
/// MAX_AGE_SECONDS (600). The vault re-checks every callback against the oracle with these.
/// The vault pays for its own callbacks in ETH, so it is funded at deploy (default 0.01 ETH).
contract DeployVault is GuardianScript {
    address constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address reactive = vm.envAddress("G_REACTIVE_ADDRESS");
        address vol = vm.envAddress("VOL_ADDRESS");
        address stable = vm.envAddress("STABLE_ADDRESS");
        address pool = vm.envAddress("POOL_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint8 high = uint8(vm.envOr("HIGH_THRESHOLD", uint256(70)));
        uint8 low = uint8(vm.envOr("LOW_THRESHOLD", uint256(30)));
        uint256 maxAge = vm.envOr("MAX_AGE_SECONDS", uint256(600));
        address proxy = vm.envOr("CALLBACK_PROXY", BASE_SEPOLIA_PROXY);
        uint256 fund = vm.envOr("VAULT_FUND_WEI", uint256(0.01 ether));

        vm.startBroadcast();
        GuardianVault v = new GuardianVault{ value: fund }(
            IPayable(payable(proxy)),
            reactive,
            MockToken(vol),
            MockToken(stable),
            MockPool(pool),
            RiskOracle(oracle),
            high,
            low,
            maxAge
        );
        vm.stopBroadcast();

        console.log("VAULT_ADDRESS=%s", address(v));
    }
}

/// 4. forge script script/Guardian.s.sol:LinkVault --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
/// One-time: tells the reactive contract which vault to call back.
contract LinkVault is GuardianScript {
    function run() external {
        GuardianReactive r = GuardianReactive(payable(vm.envAddress("G_REACTIVE_ADDRESS")));
        address vault = vm.envAddress("VAULT_ADDRESS");

        vm.startBroadcast();
        r.setVault(vault);
        vm.stopBroadcast();

        console.log("Vault linked:", vault);
    }
}

/// 5. forge script script/Guardian.s.sol:SeedVault --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
/// Mints test gVOL to you and deposits it. Optional: SEED_VOL_WEI (default 100 gVOL).
contract SeedVault is GuardianScript {
    function run() external {
        MockToken vol = MockToken(vm.envAddress("VOL_ADDRESS"));
        GuardianVault vault = GuardianVault(payable(vm.envAddress("VAULT_ADDRESS")));
        uint256 amount = vm.envOr("SEED_VOL_WEI", uint256(100 ether));

        vm.startBroadcast();
        address me = _me();
        vol.mint(me, amount);
        vol.approve(address(vault), amount);
        uint256 minted = vault.deposit(amount);
        vm.stopBroadcast();

        console.log("Deposited, shares:", minted);
    }
}

/// Demo helper. Publishes a risk verdict as the AI signer (use before the AI service exists, or to
/// force a scenario). RISK_SCORE (default 90), RISK_REASON (text, hashed on-chain).
///   forge script script/Guardian.s.sol:PublishRisk --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract PublishRisk is GuardianScript {
    function run() external {
        RiskOracle oracle = RiskOracle(vm.envAddress("ORACLE_ADDRESS"));
        uint8 score = uint8(vm.envOr("RISK_SCORE", uint256(90)));
        string memory reason = vm.envOr("RISK_REASON", string("manual test verdict"));

        vm.startBroadcast();
        uint256 epoch = oracle.publishRisk(score, keccak256(bytes(reason)));
        vm.stopBroadcast();

        console.log("Published epoch", epoch);
        console.log("score", score);
    }
}

/// Demo helper. Dumps gVOL into the pool to crash its price. DUMP_VOL_WEI (default 5000 gVOL).
///   forge script script/Guardian.s.sol:CrashPool --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract CrashPool is GuardianScript {
    function run() external {
        MockToken vol = MockToken(vm.envAddress("VOL_ADDRESS"));
        MockPool pool = MockPool(vm.envAddress("POOL_ADDRESS"));
        uint256 amount = vm.envOr("DUMP_VOL_WEI", uint256(5_000 ether));

        vm.startBroadcast();
        address me = _me();
        vol.mint(me, amount);
        vol.approve(address(pool), amount);
        pool.swap(true, amount, 0, me);
        vm.stopBroadcast();

        console.log("price after (1e18 = 1.0):", pool.priceE18());
    }
}

/// Demo helper. Buys gVOL back to restore the price. RECOVER_STABLE_WEI (default 3300 gUSD, which
/// brings a pool crashed by the default 5000 gVOL dump back to roughly parity).
///   forge script script/Guardian.s.sol:RecoverPool --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract RecoverPool is GuardianScript {
    function run() external {
        MockToken stable = MockToken(vm.envAddress("STABLE_ADDRESS"));
        MockPool pool = MockPool(vm.envAddress("POOL_ADDRESS"));
        uint256 amount = vm.envOr("RECOVER_STABLE_WEI", uint256(3_300 ether));

        vm.startBroadcast();
        address me = _me();
        stable.mint(me, amount);
        stable.approve(address(pool), amount);
        pool.swap(false, amount, 0, me);
        vm.stopBroadcast();

        console.log("price after (1e18 = 1.0):", pool.priceE18());
    }
}

/// Optional live demo of the vault's independent check (a race, so it can need a retry): publishes a
/// DANGER verdict and, right behind it, a CALM one. Reactive reacts to the first and requests a de-risk
/// callback; by the time it lands the oracle's latest verdict is calm, so the vault refuses and emits
/// CallbackRejected(epoch, 1, calmScore) instead of selling. If the callback wins the race the vault
/// simply de-risks (a correct outcome); run RecoverPool/reset and try again.
///   forge script script/Guardian.s.sol:PublishSupersede --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract PublishSupersede is GuardianScript {
    function run() external {
        RiskOracle oracle = RiskOracle(vm.envAddress("ORACLE_ADDRESS"));
        vm.startBroadcast();
        uint256 e1 = oracle.publishRisk(90, keccak256("demo: danger verdict (will be superseded)"));
        uint256 e2 = oracle.publishRisk(10, keccak256("demo: calm verdict lands right behind it"));
        vm.stopBroadcast();
        console.log("danger epoch", e1);
        console.log("calm epoch", e2);
    }
}
