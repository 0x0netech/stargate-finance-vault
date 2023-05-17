// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "./interfaces/IStargateRouter.sol";
import "./interfaces/IStargateFarm.sol";
import "./interfaces/IStargatePool.sol";

/// @notice ERC4626 Vault for Stargate Finance
/// @author 0xm00n
contract Vault is ERC4626 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStargatePool;

    /// @notice Uniswap v3 Router
    ISwapRouter private constant uniswapV3Router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    /// @notice Uniswap v3 Quoter
    IQuoter private constant uniswapV3Quoter =
        IQuoter(0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6);

    /// @notice WETH
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Stargate Router contract
    IStargateRouter public immutable stargateRouter;

    /// @notice STG Token
    IERC20 public immutable stgToken;

    /// @notice Stargate Farm
    IStargateFarm public immutable stargateFarm;

    /// @notice LP Token
    IStargatePool public immutable lpToken;

    /// @notice Stargate Pool Id
    uint256 public immutable poolId;

    /// @notice Stargate Farm Id
    uint256 public immutable farmId;

    /* Errors */

    /// @notice Invalid Input
    error InvalidInput();

    /// @notice Vault Constructor
    /// @param _name Vault name
    /// @param _symbol Vault symbol
    /// @param _asset Vault underlying asset
    /// @param _lpToken Stargate LP token
    /// @param _stargateRouter Stargate router contract
    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _asset,
        IStargatePool _lpToken,
        IERC20 _stgToken,
        IStargateRouter _stargateRouter,
        IStargateFarm _stargateFarm,
        uint256 _poolId,
        uint256 _farmId
    ) ERC20(_name, _symbol) ERC4626(_asset) {
        if (address(_lpToken) == address(0)) revert InvalidInput();
        if (_lpToken.token() != address(_asset)) revert InvalidInput();
        if (address(_stgToken) == address(0)) revert InvalidInput();
        if (address(_stargateRouter) == address(0)) revert InvalidInput();
        if (address(_stargateFarm) == address(0)) revert InvalidInput();

        lpToken = _lpToken;
        stgToken = _stgToken;
        stargateRouter = IStargateRouter(_stargateRouter);
        stargateFarm = _stargateFarm;
        poolId = _poolId;
        farmId = _farmId;
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256 _totalAssets) {
        (uint256 lpAmount, ) = stargateFarm.userInfo(farmId, address(this));
        _totalAssets = _amountLPtoLD(lpAmount);

        uint256 pendingStg = stargateFarm.pendingStargate(
            farmId,
            address(this)
        );
        if (pendingStg > 0) {
            bytes memory path = abi.encodePacked(
                address(stgToken),
                uint24(3000),
                WETH,
                uint24(3000),
                asset()
            );
            (bool success, bytes memory response) = address(uniswapV3Quoter)
                .staticcall(
                    abi.encodeWithSignature(
                        "quoteExactInput(bytes,uint256)",
                        path,
                        pendingStg
                    )
                );
            if (success) {
                uint256 amountOut = abi.decode(response, (uint256));
                _totalAssets += amountOut;
            }
        }
    }

    /// @inheritdoc ERC4626
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);

        _depositToFarm(assets);
    }

    /// @inheritdoc ERC4626
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 lpToRemove = _amountLDtoLP(assets);
        (uint256 lpAmount, ) = stargateFarm.userInfo(farmId, address(this));

        if (lpToRemove > lpAmount) {
            lpToRemove = lpAmount;
        }

        if (lpToRemove != 0) {
            _withdrawFromFarm(lpToRemove);
            _sellReward();
        }

        IERC20 token = IERC20(asset());
        uint256 currTokenBalance = token.balanceOf(address(this));
        if (assets > currTokenBalance) {
            shares = (shares * currTokenBalance) / assets;
            assets = currTokenBalance;
        } else if (currTokenBalance > assets) {
            _depositToFarm(currTokenBalance - assets);
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _depositToFarm(uint256 amount) internal {
        IERC20(asset()).safeApprove(address(stargateRouter), 0);
        IERC20(asset()).safeApprove(address(stargateRouter), amount);

        stargateRouter.addLiquidity(poolId, amount, address(this));

        uint256 lpBalance = lpToken.balanceOf(address(this));

        lpToken.safeApprove(address(stargateFarm), lpBalance);
        stargateFarm.deposit(farmId, lpBalance);
    }

    function _withdrawFromFarm(uint256 _lpAmount) internal {
        stargateFarm.withdraw(farmId, _lpAmount);
        stargateRouter.instantRedeemLocal(
            uint16(poolId),
            _lpAmount,
            address(this)
        );
        uint256 remainLp = lpToken.balanceOf(address(this));
        if (remainLp != 0) {
            lpToken.safeApprove(address(stargateFarm), 0);
            lpToken.safeApprove(address(stargateFarm), remainLp);
            stargateFarm.deposit(farmId, remainLp);
        }
    }

    function _sellReward() private {
        uint256 stgBalance = stgToken.balanceOf(address(this));

        if (stgBalance != 0) {
            stgToken.safeApprove(address(uniswapV3Router), 0);
            stgToken.safeApprove(address(uniswapV3Router), stgBalance);
            bytes memory path = abi.encodePacked(
                address(stgToken),
                uint24(3000),
                WETH,
                uint24(3000),
                asset()
            );
            uniswapV3Router.exactInput(
                ISwapRouter.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: stgBalance,
                    amountOutMinimum: 0
                })
            );
        }
    }

    function _amountLDtoLP(
        uint256 _amountLD
    ) internal view returns (uint256 _amountLP) {
        uint256 _amountSD = _amountLDtoSD(_amountLD);
        _amountLP =
            (_amountSD * lpToken.totalSupply()) /
            lpToken.totalLiquidity();
    }

    function _amountLPtoLD(
        uint256 _amountLP
    ) internal view returns (uint256 _amountLD) {
        uint256 _amountSD = (_amountLP * lpToken.totalLiquidity()) /
            lpToken.totalSupply();
        _amountLD = _amountSDtoLD(_amountSD);
    }

    function _amountLDtoSD(
        uint256 _amountLD
    ) internal view returns (uint256 _amountSD) {
        _amountSD = _amountLD / lpToken.convertRate();
    }

    function _amountSDtoLD(
        uint256 _amountSD
    ) internal view returns (uint256 _amountLD) {
        _amountLD = _amountSD * lpToken.convertRate();
    }
}
