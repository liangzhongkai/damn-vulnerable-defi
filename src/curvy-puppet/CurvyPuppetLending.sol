// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {IStableSwap} from "./IStableSwap.sol";
import {CurvyPuppetOracle} from "./CurvyPuppetOracle.sol";
import {console} from "forge-std/console.sol";

contract CurvyPuppetLending is ReentrancyGuard {
    using FixedPointMathLib for uint256;

    address public immutable borrowAsset;
    address public immutable collateralAsset;
    IStableSwap public immutable curvePool;
    IPermit2 public immutable permit2;
    CurvyPuppetOracle public immutable oracle;

    struct Position {
        uint256 collateralAmount;
        uint256 borrowAmount;
    }

    mapping(address who => Position) public positions;

    error InvalidAmount();
    error NotEnoughCollateral();
    error HealthyPosition(uint256 borrowValue, uint256 collateralValue);
    error UnhealthyPosition();

    constructor(address _collateralAsset, IStableSwap _curvePool, IPermit2 _permit2, CurvyPuppetOracle _oracle) {
        borrowAsset = _curvePool.lp_token();
        collateralAsset = _collateralAsset;
        curvePool = _curvePool;
        permit2 = _permit2;
        oracle = _oracle;
    }

    function deposit(uint256 amount) external nonReentrant {
        positions[msg.sender].collateralAmount += amount;
        _pullAssets(collateralAsset, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 remainingCollateral = positions[msg.sender].collateralAmount - amount;
        uint256 remainingCollateralValue = getCollateralValue(remainingCollateral);
        uint256 borrowValue = getBorrowValue(positions[msg.sender].borrowAmount);

        if (borrowValue * 175 > remainingCollateralValue * 100) revert UnhealthyPosition();

        positions[msg.sender].collateralAmount = remainingCollateral;
        IERC20(collateralAsset).transfer(msg.sender, amount);
    }

    function borrow(uint256 amount) external {
        // Get current collateral and borrow values
        uint256 collateralValue = getCollateralValue(positions[msg.sender].collateralAmount);
        uint256 currentBorrowValue = getBorrowValue(positions[msg.sender].borrowAmount);

        uint256 maxBorrowValue = collateralValue * 100 / 175;
        uint256 availableBorrowValue = maxBorrowValue - currentBorrowValue;

        if (amount == type(uint256).max) {
            // set amount to as much borrow tokens as possible, given the available borrow value and the borrow asset's price
            amount = availableBorrowValue.divWadDown(_getLPTokenPrice());
        }

        if (amount == 0) revert InvalidAmount();

        // Now do solvency check
        uint256 borrowAmountValue = getBorrowValue(amount);
        if (currentBorrowValue + borrowAmountValue > maxBorrowValue) revert NotEnoughCollateral();

        // Update caller's position and transfer borrowed assets
        positions[msg.sender].borrowAmount += amount;
        IERC20(borrowAsset).transfer(msg.sender, amount);
    }

    function redeem(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        positions[msg.sender].borrowAmount -= amount;
        _pullAssets(borrowAsset, amount);

        if (positions[msg.sender].borrowAmount == 0) {
            uint256 returnAmount = positions[msg.sender].collateralAmount;
            positions[msg.sender].collateralAmount = 0;
            IERC20(collateralAsset).transfer(msg.sender, returnAmount);
        }
    }

    function liquidate(address target) external nonReentrant {
        uint256 borrowAmount = positions[target].borrowAmount; // 1e18
        uint256 collateralAmount = positions[target].collateralAmount; // 2500e18

        // 2500e18 * 10e18 * 100
        uint256 collateralValue = getCollateralValue(collateralAmount) * 100;
        // 1e18 * (4000 × virtual_price) / 1e18 * 175
        uint256 borrowValue = getBorrowValue(borrowAmount) * 175;
        // collateralValue * 100 < borrowValue * 175
        // 25,000 × 100 < (4000 × virtual_price) × 175
        // 2,500,000 < 700,000 × virtual_price
        // virtual_price > 2,500,000 / 700,000
        // virtual_price > 3.571
        if (collateralValue >= borrowValue) revert HealthyPosition(borrowValue, collateralValue);

        delete positions[target];

        _pullAssets(borrowAsset, borrowAmount);
        IERC20(collateralAsset).transfer(msg.sender, collateralAmount);
    }

    function getBorrowValue(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulWadUp(_getLPTokenPrice());
    }

    function getCollateralValue(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        // oracle.getPrice(collateralAsset).value 也即dvt price
        return amount.mulWadDown(oracle.getPrice(collateralAsset).value);
    }

    function getBorrowAmount(address who) external view returns (uint256) {
        return positions[who].borrowAmount;
    }

    function getCollateralAmount(address who) external view returns (uint256) {
        return positions[who].collateralAmount;
    }

    function _pullAssets(address asset, uint256 amount) private {
        permit2.transferFrom({from: msg.sender, to: address(this), amount: SafeCast.toUint160(amount), token: asset});
    }

    // @view
    // @external
    // def get_virtual_price() -> uint256:
    //     """
    //     @notice The current virtual price of the pool LP token
    //     @dev Useful for calculating profits
    //     @return LP token virtual price normalized to 1e18
    //     """
    //     D: uint256 = self.get_D(self._balances(), self._A())   # D 约等于 balance0 + balance1
    //     token_supply: uint256 = ERC20(self.lp_token).totalSupply()  
    //     return D * PRECISION / token_supply                    # (3.454e22 + 3.554e22) / 6.39e22 = 1.096e18

    // // 1096890440129560193 [1.096e18]
    // cast call 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 "get_virtual_price()(uint256)" \  // curve.get_virtual_price()
    // --rpc-url $MAINNET_FORKING_URL --block 20190356

    // // 34543279685479012272346 [3.454e22]
    // cast call 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 "balances(uint256)(uint256)" 0 \  // curve.balances(0) 即eth
    // --rpc-url $MAINNET_FORKING_URL --block 20190356

    // // 35548870433002420435140 [3.554e22]
    // cast call 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 "balances(uint256)(uint256)" 1 \  // curve.balances(1) 即stETH
    // --rpc-url $MAINNET_FORKING_URL --block 20190356

    // // 63900743099782364043112 [6.39e22]
    // cast call 0x06325440D014e39736583c165C2963BA99fAf14E "totalSupply()(uint256)" \    // lp.totalSupply()
    // --rpc-url $MAINNET_FORKING_URL --block 20190356

    // 要令 (X + 3.554e22) / 6.39e22 > 3.571e18
    // X > 1.926e23
    // X本身有3.454e22, 所以需要增加X > 1.926e23 - 3.454e22 = 1.572e23

    // 结论：
    //      aave v2 flash loan 1.16e23 weth
    //      aave v3 flash loan 8.319e22 weth
    //      需要增加X > 1.572e23 weth
    // export WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // export AWETH_V2=0x030bA81f1c18d280636F32af80b9AAd02Cf0854e
    // export AWETH_V3=0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8
    // export RPC=$MAINNET_FORKING_URL
    // export BLK=20190356
    // cast call $WETH "balanceOf(address)(uint256)" $AWETH_V2 --rpc-url $RPC --block $BLK
    // 116076463816355134246288 [1.16e23]
    // cast call $WETH "balanceOf(address)(uint256)" $AWETH_V3 --rpc-url $RPC --block $BLK
    // 83191993826816279957695 [8.319e22]

    function _getLPTokenPrice() private view returns (uint256) {
        // ETHER_PRICE = 4000e18
        return oracle.getPrice(curvePool.coins(0)).value.mulWadDown(curvePool.get_virtual_price());
    }
}
