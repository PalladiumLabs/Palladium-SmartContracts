// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "../Interfaces/IPDMStaking.sol";

contract PDMStakingScript {
	IPDMStaking immutable pdmStaking;

	constructor(address _PDMStakingAddress) {
		pdmStaking = IPDMStaking(_PDMStakingAddress);
	}

	function stake(uint256 _PDMamount) external {
		IPDMStaking(pdmStaking).stake(_PDMamount);
	}
}
