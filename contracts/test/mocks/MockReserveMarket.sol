// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockReserveMarket {
    uint256 public realReserve_;
    uint256 public progressBps_;

    function setReserve(uint256 r) external {
        realReserve_ = r;
    }

    function setProgressBps(uint256 p) external {
        progressBps_ = p;
    }

    function realReserve() external view returns (uint256) {
        return realReserve_;
    }

    function progressBps() external view returns (uint256) {
        return progressBps_;
    }
}
