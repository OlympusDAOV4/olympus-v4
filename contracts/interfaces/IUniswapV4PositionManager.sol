// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @notice Minimal subset of the canonical Uniswap V4 PositionManager surface
///         needed to value a position NFT. We only depend on read-only methods
///         so that we are not coupled to swap/mint flows.
///
/// Reference: https://github.com/Uniswap/v4-periphery/blob/main/src/PositionManager.sol
interface IUniswapV4PositionManager {
    /// @dev V4 PoolKey, kept inline to avoid pulling in v4-core types.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice Returns the PoolKey and packed PositionInfo for `tokenId`.
    ///         PositionInfo packs (poolId, tickLower, tickUpper, hasSubscriber);
    ///         we expose helper getters below so callers don't need bit-twiddling.
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, uint256 info);

    /// @notice Liquidity owned by `tokenId` in its pool. (Periphery helper that
    ///         delegates to PoolManager.getPositionLiquidity under the hood.)
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice ERC-721 owner-of, used to verify Treasury custody before valuing.
    function ownerOf(uint256 tokenId) external view returns (address);
}
