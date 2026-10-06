// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

// Inherits
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// Interfaces
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Factory} from "../../Factory.sol";

import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {VaultConnectorRegistry} from "../../modules/connectors/VaultConnectorRegistry.sol";

// Internal
import "../../Types.sol";
import {LibTwoCryptoNG} from "../../utils/LibTwoCryptoNG.sol";
import {ConversionLib} from "./ConversionLib.sol";
import {TwoCryptoNGPreviewLib} from "../../utils/TwoCryptoNGPreviewLib.sol";
import {ContractValidation} from "../../utils/ContractValidation.sol";
import {ZapMathLib} from "../../utils/ZapMathLib.sol";
import {LibExpiry} from "../../utils/LibExpiry.sol";
import {BaseQuoter} from "../BaseQuoter.sol";
import {PT_INDEX, TARGET_INDEX} from "../../Constants.sol";
import "../../Constants.sol" as Constants;
import {Errors} from "../../Errors.sol";

contract Quoter is UUPSUpgradeable, Initializable, Ownable, BaseQuoter {
    using LibTwoCryptoNG for TwoCrypto;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    /// @dev The maximum refund tolerance in basis points (100 = 1%). Revert if the refund is greater than this value.
    uint256 internal constant REFUND_TOLERANCE_BPS = 100;

    address s_WETH;
    address s_twoCryptoDeployer;
    Factory s_factory;
    VaultConnectorRegistry s_vaultConnectorRegistry;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        Factory _factory,
        VaultConnectorRegistry _vaultConnectorRegistry,
        address _twoCryptoDeployer,
        address _WETH,
        address owner
    ) public initializer {
        s_factory = _factory;
        s_vaultConnectorRegistry = _vaultConnectorRegistry;
        s_twoCryptoDeployer = _twoCryptoDeployer;
        s_WETH = _WETH;
        _initializeOwner(owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Overrides                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function factory() public view override returns (Factory) {
        return s_factory;
    }

    function vaultConnectorRegistry() public view override returns (VaultConnectorRegistry) {
        return s_vaultConnectorRegistry;
    }

    function WETH() public view override returns (address) {
        return s_WETH;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Token List                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getTokenInList(address pool) public view returns (Token[] memory) {
        return _getTokenInList(PrincipalToken(TwoCrypto.wrap(pool).coins(PT_INDEX)));
    }

    function getTokenOutList(address pool) public view returns (Token[] memory) {
        return _getTokenOutList(PrincipalToken(TwoCrypto.wrap(pool).coins(PT_INDEX)));
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

    function _delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    modifier checkTwoCrypto(TwoCrypto twoCrypto) {
        ContractValidation.checkTwoCrypto(s_factory, twoCrypto.unwrap(), s_twoCryptoDeployer);
        _;
    }
}
