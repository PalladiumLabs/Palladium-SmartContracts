// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./Interfaces/ITroveManager.sol";
import "./Dependencies/PalladiumBase.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IDebtToken.sol";
import "./Interfaces/IFeeCollector.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Addresses.sol";

contract BorrowerOperations is PalladiumBase, ReentrancyGuardUpgradeable, UUPSUpgradeable, IBorrowerOperations {
	using SafeERC20Upgradeable for IERC20Upgradeable;

	string public constant NAME = "BorrowerOperations";

	// --- Connected contract declarations ---

	/* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

	struct LocalVariables_adjustTrove {
		address asset;
		bool isCollIncrease;
		uint256 price;
		uint256 collChange;
		uint256 netDebtChange;
		uint256 debt;
		uint256 coll;
		uint256 oldICR;
		uint256 newICR;
		uint256 newTCR;
		uint256 debtTokenFee;
		uint256 newDebt;
		uint256 newColl;
		uint256 stake;
	}

	struct LocalVariables_openTrove {
		address asset;
		uint256 price;
		uint256 debtTokenFee;
		uint256 netDebt;
		uint256 compositeDebt;
		uint256 ICR;
		uint256 NICR;
		uint256 stake;
		uint256 arrayIndex;
	}

	// --- Initializer ---

	function initialize() public initializer {
		__Ownable_init();
		__UUPSUpgradeable_init();
	}

	// --- Borrower Trove Operations ---

	function openTrove(
		address _asset,
		uint256 _assetAmount,
		uint256 _debtTokenAmount,
		address _upperHint,
		address _lowerHint
	) external override {
		require(IAdminContract(adminContract).getIsActive(_asset), "BorrowerOps: Asset is not active");
		LocalVariables_openTrove memory vars;
		vars.asset = _asset;

		vars.price = IPriceFeed(priceFeed).fetchPrice(vars.asset);
		bool isRecoveryMode = _checkRecoveryMode(vars.asset, vars.price);

		_requireTroveIsNotActive(vars.asset, msg.sender);

		vars.netDebt = _debtTokenAmount;

		if (!isRecoveryMode) {
			vars.debtTokenFee = _triggerBorrowingFee(vars.asset, _debtTokenAmount);
			vars.netDebt = vars.netDebt + vars.debtTokenFee;
		}
		_requireAtLeastMinNetDebt(vars.asset, vars.netDebt);

		// ICR is based on the composite debt, i.e. the requested debt token amount + borrowing fee + gas comp.
		uint256 gasCompensation = IAdminContract(adminContract).getDebtTokenGasCompensation(vars.asset);
		vars.compositeDebt = vars.netDebt + gasCompensation;
		require(vars.compositeDebt != 0, "compositeDebt cannot be 0");

		vars.ICR = PalladiumMath._computeCR(_assetAmount, vars.compositeDebt, vars.price);
		vars.NICR = PalladiumMath._computeNominalCR(_assetAmount, vars.compositeDebt);

		if (isRecoveryMode) {
			_requireICRisAboveCCR(vars.asset, vars.ICR);
		} else {
			_requireICRisAboveMCR(vars.asset, vars.ICR);
			uint256 newTCR = _getNewTCRFromTroveChange(vars.asset, _assetAmount, true, vars.compositeDebt, true, vars.price); // bools: coll increase, debt increase
			_requireNewTCRisAboveCCR(vars.asset, newTCR);
		}

		// Set the trove struct's properties
		ITroveManager(troveManager).setTroveStatus(vars.asset, msg.sender, 1); // Trove Status 1 = Active
		ITroveManager(troveManager).increaseTroveColl(vars.asset, msg.sender, _assetAmount);
		ITroveManager(troveManager).increaseTroveDebt(vars.asset, msg.sender, vars.compositeDebt);

		ITroveManager(troveManager).updateTroveRewardSnapshots(vars.asset, msg.sender);
		vars.stake = ITroveManager(troveManager).updateStakeAndTotalStakes(vars.asset, msg.sender);

		ISortedTroves(sortedTroves).insert(vars.asset, msg.sender, vars.NICR, _upperHint, _lowerHint);
		vars.arrayIndex = ITroveManager(troveManager).addTroveOwnerToArray(vars.asset, msg.sender);
		emit TroveCreated(vars.asset, msg.sender, vars.arrayIndex);

		// Move the asset to the Active Pool, and mint the debtToken amount to the borrower
		_activePoolAddColl(vars.asset, _assetAmount);
		_withdrawDebtTokens(vars.asset, msg.sender, _debtTokenAmount, vars.netDebt);
		// Move the debtToken gas compensation to the Gas Pool
		if (gasCompensation != 0) {
			_withdrawDebtTokens(vars.asset, gasPoolAddress, gasCompensation, gasCompensation);
		}

		emit TroveUpdated(
			vars.asset,
			msg.sender,
			vars.compositeDebt,
			_assetAmount,
			vars.stake,
			BorrowerOperation.openTrove
		);
		emit BorrowingFeePaid(vars.asset, msg.sender, vars.debtTokenFee);
	}

	// Send collateral to a trove
	function addColl(
		address _asset,
		uint256 _assetSent,
		address _upperHint,
		address _lowerHint
	) external override nonReentrant {
		_adjustTrove(_asset, _assetSent, msg.sender, 0, 0, false, _upperHint, _lowerHint);
	}

	// Withdraw collateral from a trove
	function withdrawColl(
		address _asset,
		uint256 _collWithdrawal,
		address _upperHint,
		address _lowerHint
	) external override nonReentrant {
		_adjustTrove(_asset, 0, msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint);
	}

	// Withdraw debt tokens from a trove: mint new debt tokens to the owner, and increase the trove's debt accordingly
	function withdrawDebtTokens(
		address _asset,
		uint256 _debtTokenAmount,
		address _upperHint,
		address _lowerHint
	) external override nonReentrant {
		_adjustTrove(_asset, 0, msg.sender, 0, _debtTokenAmount, true, _upperHint, _lowerHint);
	}

	// Repay debt tokens to a Trove: Burn the repaid debt tokens, and reduce the trove's debt accordingly
	function repayDebtTokens(
		address _asset,
		uint256 _debtTokenAmount,
		address _upperHint,
		address _lowerHint
	) external override nonReentrant {
		_adjustTrove(_asset, 0, msg.sender, 0, _debtTokenAmount, false, _upperHint, _lowerHint);
	}

	function adjustTrove(
		address _asset,
		uint256 _assetSent,
		uint256 _collWithdrawal,
		uint256 _debtTokenChange,
		bool _isDebtIncrease,
		address _upperHint,
		address _lowerHint
	) external override nonReentrant {
		_adjustTrove(
			_asset,
			_assetSent,
			msg.sender,
			_collWithdrawal,
			_debtTokenChange,
			_isDebtIncrease,
			_upperHint,
			_lowerHint
		);
	}

	/*
	 * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
	 */
	function _adjustTrove(
		address _asset,
		uint256 _assetSent,
		address _borrower,
		uint256 _collWithdrawal,
		uint256 _debtTokenChange,
		bool _isDebtIncrease,
		address _upperHint,
		address _lowerHint
	) internal {
		LocalVariables_adjustTrove memory vars;
		vars.asset = _asset;
		vars.price = IPriceFeed(priceFeed).fetchPrice(vars.asset);
		bool isRecoveryMode = _checkRecoveryMode(vars.asset, vars.price);

		if (_isDebtIncrease) {
			_requireNonZeroDebtChange(_debtTokenChange);
		}
		_requireSingularCollChange(_collWithdrawal, _assetSent);
		_requireNonZeroAdjustment(_collWithdrawal, _debtTokenChange, _assetSent);
		_requireTroveIsActive(vars.asset, _borrower);

		// Confirm the operation is either a borrower adjusting their own trove, or a pure asset transfer from the Stability Pool to a trove
		assert(msg.sender == _borrower || (stabilityPool == msg.sender && _assetSent != 0 && _debtTokenChange == 0));

		ITroveManager(troveManager).applyPendingRewards(vars.asset, _borrower);

		// Get the collChange based on whether or not asset was sent in the transaction
		(vars.collChange, vars.isCollIncrease) = _getCollChange(_assetSent, _collWithdrawal);

		vars.netDebtChange = _debtTokenChange;

		// If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
		if (_isDebtIncrease && !isRecoveryMode) {
			vars.debtTokenFee = _triggerBorrowingFee(vars.asset, _debtTokenChange);
			vars.netDebtChange = vars.netDebtChange + vars.debtTokenFee; // The raw debt change includes the fee
		}

		vars.debt = ITroveManager(troveManager).getTroveDebt(vars.asset, _borrower);
		vars.coll = ITroveManager(troveManager).getTroveColl(vars.asset, _borrower);

		// Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
		vars.oldICR = PalladiumMath._computeCR(vars.coll, vars.debt, vars.price);
		vars.newICR = _getNewICRFromTroveChange(
			vars.coll,
			vars.debt,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease,
			vars.price
		);
		require(_collWithdrawal <= vars.coll, "BorrowerOps: bad _collWithdrawal");

		// Check the adjustment satisfies all conditions for the current system mode
		_requireValidAdjustmentInCurrentMode(vars.asset, isRecoveryMode, _collWithdrawal, _isDebtIncrease, vars);

		// When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough debt tokens
		if (!_isDebtIncrease && _debtTokenChange != 0) {
			_requireAtLeastMinNetDebt(vars.asset, _getNetDebt(vars.asset, vars.debt) - vars.netDebtChange);
			_requireValidDebtTokenRepayment(vars.asset, vars.debt, vars.netDebtChange);
			_requireSufficientDebtTokenBalance(_borrower, vars.netDebtChange);
		}

		(vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(
			vars.asset,
			_borrower,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease
		);
		vars.stake = ITroveManager(troveManager).updateStakeAndTotalStakes(vars.asset, _borrower);

		// Re-insert trove in to the sorted list
		uint256 newNICR = _getNewNominalICRFromTroveChange(
			vars.coll,
			vars.debt,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease
		);
		ISortedTroves(sortedTroves).reInsert(vars.asset, _borrower, newNICR, _upperHint, _lowerHint);

		emit TroveUpdated(vars.asset, _borrower, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustTrove);
		emit BorrowingFeePaid(vars.asset, msg.sender, vars.debtTokenFee);

		// Use the unmodified _debtTokenChange here, as we don't send the fee to the user
		_moveTokensFromAdjustment(
			vars.asset,
			msg.sender,
			vars.collChange,
			vars.isCollIncrease,
			_debtTokenChange,
			_isDebtIncrease,
			vars.netDebtChange
		);
	}

	function closeTrove(address _asset) external override {
		_requireTroveIsActive(_asset, msg.sender);
		uint256 price = IPriceFeed(priceFeed).fetchPrice(_asset);
		_requireNotInRecoveryMode(_asset, price);

		ITroveManager(troveManager).applyPendingRewards(_asset, msg.sender);

		uint256 coll = ITroveManager(troveManager).getTroveColl(_asset, msg.sender);
		uint256 debt = ITroveManager(troveManager).getTroveDebt(_asset, msg.sender);

		uint256 gasCompensation = IAdminContract(adminContract).getDebtTokenGasCompensation(_asset);
		uint256 refund = IFeeCollector(feeCollector).simulateRefund(msg.sender, _asset, 1 ether);
		uint256 netDebt = debt - gasCompensation - refund;

		_requireSufficientDebtTokenBalance(msg.sender, netDebt);

		uint256 newTCR = _getNewTCRFromTroveChange(_asset, coll, false, debt, false, price);
		_requireNewTCRisAboveCCR(_asset, newTCR);

		ITroveManager(troveManager).removeStake(_asset, msg.sender);
		ITroveManager(troveManager).closeTrove(_asset, msg.sender);

		emit TroveUpdated(_asset, msg.sender, 0, 0, 0, BorrowerOperation.closeTrove);

		// Burn the repaid debt tokens from the user's balance and the gas compensation from the Gas Pool
		_repayDebtTokens(_asset, msg.sender, netDebt, refund);
		if (gasCompensation != 0) {
			_repayDebtTokens(_asset, gasPoolAddress, gasCompensation, 0);
		}

		// Signal to the fee collector that debt has been paid in full
		IFeeCollector(feeCollector).closeDebt(msg.sender, _asset);

		// Send the collateral back to the user
		IActivePool(activePool).sendAsset(_asset, msg.sender, coll);
	}

	/**
	 * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
	 */
	function claimCollateral(address _asset) external override {
		// send asset from CollSurplusPool to owner
		ICollSurplusPool(collSurplusPool).claimColl(_asset, msg.sender);
	}

	function _triggerBorrowingFee(address _asset, uint256 _debtTokenAmount) internal returns (uint256) {
		uint256 debtTokenFee = ITroveManager(troveManager).getBorrowingFee(_asset, _debtTokenAmount);
		IDebtToken(debtToken).mint(_asset, feeCollector, debtTokenFee);
		IFeeCollector(feeCollector).increaseDebt(msg.sender, _asset, debtTokenFee);
		return debtTokenFee;
	}

	function _getUSDValue(uint256 _coll, uint256 _price) internal pure returns (uint256) {
		return (_price * _coll) / DECIMAL_PRECISION;
	}

	function _getCollChange(
		uint256 _collReceived,
		uint256 _requestedCollWithdrawal
	) internal pure returns (uint256 collChange, bool isCollIncrease) {
		if (_collReceived != 0) {
			collChange = _collReceived;
			isCollIncrease = true;
		} else {
			collChange = _requestedCollWithdrawal;
		}
	}

	// Update trove's coll and debt based on whether they increase or decrease
	function _updateTroveFromAdjustment(
		address _asset,
		address _borrower,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal returns (uint256, uint256) {
		uint256 newColl = (_isCollIncrease)
			? ITroveManager(troveManager).increaseTroveColl(_asset, _borrower, _collChange)
			: ITroveManager(troveManager).decreaseTroveColl(_asset, _borrower, _collChange);
		uint256 newDebt = (_isDebtIncrease)
			? ITroveManager(troveManager).increaseTroveDebt(_asset, _borrower, _debtChange)
			: ITroveManager(troveManager).decreaseTroveDebt(_asset, _borrower, _debtChange);

		return (newColl, newDebt);
	}

	function _moveTokensFromAdjustment(
		address _asset,
		address _borrower,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtTokenChange,
		bool _isDebtIncrease,
		uint256 _netDebtChange
	) internal {
		if (_isDebtIncrease) {
			_withdrawDebtTokens(_asset, _borrower, _debtTokenChange, _netDebtChange);
		} else {
			_repayDebtTokens(_asset, _borrower, _debtTokenChange, 0);
		}
		if (_isCollIncrease) {
			_activePoolAddColl(_asset, _collChange);
		} else {
			IActivePool(activePool).sendAsset(_asset, _borrower, _collChange);
		}
	}

	// Send asset to Active Pool and increase its recorded asset balance
	function _activePoolAddColl(address _asset, uint256 _amount) internal {
		IActivePool(activePool).receivedERC20(_asset, _amount);
		IERC20Upgradeable(_asset).safeTransferFrom(
			msg.sender,
			activePool,
			SafetyTransfer.decimalsCorrection(_asset, _amount)
		);
	}

	// Issue the specified amount of debt tokens to _account and increases the total active debt (_netDebtIncrease potentially includes a debtTokenFee)
	function _withdrawDebtTokens(
		address _asset,
		address _account,
		uint256 _debtTokenAmount,
		uint256 _netDebtIncrease
	) internal {
		uint256 newTotalAssetDebt = IActivePool(activePool).getDebtTokenBalance(_asset) +
			IDefaultPool(defaultPool).getDebtTokenBalance(_asset) +
			_netDebtIncrease;
		require(newTotalAssetDebt <= IAdminContract(adminContract).getMintCap(_asset), "Exceeds mint cap");
		IActivePool(activePool).increaseDebt(_asset, _netDebtIncrease);
		IDebtToken(debtToken).mint(_asset, _account, _debtTokenAmount);
	}

	// Burn the specified amount of debt tokens from _account and decreases the total active debt
	function _repayDebtTokens(address _asset, address _account, uint256 _debtTokenAmount, uint256 _refund) internal {
		/// @dev the borrowing fee partial refund is accounted for when decreasing the debt, as it was included when trove was opened
		IActivePool(activePool).decreaseDebt(_asset, _debtTokenAmount + _refund);
		/// @dev the borrowing fee partial refund is not burned here, as it has already been burned by the FeeCollector
		IDebtToken(debtToken).burn(_account, _debtTokenAmount);
	}

	// --- 'Require' wrapper functions ---

	function _requireSingularCollChange(uint256 _collWithdrawal, uint256 _amountSent) internal pure {
		require(_collWithdrawal == 0 || _amountSent == 0, "BorrowerOperations: Cannot withdraw and add coll");
	}

	function _requireNonZeroAdjustment(
		uint256 _collWithdrawal,
		uint256 _debtTokenChange,
		uint256 _assetSent
	) internal pure {
		require(
			_collWithdrawal != 0 || _debtTokenChange != 0 || _assetSent != 0,
			"BorrowerOps: There must be either a collateral change or a debt change"
		);
	}

	function _requireTroveIsActive(address _asset, address _borrower) internal view {
		uint256 status = ITroveManager(troveManager).getTroveStatus(_asset, _borrower);
		require(status == 1, "BorrowerOps: Trove does not exist or is closed");
	}

	function _requireTroveIsNotActive(address _asset, address _borrower) internal view {
		uint256 status = ITroveManager(troveManager).getTroveStatus(_asset, _borrower);
		require(status != 1, "BorrowerOps: Trove is active");
	}

	function _requireNonZeroDebtChange(uint256 _debtTokenChange) internal pure {
		require(_debtTokenChange != 0, "BorrowerOps: Debt increase requires non-zero debtChange");
	}

	function _requireNotInRecoveryMode(address _asset, uint256 _price) internal view {
		require(!_checkRecoveryMode(_asset, _price), "BorrowerOps: Operation not permitted during Recovery Mode");
	}

	function _requireNoCollWithdrawal(uint256 _collWithdrawal) internal pure {
		require(_collWithdrawal == 0, "BorrowerOps: Collateral withdrawal not permitted Recovery Mode");
	}

	function _requireValidAdjustmentInCurrentMode(
		address _asset,
		bool _isRecoveryMode,
		uint256 _collWithdrawal,
		bool _isDebtIncrease,
		LocalVariables_adjustTrove memory _vars
	) internal view {
		/*
		 * In Recovery Mode, only allow:
		 *
		 * - Pure collateral top-up
		 * - Pure debt repayment
		 * - Collateral top-up with debt repayment
		 * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
		 *
		 * In Normal Mode, ensure:
		 *
		 * - The new ICR is above MCR
		 * - The adjustment won't pull the TCR below CCR
		 */
		if (_isRecoveryMode) {
			_requireNoCollWithdrawal(_collWithdrawal);
			if (_isDebtIncrease) {
				_requireICRisAboveCCR(_asset, _vars.newICR);
				_requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
			}
		} else {
			// if Normal Mode
			_requireICRisAboveMCR(_asset, _vars.newICR);
			_vars.newTCR = _getNewTCRFromTroveChange(
				_asset,
				_vars.collChange,
				_vars.isCollIncrease,
				_vars.netDebtChange,
				_isDebtIncrease,
				_vars.price
			);
			_requireNewTCRisAboveCCR(_asset, _vars.newTCR);
		}
	}

	function _requireICRisAboveMCR(address _asset, uint256 _newICR) internal view {
		require(
			_newICR >= IAdminContract(adminContract).getMcr(_asset),
			"BorrowerOps: An operation that would result in ICR < MCR is not permitted"
		);
	}

	function _requireICRisAboveCCR(address _asset, uint256 _newICR) internal view {
		require(
			_newICR >= IAdminContract(adminContract).getCcr(_asset),
			"BorrowerOps: Operation must leave trove with ICR >= CCR"
		);
	}

	function _requireNewICRisAboveOldICR(uint256 _newICR, uint256 _oldICR) internal pure {
		require(_newICR >= _oldICR, "BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode");
	}

	function _requireNewTCRisAboveCCR(address _asset, uint256 _newTCR) internal view {
		require(
			_newTCR >= IAdminContract(adminContract).getCcr(_asset),
			"BorrowerOps: An operation that would result in TCR < CCR is not permitted"
		);
	}

	function _requireAtLeastMinNetDebt(address _asset, uint256 _netDebt) internal view {
		require(
			_netDebt >= IAdminContract(adminContract).getMinNetDebt(_asset),
			"BorrowerOps: Trove's net debt must be greater than minimum"
		);
	}

	function _requireValidDebtTokenRepayment(address _asset, uint256 _currentDebt, uint256 _debtRepayment) internal view {
		require(
			_debtRepayment <= _currentDebt - IAdminContract(adminContract).getDebtTokenGasCompensation(_asset),
			"BorrowerOps: Amount repaid must not be larger than the Trove's debt"
		);
	}

	function _requireSufficientDebtTokenBalance(address _borrower, uint256 _debtRepayment) internal view {
		require(
			IDebtToken(debtToken).balanceOf(_borrower) >= _debtRepayment,
			"BorrowerOps: Caller doesnt have enough debt tokens to make repayment"
		);
	}

	// --- ICR and TCR getters ---

	// Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
	function _getNewNominalICRFromTroveChange(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal pure returns (uint256) {
		(uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
			_coll,
			_debt,
			_collChange,
			_isCollIncrease,
			_debtChange,
			_isDebtIncrease
		);

		uint256 newNICR = PalladiumMath._computeNominalCR(newColl, newDebt);
		return newNICR;
	}

	// Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
	function _getNewICRFromTroveChange(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease,
		uint256 _price
	) internal pure returns (uint256) {
		(uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
			_coll,
			_debt,
			_collChange,
			_isCollIncrease,
			_debtChange,
			_isDebtIncrease
		);

		uint256 newICR = PalladiumMath._computeCR(newColl, newDebt, _price);
		return newICR;
	}

	function _getNewTroveAmounts(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal pure returns (uint256, uint256) {
		uint256 newColl = _coll;
		uint256 newDebt = _debt;

		newColl = _isCollIncrease ? _coll + _collChange : _coll - _collChange;
		newDebt = _isDebtIncrease ? _debt + _debtChange : _debt - _debtChange;

		return (newColl, newDebt);
	}

	function _getNewTCRFromTroveChange(
		address _asset,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease,
		uint256 _price
	) internal view returns (uint256) {
		uint256 totalColl = getEntireSystemColl(_asset);
		uint256 totalDebt = getEntireSystemDebt(_asset);

		totalColl = _isCollIncrease ? totalColl + _collChange : totalColl - _collChange;
		totalDebt = _isDebtIncrease ? totalDebt + _debtChange : totalDebt - _debtChange;

		uint256 newTCR = PalladiumMath._computeCR(totalColl, totalDebt, _price);
		return newTCR;
	}

	function getCompositeDebt(address _asset, uint256 _debt) external view override returns (uint256) {
		return _getCompositeDebt(_asset, _debt);
	}

	function authorizeUpgrade(address newImplementation) public {
		require(newImplementation != address(0), "BorrowerOperations: new implementation is the zero address");
		_authorizeUpgrade(newImplementation);
	}

	function _authorizeUpgrade(address) internal override onlyOwner {}
}
