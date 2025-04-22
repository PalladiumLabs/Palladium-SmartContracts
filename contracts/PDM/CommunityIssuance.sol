// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../Dependencies/BaseMath.sol";
import "../Dependencies/PalladiumMath.sol";

import "../Interfaces/ICommunityIssuance.sol";
import "../Interfaces/IStabilityPool.sol";

contract CommunityIssuance is ICommunityIssuance, OwnableUpgradeable, BaseMath {
	using SafeERC20Upgradeable for IERC20Upgradeable;

	string public constant NAME = "CommunityIssuance";

	uint256 public constant DISTRIBUTION_DURATION = 7 days / 60;
	uint256 public constant SECONDS_IN_ONE_MINUTE = 60;

	uint256 public totalPDMIssued;
	uint256 public lastUpdateTime;
	uint256 public PDMSupplyCap;
	uint256 public pdmDistribution;

	IERC20Upgradeable public pdmToken;
	IStabilityPool public stabilityPool;

	address public adminContract;
	bool public isSetupInitialized;

	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permission");
		_;
	}

	modifier isStabilityPool(address _pool) {
		require(address(stabilityPool) == _pool, "CommunityIssuance: caller is not SP");
		_;
	}

	modifier onlyStabilityPool() {
		require(address(stabilityPool) == msg.sender, "CommunityIssuance: caller is not SP");
		_;
	}

	// --- Initializer ---

	function initialize() public initializer {
		__Ownable_init();
	}

	// --- Functions ---
	function setAddresses(
		address _pdmTokenAddress,
		address _stabilityPoolAddress,
		address _adminContract
	) external onlyOwner {
		require(!isSetupInitialized, "Setup is already initialized");
		adminContract = _adminContract;
		pdmToken = IERC20Upgradeable(_pdmTokenAddress);
		stabilityPool = IStabilityPool(_stabilityPoolAddress);
		isSetupInitialized = true;
	}

	function setAdminContract(address _admin) external onlyOwner {
		require(_admin != address(0));
		adminContract = _admin;
	}

	function addFundToStabilityPool(uint256 _assignedSupply) external override isController {
		_addFundToStabilityPoolFrom(_assignedSupply, msg.sender);
	}

	function removeFundFromStabilityPool(uint256 _fundToRemove) external onlyOwner {
		uint256 newCap = PDMSupplyCap - _fundToRemove;
		require(totalPDMIssued <= newCap, "CommunityIssuance: Stability Pool doesn't have enough supply.");

		PDMSupplyCap -= _fundToRemove;

		pdmToken.safeTransfer(msg.sender, _fundToRemove);
	}

	function addFundToStabilityPoolFrom(uint256 _assignedSupply, address _spender) external override isController {
		_addFundToStabilityPoolFrom(_assignedSupply, _spender);
	}

	function _addFundToStabilityPoolFrom(uint256 _assignedSupply, address _spender) internal {
		if (lastUpdateTime == 0) {
			lastUpdateTime = block.timestamp;
		}

		PDMSupplyCap += _assignedSupply;
		pdmToken.safeTransferFrom(_spender, address(this), _assignedSupply);
	}

	function issuePDM() public override onlyStabilityPool returns (uint256) {
		uint256 maxPoolSupply = PDMSupplyCap;

		if (totalPDMIssued >= maxPoolSupply) return 0;

		uint256 issuance = _getLastUpdateTokenDistribution();
		uint256 totalIssuance = issuance + totalPDMIssued;

		if (totalIssuance > maxPoolSupply) {
			issuance = maxPoolSupply - totalPDMIssued;
			totalIssuance = maxPoolSupply;
		}

		lastUpdateTime = block.timestamp;
		totalPDMIssued = totalIssuance;
		emit TotalPDMIssuedUpdated(totalIssuance);

		return issuance;
	}

	function _getLastUpdateTokenDistribution() internal view returns (uint256) {
		require(lastUpdateTime != 0, "Stability pool hasn't been assigned");
		uint256 timePassed = (block.timestamp - lastUpdateTime) / SECONDS_IN_ONE_MINUTE;
		uint256 totalDistribuedSinceBeginning = pdmDistribution * timePassed;

		return totalDistribuedSinceBeginning;
	}

	function sendPDM(address _account, uint256 _PDMamount) external override onlyStabilityPool {
		uint256 balancePDM = pdmToken.balanceOf(address(this));
		uint256 safeAmount = balancePDM >= _PDMamount ? _PDMamount : balancePDM;

		if (safeAmount == 0) {
			return;
		}

		IERC20Upgradeable(address(pdmToken)).safeTransfer(_account, safeAmount);
	}

	function setWeeklyPdmDistribution(uint256 _weeklyReward) external isController {
		pdmDistribution = _weeklyReward / DISTRIBUTION_DURATION;
	}
}
