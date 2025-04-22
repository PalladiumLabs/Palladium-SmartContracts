// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "../Dependencies/PalladiumMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/IVesselManager.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/IPDMStaking.sol";
import "./BorrowerOperationsScript.sol";
import "./ETHTransferScript.sol";
import "./PDMStakingScript.sol";

contract BorrowerWrappersScript is BorrowerOperationsScript, ETHTransferScript, PDMStakingScript {
	struct Local_var {
		address _asset;
		uint256 _maxFee;
		address _upperHint;
		address _lowerHint;
		uint256 netVUSDAmount;
	}

	string public constant NAME = "BorrowerWrappersScript";

	IVesselManager immutable vesselManager;
	IStabilityPool immutable stabilityPool;
	IPriceFeed immutable priceFeed;
	IERC20 immutable debtToken;
	IERC20 immutable pdmToken;

	constructor(
		address _borrowerOperationsAddress,
		address _vesselManagerAddress,
		address _PDMStakingAddress
	) BorrowerOperationsScript(IBorrowerOperations(_borrowerOperationsAddress)) PDMStakingScript(_PDMStakingAddress) {
		IVesselManager vesselManagerCached = IVesselManager(_vesselManagerAddress);
		vesselManager = vesselManagerCached;

		IStabilityPool stabilityPoolCached = vesselManagerCached.stabilityPool();
		stabilityPool = stabilityPoolCached;

		IPriceFeed priceFeedCached = vesselManagerCached.adminContract().priceFeed();
		priceFeed = priceFeedCached;

		address debtTokenCached = address(vesselManagerCached.debtToken());
		debtToken = IERC20(debtTokenCached);

		address pdmTokenCached = address(IPDMStaking(_PDMStakingAddress).pdmToken());
		pdmToken = IERC20(pdmTokenCached);

		// IPDMStaking pdmStakingCached = vesselManagerCached.pdmStaking();
		// require(
		// 	_PDMStakingAddress == address(pdmStakingCached),
		// 	"BorrowerWrappersScript: Wrong PDMStaking address"
		// );
	}

	function claimCollateralAndOpenVessel(
		address _asset,
		uint256 _VUSDAmount,
		address _upperHint,
		address _lowerHint
	) external payable {
		uint256 balanceBefore = address(this).balance;

		// Claim collateral
		borrowerOperations.claimCollateral(_asset);

		uint256 balanceAfter = address(this).balance;

		// already checked in CollSurplusPool
		assert(balanceAfter > balanceBefore);

		uint256 totalCollateral = balanceAfter - balanceBefore + msg.value;

		// Open vessel with obtained collateral, plus collateral sent by user
		borrowerOperations.openVessel(_asset, totalCollateral, _VUSDAmount, _upperHint, _lowerHint);
	}

	function claimSPRewardsAndRecycle(address _asset, uint256 _maxFee, address _upperHint, address _lowerHint) external {
		Local_var memory vars = Local_var(_asset, _maxFee, _upperHint, _lowerHint, 0);
		uint256 collBalanceBefore = address(this).balance;
		uint256 PDMBalanceBefore = pdmToken.balanceOf(address(this));

		// Claim rewards
		IStabilityPool(stabilityPool).withdrawFromSP(0);

		uint256 collBalanceAfter = address(this).balance;
		uint256 PDMBalanceAfter = pdmToken.balanceOf(address(this));
		uint256 claimedCollateral = collBalanceAfter - collBalanceBefore;

		// Add claimed ETH to vessel, get more VUSD and stake it into the Stability Pool
		if (claimedCollateral > 0) {
			_requireUserHasVessel(vars._asset, address(this));
			vars.netVUSDAmount = _getNetVUSDAmount(vars._asset, claimedCollateral);
			borrowerOperations.adjustVessel(
				vars._asset,
				claimedCollateral,
				0,
				vars.netVUSDAmount,
				true,
				vars._upperHint,
				vars._lowerHint
			);
			// Provide withdrawn VUSD to Stability Pool
			if (vars.netVUSDAmount > 0) {
				IStabilityPool(stabilityPool).provideToSP(vars.netVUSDAmount);
			}
		}

		// Stake claimed PDM
		uint256 claimedPDM = PDMBalanceAfter - PDMBalanceBefore;
		if (claimedPDM > 0) {
			IPDMStaking(pdmStaking).stake(claimedPDM);
		}
	}

	function claimStakingGainsAndRecycle(
		address _asset,
		uint256 _maxFee,
		address _upperHint,
		address _lowerHint
	) external {
		Local_var memory vars = Local_var(_asset, _maxFee, _upperHint, _lowerHint, 0);

		uint256 collBalanceBefore = address(this).balance;
		uint256 VUSDBalanceBefore = IDebtToken(debtToken).balanceOf(address(this));
		uint256 PDMBalanceBefore = pdmToken.balanceOf(address(this));

		// Claim gains
		IPDMStaking(pdmStaking).unstake(0);

		uint256 gainedCollateral = address(this).balance - collBalanceBefore; // stack too deep issues :'(
		uint256 gainedVUSD = IDebtToken(debtToken).balanceOf(address(this)) - VUSDBalanceBefore;

		// Top up vessel and get more VUSD, keeping ICR constant
		if (gainedCollateral > 0) {
			_requireUserHasVessel(vars._asset, address(this));
			vars.netVUSDAmount = _getNetVUSDAmount(vars._asset, gainedCollateral);
			borrowerOperations.adjustVessel(
				vars._asset,
				gainedCollateral,
				0,
				vars.netVUSDAmount,
				true,
				vars._upperHint,
				vars._lowerHint
			);
		}

		uint256 totalVUSD = gainedVUSD + vars.netVUSDAmount;
		if (totalVUSD > 0) {
			IStabilityPool(stabilityPool).provideToSP(totalVUSD);

			// Providing to Stability Pool also triggers PDM claim, so stake it if any
			uint256 PDMBalanceAfter = pdmToken.balanceOf(address(this));
			uint256 claimedPDM = PDMBalanceAfter - PDMBalanceBefore;
			if (claimedPDM > 0) {
				IPDMStaking(pdmStaking).stake(claimedPDM);
			}
		}
	}

	function _getNetVUSDAmount(address _asset, uint256 _collateral) internal returns (uint256) {
		uint256 price = IPriceFeed(priceFeed).fetchPrice(_asset);
		uint256 ICR = IVesselManager(vesselManager).getCurrentICR(_asset, address(this), price);

		uint256 VUSDAmount = (_collateral * price) / ICR;
		uint256 borrowingRate = IVesselManager(vesselManager).adminContract().getBorrowingFee(_asset);
		uint256 netDebt = (VUSDAmount * PalladiumMath.DECIMAL_PRECISION) /
			(PalladiumMath.DECIMAL_PRECISION + borrowingRate);

		return netDebt;
	}

	function _requireUserHasVessel(address _asset, address _depositor) internal view {
		require(
			IVesselManager(vesselManager).getVesselStatus(_asset, _depositor) == 1,
			"BorrowerWrappersScript: caller must have an active vessel"
		);
	}
}
