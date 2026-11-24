// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

import {MockToken} from "../src/MockToken.sol";
import {MockPool} from "../src/MockPool.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {GuardianVaultV3} from "../src/GuardianVaultV3.sol";
import {GuardianReactiveV3} from "../src/GuardianReactiveV3.sol";

/// v3 deployment (watchdog). Same order as v2, with two contracts swapped:
///   1 DeployMarket              (script/Guardian.s.sol)  Base Sepolia  tokens + pool + oracle
///   2 DeployGuardianReactiveV3  (this file)              Lasna         needs ORACLE_ADDRESS, POOL_ADDRESS
///   3 DeployVaultV3             (this file)              Base Sepolia  needs G_REACTIVE_ADDRESS, ...
///   4 LinkVault                 (script/Guardian.s.sol)  Lasna         unchanged (same setVault)
///   5 SeedVault                 (script/Guardian.s.sol)  Base Sepolia  unchanged
/// Demo helpers: NudgePool (this file) wakes the watchdog without Cron; CrashPool / RecoverPool as before.

abstract contract GuardianV3Script is Script {
    function _me() internal returns (address me) {
        (, me,) = vm.readCallers();
    }
}

/// 2. forge script script/GuardianV3.s.sol:DeployGuardianReactiveV3 --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
/// Needs ORACLE_ADDRESS and POOL_ADDRESS. Optional:
///   HIGH_THRESHOLD (70), LOW_THRESHOLD (30), COOLDOWN_SECONDS (60), MAX_AGE_SECONDS (600),
///   BREAKER_BPS (4000 = stop level 40% below the entry price; 0 turns the watchdog off),
///   GRACE_SECONDS (30), ENTRY_PRICE_E18 (1e18, the pool price at deploy: 1.0 for an equal-liquidity pool),
///   CRON_TOPIC0 (0 = no Cron subscription; 0xb499...3c70 = Cron100, about every 2 minutes, billed per tick),
///   REACTIVE_FUND_WEI (1 ether of lREACT).
contract DeployGuardianReactiveV3 is GuardianV3Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address pool = vm.envAddress("POOL_ADDRESS");
        uint256 chainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(84532));
        uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(84532));
        uint8 high = uint8(vm.envOr("HIGH_THRESHOLD", uint256(70)));
        uint8 low = uint8(vm.envOr("LOW_THRESHOLD", uint256(30)));
        uint256 cooldown = vm.envOr("COOLDOWN_SECONDS", uint256(60));
        uint256 maxAge = vm.envOr("MAX_AGE_SECONDS", uint256(600));
        uint256 breakerBps = vm.envOr("BREAKER_BPS", uint256(4_000));
        uint256 grace = vm.envOr("GRACE_SECONDS", uint256(30));
        uint256 entry = vm.envOr("ENTRY_PRICE_E18", uint256(1 ether));
        uint256 cron = vm.envOr("CRON_TOPIC0", uint256(0));
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(1 ether));

        vm.startBroadcast();
        GuardianReactiveV3 r = new GuardianReactiveV3{value: fund}(
            chainId,
            oracle,
            pool,
            destChainId,
            high,
            low,
            cooldown,
            maxAge,
            entry,
            breakerBps,
            grace,
            cron
        );
        vm.stopBroadcast();

        console.log("G_REACTIVE_ADDRESS=%s", address(r));
        console.log("breaker bps:", breakerBps);
        console.log("grace seconds:", grace);
        console.log("cron topic0:", cron);
    }
}

/// 3. forge script script/GuardianV3.s.sol:DeployVaultV3 --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
/// Needs G_REACTIVE_ADDRESS, VOL_ADDRESS, STABLE_ADDRESS, POOL_ADDRESS, ORACLE_ADDRESS.
/// Optional (keep equal to the reactive contract's): HIGH_THRESHOLD, LOW_THRESHOLD, MAX_AGE_SECONDS, BREAKER_BPS.
/// The vault's BREAKER_BPS is its own stop level: it never takes the level from the callback.
contract DeployVaultV3 is GuardianV3Script {
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
        uint256 breakerBps = vm.envOr("BREAKER_BPS", uint256(4_000));
        address proxy = vm.envOr("CALLBACK_PROXY", BASE_SEPOLIA_PROXY);
        uint256 fund = vm.envOr("VAULT_FUND_WEI", uint256(0.01 ether));

        vm.startBroadcast();
        GuardianVaultV3 v = new GuardianVaultV3{value: fund}(
            IPayable(payable(proxy)),
            reactive,
            MockToken(vol),
            MockToken(stable),
            MockPool(pool),
            RiskOracle(oracle),
            high,
            low,
            maxAge,
            breakerBps
        );
        vm.stopBroadcast();

        console.log("VAULT_ADDRESS=%s", address(v));
        console.log("entry price (1e18 = 1.0):", v.entryPriceE18());
        console.log("breaker bps:", breakerBps);
    }
}

/// Demo helper. A tiny swap that wakes the watchdog after its grace period when no Cron subscription is
/// used (any Swap or oracle event does the same; on a busy pool you would not need this).
///   forge script script/GuardianV3.s.sol:NudgePool --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract NudgePool is GuardianV3Script {
    function run() external {
        MockToken vol = MockToken(vm.envAddress("VOL_ADDRESS"));
        MockPool pool = MockPool(vm.envAddress("POOL_ADDRESS"));
        uint256 amount = vm.envOr("NUDGE_VOL_WEI", uint256(1 ether));

        vm.startBroadcast();
        address me = _me();
        vol.mint(me, amount);
        vol.approve(address(pool), amount);
        pool.swap(true, amount, 0, me);
        vm.stopBroadcast();

        console.log("price after (1e18 = 1.0):", pool.priceE18());
    }
}
