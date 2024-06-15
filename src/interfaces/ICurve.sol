pragma solidity 0.8.18;


interface ICurveStableSwapNG {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external;
    function price_oracle(uint256 i) external view returns (uint256);
}

