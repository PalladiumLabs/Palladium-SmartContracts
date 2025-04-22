// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "../FeeCollector.sol";

contract FeeCollectorTester is FeeCollector {
	bool public __routeToPDMStaking;

	function calcNewDuration(
		uint256 remainingAmount,
		uint256 remainingTimeToLive,
		uint256 addedAmount
	) external pure returns (uint256) {
		return _calcNewDuration(remainingAmount, remainingTimeToLive, addedAmount);
	}

	function setRouteToPDMStaking(bool ___routeToPDMStaking) external onlyOwner {
		__routeToPDMStaking = ___routeToPDMStaking;
	}

	function _routeToPDMStaking() internal view override returns (bool) {
		return __routeToPDMStaking;
	}
}
