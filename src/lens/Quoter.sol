// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

// Inherits
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// Interfaces
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Factory} from "../Factory.sol";
import {IRewardProxy} from "../interfaces/IRewardProxy.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {VaultConnector, VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";

// Internal
import "../Types.sol";
import {LibTwoCryptoNG} from "../utils/LibTwoCryptoNG.sol";
import {ConversionLib} from "./ConversionLib.sol";
import {TwoCryptoNGPreviewLib} from "../utils/TwoCryptoNGPreviewLib.sol";
import {ContractValidation} from "../utils/ContractValidation.sol";
import {ZapMathLib} from "../utils/ZapMathLib.sol";
import {LibExpiry} from "../utils/LibExpiry.sol";
import {RewardLensLib} from "./RewardLensLib.sol";
import {WAD, PT_INDEX, TARGET_INDEX} from "../Constants.sol";
import "../Constants.sol" as Constants;
import {Errors} from "../Errors.sol";

contract Quoter is UUPSUpgradeable, Initializable, Ownable {
    using LibTwoCryptoNG for TwoCrypto;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    /// @dev The maximum refund tolerance in basis points (100 = 1%). Revert if the refund is greater than this value.
    uint256 internal constant REFUND_TOLERANCE_BPS = 100;

    address public s_WETH;
    address public s_twoCryptoDeployer;
    Factory public s_factory;
    VaultConnectorRegistry public s_vaultConnectorRegistry;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        Factory factory,
        VaultConnectorRegistry vaultConnectorRegistry,
        address twoCryptoDeployer,
        address WETH,
        address owner
    ) public initializer {
        s_factory = factory;
        s_vaultConnectorRegistry = vaultConnectorRegistry;
        s_twoCryptoDeployer = twoCryptoDeployer;
        s_WETH = WETH;
        _initializeOwner(owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Token List                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getTokenInList(TwoCrypto twoCrypto) public view returns (Token[] memory) {
        address underlying = twoCrypto.coins(TARGET_INDEX);
        address asset = address(PrincipalToken(twoCrypto.coins(PT_INDEX)).i_asset());

        VaultConnector connector = s_vaultConnectorRegistry.s_connectors(underlying, asset);
        bool isERC4626 = _isERC4626Depositable(underlying, asset);

        if (connector != VaultConnector(address(0))) {
            // Connector is present
            return connector.getTokenInList();
        } else if (underlying == asset) {
            // Underlying is same as asset. Handle the edge case to avoid duplicate tokens in the list.
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        } else if (isERC4626) {
            // Underlying is like an ERC4626
            bool isWETH = asset == s_WETH;
            Token[] memory tokens = new Token[](isWETH ? 3 : 2);
            tokens[0] = Token.wrap(underlying);
            tokens[1] = Token.wrap(asset);
            if (isWETH) tokens[2] = Token.wrap(Constants.NATIVE_ETH);
            return tokens;
        } else {
            // None of the above
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        }
    }

    function getTokenOutList(TwoCrypto twoCrypto) public view returns (Token[] memory) {
        address underlying = twoCrypto.coins(TARGET_INDEX);
        address asset = address(PrincipalToken(twoCrypto.coins(PT_INDEX)).i_asset());

        VaultConnector connector = s_vaultConnectorRegistry.s_connectors(underlying, asset);
        if (connector != VaultConnector(address(0))) {
            return connector.getTokenOutList();
        } else {
            // Regardless of ERC4626 or not, the token out list is always the underlying token because some ERC4626 have cooldown period for redeeming.
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        }
    }

    function _isERC4626Depositable(address erc4626Like, address asset) internal view returns (bool) {
        if (!ContractValidation.hasCode(erc4626Like)) return false; // No code
        // Calls may fail due to a non-existent function selector
        try ERC4626(erc4626Like).asset() returns (address _asset) {
            if (_asset != asset) return false; // Asset mismatch
        } catch {
            return false;
        }
        try ERC4626(erc4626Like).maxDeposit(address(this)) returns (uint256 maxDeposit) {
            if (maxDeposit == 0) return false; // Deposit limit reached
        } catch {
            return false;
        }
        try ERC4626(erc4626Like).previewDeposit(1) {}
        catch {
            return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 Add Liquidity Preview                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev When total supply is zero, the Curve.calc_token_amount_in() fails.
    function previewAddLiquidityOneToken(TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 liquidity, uint256 principal)
    {
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));

        uint256 shares = vaultPreviewDeposit(principalToken, tokenIn, amountIn);
        uint256 sharesToPool = ZapMathLib.computeSharesToTwoCrypto(twoCrypto, principalToken, shares);

        if (LibExpiry.isExpired(principalToken)) return (0, 0);
        principal = principalToken.previewSupply(shares - sharesToPool);
        liquidity = twoCrypto.calc_token_amount_in({amount0: sharesToPool, amount1: principal});
    }

    function previewAddLiquidity(TwoCrypto twoCrypto, uint256 shares, uint256 principal)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 liquidity)
    {
        liquidity = twoCrypto.calc_token_amount_in({amount0: shares, amount1: principal});
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 Remove Liquidity Preview                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Preview the withdrawal of liquidity `liquidity` from a TwoCrypto pool and convert the withdrawn tokens to a single token `tokenOut`
    function previewRemoveLiquidityOneToken(TwoCrypto twoCrypto, Token tokenOut, uint256 liquidity)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 amountOut)
    {
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));

        uint256 sharesWithdrawn;
        if (LibExpiry.isNotExpired(principalToken)) {
            // If the PT is not expired, withdraw one token (underlying tokens)
            // It may fail if the pool is imbalanced
            sharesWithdrawn = twoCrypto.calc_withdraw_one_coin(liquidity, TARGET_INDEX);
        } else {
            (uint256 shares, uint256 principal) = previewRemoveLiquidity({twoCrypto: twoCrypto, liquidity: liquidity});
            // Reeem the PT and convert the underlying tokens
            uint256 sharesFromPT = principalToken.previewRedeem(principal);
            sharesWithdrawn = shares + sharesFromPT;
        }
        // Convert the shares to the desired token `tokenOut`
        amountOut = vaultPreviewRedeem(principalToken, tokenOut, sharesWithdrawn);
    }

    /// @notice Preview the proportional withdrawal of liquidity from a TwoCrypto pool
    function previewRemoveLiquidity(TwoCrypto twoCrypto, uint256 liquidity)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 shares, uint256 principal)
    {
        uint256 reserve0 = twoCrypto.balances(TARGET_INDEX);
        uint256 reserve1 = twoCrypto.balances(PT_INDEX);
        uint256 totalSupply = twoCrypto.totalSupply();
        if (totalSupply == 0) return (0, 0);
        shares = reserve0 * liquidity / totalSupply;
        principal = reserve1 * liquidity / totalSupply;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Swap PT Preview                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function previewSwapTokenForPt(TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 principal)
    {
        uint256 shares = vaultPreviewDeposit(PrincipalToken(twoCrypto.coins(PT_INDEX)), tokenIn, amountIn);
        principal = twoCrypto.get_dy({i: TARGET_INDEX, j: PT_INDEX, dx: shares});
    }

    function previewSwapPtForToken(TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 amountOut)
    {
        uint256 shares = twoCrypto.get_dy({i: PT_INDEX, j: TARGET_INDEX, dx: principal});
        amountOut = vaultPreviewRedeem(PrincipalToken(twoCrypto.coins(PT_INDEX)), tokenOut, shares);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Swap YT Preview                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function previewSwapYtForToken(TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 amountOut, ApproxValue principalActual, ApproxValue getDxResult)
    {
        PrincipalToken pt = PrincipalToken(twoCrypto.coins(PT_INDEX));

        // NOTE: get_dy and get_dx don't take pool rampping into account.
        uint256 sharesDx = TwoCryptoNGPreviewLib.binsearch_dx(twoCrypto, TARGET_INDEX, PT_INDEX, principal);
        principalActual = ApproxValue.wrap(twoCrypto.get_dy(TARGET_INDEX, PT_INDEX, sharesDx));

        uint256 shares = pt.previewCombine(principalActual.unwrap());

        if (shares < sharesDx) revert Errors.Quoter_InsufficientUnderlyingOutput();

        uint256 sharesOut = shares - sharesDx;
        amountOut = vaultPreviewRedeem(pt, tokenOut, sharesOut);
        getDxResult = ApproxValue.wrap(sharesDx);
    }

    /// @return guessYt The output YT amount
    /// @return sharesBorrow The amount of shares borrowed to execute the swap (i.e. the amount of PT minted)
    /// @return sharesSpent The net amount of shares spent to execute the swap. Excludes the amount of shares refunded.
    function previewSwapTokenForYt(TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (ApproxValue guessYt, ApproxValue sharesBorrow, uint256 sharesSpent)
    {
        uint256 shares = vaultPreviewDeposit(PrincipalToken(twoCrypto.coins(PT_INDEX)), tokenIn, amountIn);
        (guessYt, sharesBorrow, sharesSpent) = _previewSwapUnderlyingForYt(twoCrypto, shares);
    }

    /// @notice Quote the amount of shares needed to swap a given amount of YT for underlying tokens
    /// @return sharesIn The amount of shares needed to get the desired amount of YT.
    /// @return sharesBorrow The amount of shares borrowed to execute the swap (i.e. the amount of PT minted)
    function uncheckedPreviewSwapUnderlyingForExactYt(TwoCrypto twoCrypto, uint256 ytOut)
        public
        view
        returns (uint256 sharesIn, uint256 sharesBorrow)
    {
        sharesBorrow = PrincipalToken(twoCrypto.coins(PT_INDEX)).previewIssue(ytOut);
        uint256 sharesDy = twoCrypto.get_dy({i: PT_INDEX, j: TARGET_INDEX, dx: ytOut});
        sharesIn = sharesBorrow - sharesDy;
    }

    function _previewSwapUnderlyingForYt(TwoCrypto twoCrypto, uint256 shares)
        internal
        view
        returns (ApproxValue, ApproxValue, uint256)
    {
        uint256 low = 0;
        uint256 high = convertSharesToYt(twoCrypto, shares); // Initial guess

        // Step 1: Expand upper bound
        while (true) {
            try this.uncheckedPreviewSwapUnderlyingForExactYt(twoCrypto, high) returns (uint256 requiredShares, uint256)
            {
                if (requiredShares > shares) {
                    break;
                } else {
                    high = high * 2; // Double the guess
                }
            } catch {
                break;
            }
        }

        // Step 2: Binary search
        uint256 guessYt;
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            try this.uncheckedPreviewSwapUnderlyingForExactYt(twoCrypto, mid) returns (uint256 requiredShares, uint256)
            {
                if (requiredShares <= shares) {
                    guessYt = mid; // Cache last value
                    low = mid + 1; // Try larger YT
                } else {
                    high = mid - 1; // Too many shares, try smaller YT
                }
            } catch {
                high = mid - 1; // Revert means YT is too large
            }
        }

        (uint256 sharesSpent, uint256 sharesBorrowed) = uncheckedPreviewSwapUnderlyingForExactYt(twoCrypto, guessYt);

        // If buying YT hits a threshold of max output YT, the refund will be non-zero.
        // For some low decimals tokens, the refund will be always non-zero because of precision loss.
        // Actual transaction will have a small refund because of the error margin for slippage.
        uint256 refund = shares - sharesSpent;
        uint256 refundBps = (refund * Constants.BASIS_POINTS) / shares;
        if (refundBps > REFUND_TOLERANCE_BPS) revert Errors.Quoter_MaximumYtOutputReached();

        return (ApproxValue.wrap(guessYt), ApproxValue.wrap(sharesBorrowed), sharesSpent);
    }

    /// @notice Quote the amount of shares needed to get the desired amount of YT
    function previewSwapUnderlyingForExactYt(TwoCrypto twoCrypto, uint256 ytOut)
        external
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256 sharesSpent, uint256 sharesBorrow)
    {
        (sharesSpent, sharesBorrow) = uncheckedPreviewSwapUnderlyingForExactYt(twoCrypto, ytOut);
    }

    /**
     * @dev Returns the maximal amount of YT one can obtain with a given amount of IBT (i.e without fees or slippage).
     * @dev Gives the upper bound of the interval to perform bisection search in previewFlashSwapExactIBTForYT().
     * @return The upper bound for search interval in root finding algorithms
     */
    function convertSharesToYt(TwoCrypto twoCrypto, uint256 shares)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (uint256)
    {
        uint256 bDecimals = ERC20(twoCrypto.coins(PT_INDEX)).decimals();
        uint256 uDecimals = ERC20(twoCrypto.coins(TARGET_INDEX)).decimals();

        // Convert units:
        // 10^u * (10^18 * 10^b / 10^u / 10^18) => 10^b
        return shares * 10 ** (18 + bDecimals - uDecimals) / ConversionLib.getYtPriceInUnderlying(twoCrypto);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                PrincipalToken Preview                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Preview the amount of `pt` minted for a given amount `amountIn` of `tokenIn`
    /// @dev If `pt` is expired, the preview will return 0
    function previewSupply(PrincipalToken pt, Token tokenIn, uint256 amountIn)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = vaultPreviewDeposit(pt, tokenIn, amountIn);
        return pt.previewSupply(shares);
    }

    /// @notice Preview the amount of `tokenOut` that will be received in return for `principal` amount of `pt`
    /// @dev If `pt` is not expired, the preview will return 0
    function previewRedeem(PrincipalToken pt, Token tokenOut, uint256 principal)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = pt.previewRedeem(principal);
        return vaultPreviewRedeem(pt, tokenOut, shares);
    }

    /// @notice Preview the amount of `tokenOut` that will be received in return for `principal` amount of `pt`
    function previewCombine(PrincipalToken pt, Token tokenOut, uint256 principal)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = pt.previewCombine(principal);
        return vaultPreviewRedeem(pt, tokenOut, shares);
    }

    struct PreviewCollectResult {
        uint256 interest;
        TokenReward[] rewards;
    }

    function previewCollect(PrincipalToken pt, address account)
        public
        view
        checkPrincipalToken(pt)
        returns (PreviewCollectResult memory result)
    {
        result.interest = pt.previewCollect(account);
        result.rewards = RewardLensLib.getTokenRewards(pt, account);
    }

    function previewCollects(PrincipalToken[] calldata pts, address account)
        public
        view
        returns (PreviewCollectResult[] memory result)
    {
        result = new PreviewCollectResult[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            result[i] = previewCollect(pts[i], account);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Vault Preview                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Preview the amount of shares minted for a given amount `amountIn` of `tokenIn`
    /// @dev Reverts if the token is not supported by the vault connector or ERC4626
    function vaultPreviewDeposit(PrincipalToken principalToken, Token tokenIn, uint256 amountIn)
        public
        view
        checkPrincipalToken(principalToken)
        returns (uint256)
    {
        address underlying = principalToken.underlying();
        address asset = address(principalToken.i_asset());
        return _previewDeposit(underlying, asset, tokenIn, amountIn);
    }

    /// @notice Preview the amount of `tokenOut` that will be received for `shares` shares of `principalToken.underlying()`
    /// @dev Reverts if the token is not supported by the vault connector or ERC4626
    function vaultPreviewRedeem(PrincipalToken principalToken, Token tokenOut, uint256 shares)
        public
        view
        checkPrincipalToken(principalToken)
        returns (uint256)
    {
        address underlying = principalToken.underlying();
        address asset = address(principalToken.i_asset());
        return _previewRedeem(underlying, asset, tokenOut, shares);
    }

    function _previewDeposit(address underlying, address asset, Token tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (tokenIn.eq(underlying)) return amountIn; // No need to convert.

        VaultConnector connector = s_vaultConnectorRegistry.s_connectors(underlying, asset);

        if (connector != VaultConnector(address(0))) return connector.previewDeposit(tokenIn, amountIn);
        // Fall back to ERC4626 if the connector is not found
        if (tokenIn.eq(asset) || (tokenIn.isNative() && asset == s_WETH)) {
            (bool s, bytes memory ret) = underlying.staticcall(abi.encodeCall(ERC4626.previewDeposit, (amountIn)));
            if (s && underlying.code.length > 0) return abi.decode(ret, (uint256));
            revert Errors.Quoter_ERC4626FallbackCallFailed();
        }
        revert Errors.Quoter_ConnectorInvalidToken();
    }

    function _previewRedeem(address underlying, address asset, Token tokenOut, uint256 shares)
        internal
        view
        returns (uint256)
    {
        if (tokenOut.eq(underlying)) return shares; // No need to convert.

        VaultConnector connector = s_vaultConnectorRegistry.s_connectors(underlying, asset);

        if (connector != VaultConnector(address(0))) return connector.previewRedeem(tokenOut, shares);
        // Fall back to ERC4626 if the connector is not found
        if (tokenOut.eq(asset) || (tokenOut.isNative() && asset == s_WETH)) {
            (bool s, bytes memory ret) = underlying.staticcall(abi.encodeCall(ERC4626.previewRedeem, (shares)));
            if (s && underlying.code.length > 0) return abi.decode(ret, (uint256));
            revert Errors.Quoter_ERC4626FallbackCallFailed();
        }
        revert Errors.Quoter_ConnectorInvalidToken();
    }

    function _delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    modifier checkTwoCrypto(TwoCrypto twoCrypto) {
        ContractValidation.checkTwoCrypto(s_factory, twoCrypto.unwrap(), s_twoCryptoDeployer);
        _;
    }

    modifier checkPrincipalToken(PrincipalToken principalToken) {
        ContractValidation.checkPrincipalToken(s_factory, address(principalToken));
        _;
    }
}
