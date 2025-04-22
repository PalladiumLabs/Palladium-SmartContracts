// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "../PDM/CommunityIssuance.sol";

contract CommunityIssuanceTester is CommunityIssuance {
	function obtainPDM(uint256 _amount) external {
		pdmToken.transfer(msg.sender, _amount);
	}

	function getLastUpdateTokenDistribution() external view returns (uint256) {
		return _getLastUpdateTokenDistribution();
	}

	function unprotectedIssuePDM() external returns (uint256) {
		return issuePDM();
	}
}
