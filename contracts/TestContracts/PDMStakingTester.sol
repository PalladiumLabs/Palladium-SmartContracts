// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "../PDM/PDMStaking.sol";

contract PDMStakingTester is PDMStaking {
	function requireCallerIsVesselManager() external view callerIsVesselManager {}
}
