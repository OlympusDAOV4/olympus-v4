// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @notice Minimal subset of the canonical V4 StateView periphery contract. It
///         exposes read-only views over the singleton PoolManager's storage,
///         including TWAP-style observation cumulatives, without paying the
///         gas of an `unlock` callback.
///
/// Reference: https://github.com/Uniswap/v4-periphery/blob/main/src/lens/StateView.sol
interface IUniswapV4StateView {
    /// @notice Returns sqrtPriceX96, current tick, protocol fee, and lp fee for
    ///         a given pool id.
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice Records (tickCumulative, secondsPerLiquidityCumulativeX128) at
    ///         each `secondsAgos[i]`. Mirrors v3's `observe`.
    function observe(bytes32 poolId, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
