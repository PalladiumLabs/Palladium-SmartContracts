// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/*
This contract is reserved for Linear Vesting to the Team members and the Advisors team.
*/
contract LockedPDM is Ownable, Initializable {
	using SafeERC20 for IERC20;

	struct Rule {
		uint256 createdDate;
		uint256 totalSupply;
		uint256 startVestingDate;
		uint256 endVestingDate;
		uint256 claimed;
	}

	string public constant NAME = "LockedPDM";
	uint256 public constant SIX_MONTHS = 26 weeks;
	uint256 public constant TWO_YEARS = 730 days;

	IERC20 private pdmToken;
	uint256 private assignedPDMTokens;

	mapping(address => Rule) public entitiesVesting;

	modifier entityRuleExists(address _entity) {
		require(entitiesVesting[_entity].createdDate != 0, "Entity doesn't have a Vesting Rule");
		_;
	}

	function setAddresses(address _pdmAddress) public initializer onlyOwner {
		pdmToken = IERC20(_pdmAddress);
	}

	function addEntityVesting(address _entity, uint256 _totalSupply) public onlyOwner {
		require(address(0) != _entity, "Invalid Address");

		require(entitiesVesting[_entity].createdDate == 0, "Entity already has a Vesting Rule");

		assignedPDMTokens += _totalSupply;

		entitiesVesting[_entity] = Rule(
			block.timestamp,
			_totalSupply,
			block.timestamp + SIX_MONTHS,
			block.timestamp + TWO_YEARS,
			0
		);

		pdmToken.safeTransferFrom(msg.sender, address(this), _totalSupply);
	}

	function lowerEntityVesting(address _entity, uint256 newTotalSupply) public onlyOwner entityRuleExists(_entity) {
		sendPDMTokenToEntity(_entity);
		Rule storage vestingRule = entitiesVesting[_entity];

		require(newTotalSupply > vestingRule.claimed, "Total Supply goes lower or equal than the claimed total.");

		vestingRule.totalSupply = newTotalSupply;
	}

	function removeEntityVesting(address _entity) public onlyOwner entityRuleExists(_entity) {
		sendPDMTokenToEntity(_entity);
		Rule memory vestingRule = entitiesVesting[_entity];

		assignedPDMTokens = assignedPDMTokens - (vestingRule.totalSupply - vestingRule.claimed);

		delete entitiesVesting[_entity];
	}

	function claimPDMToken() public entityRuleExists(msg.sender) {
		sendPDMTokenToEntity(msg.sender);
	}

	function sendPDMTokenToEntity(address _entity) private {
		uint256 unclaimedAmount = getClaimablePDM(_entity);
		if (unclaimedAmount == 0) return;

		Rule storage entityRule = entitiesVesting[_entity];
		entityRule.claimed += unclaimedAmount;

		assignedPDMTokens = assignedPDMTokens - unclaimedAmount;
		pdmToken.safeTransfer(_entity, unclaimedAmount);
	}

	function transferUnassignedPDM() external onlyOwner {
		uint256 unassignedTokens = getUnassignPDMTokensAmount();

		if (unassignedTokens == 0) return;

		pdmToken.safeTransfer(msg.sender, unassignedTokens);
	}

	function getClaimablePDM(address _entity) public view returns (uint256 claimable) {
		Rule memory entityRule = entitiesVesting[_entity];
		claimable = 0;

		if (entityRule.startVestingDate > block.timestamp) return claimable;

		if (block.timestamp >= entityRule.endVestingDate) {
			claimable = entityRule.totalSupply - entityRule.claimed;
		} else {
			claimable =
				((entityRule.totalSupply / TWO_YEARS) * (block.timestamp - entityRule.createdDate)) -
				entityRule.claimed;
		}

		return claimable;
	}

	function getUnassignPDMTokensAmount() public view returns (uint256) {
		return pdmToken.balanceOf(address(this)) - assignedPDMTokens;
	}

	function isEntityExits(address _entity) public view returns (bool) {
		return entitiesVesting[_entity].createdDate != 0;
	}
}
