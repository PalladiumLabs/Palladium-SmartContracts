// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface ICommunityIssuance {
	// --- Events ---

	event TotalPDMIssuedUpdated(uint256 _totalPDMIssued);

	// --- Functions ---

	function issuePDM() external returns (uint256);

	function sendPDM(address _account, uint256 _PDMamount) external;

	function addFundToStabilityPool(uint256 _assignedSupply) external;

	function addFundToStabilityPoolFrom(uint256 _assignedSupply, address _spender) external;

	function setWeeklyPdmDistribution(uint256 _weeklyReward) external;
}
