// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

/// @notice Minimal ERC-721 surface used by Treasury for v4 position custody.
///         Intentionally small to avoid pulling in OZ for one consumer.
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    function transferFrom(address from, address to, uint256 tokenId) external;
}
