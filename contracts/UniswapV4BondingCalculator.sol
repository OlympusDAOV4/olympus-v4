// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import "./interfaces/IBondingCalculator.sol";
import "./interfaces/IUniswapV4PositionManager.sol";
import "./interfaces/IUniswapV4StateView.sol";
import "./libraries/UniswapV4Math.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title  Uniswap V4 Bonding Calculator
/// @notice Replacement for OlympusBondingCalculator (the v2 sqrt(k)*2 calculator)
///         that values a Uniswap V4 *position NFT* held by the Treasury.
///
/// Design notes — see plan file for full rationale:
///   * V4 has no ERC20 LP token. Treasury custody of POL is an ERC721 minted by
///     the canonical PositionManager. `valuation(positionManager, tokenId)` is
///     therefore tokenId-keyed, not amount-keyed; the IBondingCalculator ABI is
///     unchanged because the second arg is just `uint256`.
///   * Spot sqrtPrice is sandwich-able. We read the pool's TWAP tick over an
///     immutable window (>= MIN_TWAP_WINDOW) via StateView.observe, exactly the
///     manipulation-resistance property `2*sqrt(reserve0*reserve1)` gave us in
///     v2.
///   * Pools with non-allowlisted hooks revert. A custom hook can intercept
///     swaps and skew the price the TWAP tracks, so we restrict to a governance
///     allowlist (default: only address(0), i.e. hookless pools).
///   * Final value mirrors the v2 calculator's "double the reserve side":
///     return `2 * reserveAmount` denominated in the reserve token's decimals,
///     where the reserve side is the non-OHM currency. Caller (Treasury) is
///     responsible for converting that to OHM units via tokenValue, just as it
///     does today for v2 LP.
contract UniswapV4BondingCalculator is IBondingCalculator {
    /* ---------------------------- immutables ---------------------------- */

    address public immutable OHM;
    IUniswapV4PositionManager public immutable POSITION_MANAGER;
    IUniswapV4StateView public immutable STATE_VIEW;
    uint32 public immutable TWAP_WINDOW;

    uint32 internal constant MIN_TWAP_WINDOW = 600; // 10 minutes

    /* ----------------------------- storage ------------------------------ */

    /// @dev Hooks the calculator will value. Keyed on hook address. address(0)
    ///      (vanilla pool) is allowed by default. Governance can extend.
    mapping(address => bool) public allowedHooks;
    address public governor;
    /// @dev Two-step transfer: must be set by governor and accepted by the
    ///      target. Prevents typos / sends-to-zero from bricking governance.
    address public pendingGovernor;

    /* ------------------------------ events ------------------------------ */

    event HookAllowed(address indexed hook, bool allowed);
    event GovernorTransferStarted(address indexed prev, address indexed pending);
    event GovernorTransferred(address indexed prev, address indexed next);

    /* ------------------------------ errors ------------------------------ */

    error ZeroAddress();
    error TwapWindowTooShort();
    error NotGovernor();
    error HookNotAllowed(address hook);
    error PoolDoesNotContainOHM();
    error WrongPositionManager(address expected, address actual);
    error LiquidityZero();

    /* --------------------------- constructor ---------------------------- */

    constructor(
        address ohm,
        address positionManager,
        address stateView,
        uint32 twapWindow,
        address governor_
    ) {
        if (ohm == address(0) || positionManager == address(0) || stateView == address(0) || governor_ == address(0)) {
            revert ZeroAddress();
        }
        if (twapWindow < MIN_TWAP_WINDOW) revert TwapWindowTooShort();

        OHM = ohm;
        POSITION_MANAGER = IUniswapV4PositionManager(positionManager);
        STATE_VIEW = IUniswapV4StateView(stateView);
        TWAP_WINDOW = twapWindow;
        governor = governor_;
        allowedHooks[address(0)] = true;
    }

    /* --------------------------- governance ----------------------------- */

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    function setHookAllowed(address hook, bool allowed) external onlyGovernor {
        allowedHooks[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    /// @notice Starts a two-step governor handover. Must be accepted by `next`.
    function transferGovernor(address next) external onlyGovernor {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernor = next;
        emit GovernorTransferStarted(governor, next);
    }

    /// @notice Pending governor accepts the role. Atomic with the transfer.
    function acceptGovernor() external {
        if (msg.sender != pendingGovernor) revert NotGovernor();
        emit GovernorTransferred(governor, msg.sender);
        governor = msg.sender;
        delete pendingGovernor;
    }

    /* --------------------------- IBondingCalculator --------------------- */

    /// @notice Returns 2 * (non-OHM reserve in the position) at TWAP price,
    ///         denominated in the reserve token's native decimals.
    /// @param  asset    MUST equal the immutable POSITION_MANAGER. The asset
    ///                  arg is preserved from IBondingCalculator only so the
    ///                  Treasury's `bondCalculator[asset]` lookup keeps working.
    /// @param  tokenId  PositionManager NFT id.
    function valuation(address asset, uint256 tokenId) external view override returns (uint256) {
        if (asset != address(POSITION_MANAGER)) revert WrongPositionManager(address(POSITION_MANAGER), asset);

        (
            IUniswapV4PositionManager.PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            bytes32 poolId
        ) = _readPosition(tokenId);

        if (!allowedHooks[key.hooks]) revert HookNotAllowed(key.hooks);
        if (liquidity == 0) revert LiquidityZero();

        // Determine which side is the OHM-pegged reserve.
        bool ohmIs0;
        if (key.currency0 == OHM) ohmIs0 = true;
        else if (key.currency1 == OHM) ohmIs0 = false;
        else revert PoolDoesNotContainOHM();

        uint160 sqrtTwapX96 = _twapSqrtPriceX96(poolId);
        uint160 sqrtA = UniswapV4Math.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = UniswapV4Math.getSqrtRatioAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            UniswapV4Math.getAmountsForLiquidity(sqrtTwapX96, sqrtA, sqrtB, liquidity);

        // Mirror v2 calculator: return 2x the non-OHM (reserve) side.
        uint256 reserveAmount = ohmIs0 ? amount1 : amount0;
        return reserveAmount * 2;
    }

    /// @notice Markdown of OHM-equivalent units per (2 * reserveAmount), 1e<OHM-decimals>.
    ///         Matches the semantic of OlympusBondingCalculator.markdown for v2.
    function markdown(address asset) external view override returns (uint256) {
        // V2 calculator's markdown was per-pair and parameterless on amount. For
        // V4 the analog is per-pool, but Treasury wires `bondCalculator[token]`
        // by token, not pool. We therefore reduce markdown to the trivial
        // identity: 1 OHM-decimal of "value" per unit of the calculator's
        // native return. The Treasury's tokenValue path applies its own
        // decimal scaling.
        if (asset != address(POSITION_MANAGER)) revert WrongPositionManager(address(POSITION_MANAGER), asset);
        return 2 * (10 ** IDecimals(OHM).decimals());
    }

    /* ----------------------------- internals ---------------------------- */

    function _readPosition(uint256 tokenId)
        internal
        view
        returns (
            IUniswapV4PositionManager.PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            bytes32 poolId
        )
    {
        uint256 info;
        (key, info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);

        // PositionInfo packing (canonical v4-periphery PositionInfoLibrary):
        //   bits   0..7    : hasSubscriber flag
        //   bits   8..31   : tickUpper (int24)
        //   bits  32..55   : tickLower (int24)
        //   bits 200..255  : truncated poolId (top 56 bits) — full poolId is
        //                    keccak(abi.encode(PoolKey)). We compute it fresh
        //                    from the returned PoolKey so we don't depend on
        //                    the truncation layout.
        tickUpper = int24(uint24(info >> 8));
        tickLower = int24(uint24(info >> 32));

        poolId = keccak256(abi.encode(key));
        liquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
    }

    function _twapSqrtPriceX96(bytes32 poolId) internal view returns (uint160) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = STATE_VIEW.observe(poolId, secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(delta / int56(uint56(TWAP_WINDOW)));
        // Round toward negative infinity (matches v3 OracleLibrary.consult).
        if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW)) != 0)) {
            arithmeticMeanTick--;
        }
        return UniswapV4Math.getSqrtRatioAtTick(arithmeticMeanTick);
    }
}
