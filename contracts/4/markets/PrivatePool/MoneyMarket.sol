pragma solidity ^0.4.24;

import "./Exponential.sol";
import "./InterestRateModel.sol";
import "./PriceOracleInterface.sol";
import "./SafeToken.sol";
import "../../library/Whitelist.sol";

contract ReentrancyGuard {
    bool internal notEntered;

    constructor() internal {
        // Storing an initial non-zero value makes deployment a bit more
        // expensive, but in exchange the refund on every call to nonReentrant
        // will be lower in amount. Since refunds are capped to a percetange of
        // the total transaction's gas, it is best to keep them low in cases
        // like this one, to increase the likelihood of the full refund coming
        // into effect.
        notEntered = true;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, notEntered will be true
        require(notEntered, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        notEntered = false;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        notEntered = true;
    }
}

/**
 * @title  MoneyMarket Contract
 * @notice  MoneyMarket Contract in the core contract governing
 *         all accounts.
 */
contract MoneyMarket is Exponential, SafeToken, Whitelist, ReentrancyGuard {
    uint256 constant initialInterestIndex = 10**18;
    uint256 constant defaultOriginationFee = 0; // default is zero bps

    uint256 constant minimumCollateralRatioMantissa = 11 * (10**17); // 1.1
    uint256 constant maximumLiquidationDiscountMantissa = (10**17); // 0.1

    bool private initialized; // Flags for initializing data

    /**
     * @notice `MoneyMarket` is the core MoneyMarket contract
     */
    constructor() public {
        initialize();
    }

    function initialize() public {
        require(!initialized, "initialize: Already initialized!");
        admin = msg.sender;
        collateralRatio = Exp({mantissa: 2 * mantissaOne});
        originationFee = Exp({mantissa: defaultOriginationFee});
        liquidationDiscount = Exp({mantissa: 0});
        notEntered = true;
        owner = msg.sender;
        // oracle must be configured via _setOracle
        initialized = true;
    }

    /**
     * @notice Do not pay directly into MoneyMarket, please use `supply`.
     */
    function() public payable {
        revert();
    }

    /**
     * @dev pending Administrator for this contract.
     */
    address public pendingAdmin;

    /**
     * @dev Administrator for this contract. Initially set in constructor, but can
     *      be changed by the admin itself.
     */
    address public admin;

    /**
     * @dev Account allowed to set oracle prices for this contract. Initially set
     *      in constructor, but can be changed by the admin.
     */
    address public oracle;

    /**
     * @dev Container for customer balance information written to storage.
     *
     *      struct Balance {
     *        principal = customer total balance with accrued interest after applying the customer's most recent balance-changing action
     *        interestIndex = the total interestIndex as calculated after applying the customer's most recent balance-changing action
     *      }
     */
    struct Balance {
        uint256 principal;
        uint256 interestIndex;
    }

    /**
     * @dev 2-level map: customerAddress -> assetAddress -> balance for supplies
     */
    mapping(address => mapping(address => Balance)) public supplyBalances;

    /**
     * @dev 2-level map: customerAddress -> assetAddress -> balance for borrows
     */
    mapping(address => mapping(address => Balance)) public borrowBalances;

    /**
     * @dev Container for per-asset balance sheet and interest rate information written to storage, intended to be stored in a map where the asset address is the key
     *
     *      struct Market {
     *         isSupported = Whether this market is supported or not (not to be confused with the list of collateral assets)
     *         blockNumber = when the other values in this struct were calculated
     *         totalSupply = total amount of this asset supplied (in asset wei)
     *         supplyRateMantissa = the per-block interest rate for supplies of asset as of blockNumber, scaled by 10e18
     *         supplyIndex = the interest index for supplies of asset as of blockNumber; initialized in _supportMarket
     *         totalBorrows = total amount of this asset borrowed (in asset wei)
     *         borrowRateMantissa = the per-block interest rate for borrows of asset as of blockNumber, scaled by 10e18
     *         borrowIndex = the interest index for borrows of asset as of blockNumber; initialized in _supportMarket
     *     }
     */
    struct Market {
        bool isSupported;
        uint256 blockNumber;
        InterestRateModel interestRateModel;
        uint256 totalSupply;
        uint256 supplyRateMantissa;
        uint256 supplyIndex;
        uint256 totalBorrows;
        uint256 borrowRateMantissa;
        uint256 borrowIndex;
    }

    /**
     * @dev map: assetAddress -> Market
     */
    mapping(address => Market) public markets;

    /**
     * @dev list: collateralMarkets
     */
    address[] public collateralMarkets;

    /**
     * @dev The collateral ratio that borrows must maintain (e.g. 2 implies 2:1). This
     *      is initially set in the constructor, but can be changed by the admin.
     */
    Exp public collateralRatio;

    /**
     * @dev originationFee for new borrows.
     *
     */
    Exp public originationFee;

    /**
     * @dev liquidationDiscount for collateral when liquidating borrows
     *
     */
    Exp public liquidationDiscount;

    /**
     * @dev flag for whether or not contract is paused
     *
     */
    bool public paused;

    /**
     * @dev emitted when a supply is received
     *      Note: newBalance - amount - startingBalance = interest accumulated since last change
     */
    event SupplyReceived(
        address account,
        address asset,
        uint256 amount,
        uint256 startingBalance,
        uint256 newBalance
    );

    /**
     * @dev emitted when a supply is withdrawn
     *      Note: startingBalance - amount - startingBalance = interest accumulated since last change
     */
    event SupplyWithdrawn(
        address account,
        address asset,
        uint256 amount,
        uint256 startingBalance,
        uint256 newBalance
    );

    /**
     * @dev emitted when a new borrow is taken
     *      Note: newBalance - borrowAmountWithFee - startingBalance = interest accumulated since last change
     */
    event BorrowTaken(
        address account,
        address asset,
        uint256 amount,
        uint256 startingBalance,
        uint256 borrowAmountWithFee,
        uint256 newBalance
    );

    /**
     * @dev emitted when a borrow is repaid
     *      Note: newBalance - amount - startingBalance = interest accumulated since last change
     */
    event BorrowRepaid(
        address account,
        address asset,
        uint256 amount,
        uint256 startingBalance,
        uint256 newBalance
    );

    /**
     * @dev emitted when a borrow is liquidated
     *      targetAccount = user whose borrow was liquidated
     *      assetBorrow = asset borrowed
     *      borrowBalanceBefore = borrowBalance as most recently stored before the liquidation
     *      borrowBalanceAccumulated = borroBalanceBefore + accumulated interest as of immediately prior to the liquidation
     *      amountRepaid = amount of borrow repaid
     *      liquidator = account requesting the liquidation
     *      assetCollateral = asset taken from targetUser and given to liquidator in exchange for liquidated loan
     *      borrowBalanceAfter = new stored borrow balance (should equal borrowBalanceAccumulated - amountRepaid)
     *      collateralBalanceBefore = collateral balance as most recently stored before the liquidation
     *      collateralBalanceAccumulated = collateralBalanceBefore + accumulated interest as of immediately prior to the liquidation
     *      amountSeized = amount of collateral seized by liquidator
     *      collateralBalanceAfter = new stored collateral balance (should equal collateralBalanceAccumulated - amountSeized)
     */
    event BorrowLiquidated(
        address targetAccount,
        address assetBorrow,
        uint256 borrowBalanceBefore,
        uint256 borrowBalanceAccumulated,
        uint256 amountRepaid,
        uint256 borrowBalanceAfter,
        address liquidator,
        address assetCollateral,
        uint256 collateralBalanceBefore,
        uint256 collateralBalanceAccumulated,
        uint256 amountSeized,
        uint256 collateralBalanceAfter
    );

    /**
     * @dev emitted when pendingAdmin is changed
     */
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /**
     * @dev emitted when pendingAdmin is accepted, which means admin is updated
     */
    event NewAdmin(address oldAdmin, address newAdmin);

    /**
     * @dev newOracle - address of new oracle
     */
    event NewOracle(address oldOracle, address newOracle);

    /**
     * @dev emitted when new market is supported by admin
     */
    event SupportedMarket(address asset, address interestRateModel);

    /**
     * @dev emitted when risk parameters are changed by admin
     */
    event NewRiskParameters(
        uint256 oldCollateralRatioMantissa,
        uint256 newCollateralRatioMantissa,
        uint256 oldLiquidationDiscountMantissa,
        uint256 newLiquidationDiscountMantissa
    );

    /**
     * @dev emitted when origination fee is changed by admin
     */
    event NewOriginationFee(
        uint256 oldOriginationFeeMantissa,
        uint256 newOriginationFeeMantissa
    );

    /**
     * @dev emitted when market has new interest rate model set
     */
    event SetMarketInterestRateModel(address asset, address interestRateModel);

    /**
     * @dev emitted when admin withdraws equity
     * Note that `equityAvailableBefore` indicates equity before `amount` was removed.
     */
    event EquityWithdrawn(
        address asset,
        uint256 equityAvailableBefore,
        uint256 amount,
        address owner
    );

    /**
     * @dev emitted when a supported market is suspended by admin
     */
    event SuspendedMarket(address asset);

    /**
     * @dev emitted when admin either pauses or resumes the contract; newState is the resulting state
     */
    event SetPaused(bool newState);

    /**
     * @dev Simple function to calculate min between two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a < b) {
            return a;
        } else {
            return b;
        }
    }

    /**
     * @dev Function to simply retrieve block number
     *      This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    /**
     * @dev Adds a given asset to the list of collateral markets. This operation is impossible to reverse.
     *      Note: this will not add the asset if it already exists.
     */
    function addCollateralMarket(address asset) internal {
        for (uint256 i = 0; i < collateralMarkets.length; i++) {
            if (collateralMarkets[i] == asset) {
                return;
            }
        }

        collateralMarkets.push(asset);
    }

    /**
     * @notice return the number of elements in `collateralMarkets`
     * @dev you can then externally call `collateralMarkets(uint)` to pull each market address
     * @return the length of `collateralMarkets`
     */
    function getCollateralMarketsLength() public view returns (uint256) {
        return collateralMarkets.length;
    }

    /**
     * @dev Calculates a new supply index based on the prevailing interest rates applied over time
     *      This is defined as `we multiply the most recent supply index by (1 + blocks times rate)`
     */
    function calculateInterestIndex(
        uint256 startingInterestIndex,
        uint256 interestRateMantissa,
        uint256 blockStart,
        uint256 blockEnd
    ) internal pure returns (Error, uint256) {
        // Get the block delta
        (Error err0, uint256 blockDelta) = sub(blockEnd, blockStart);
        if (err0 != Error.NO_ERROR) {
            return (err0, 0);
        }

        // Scale the interest rate times number of blocks
        // Note: Doing Exp construction inline to avoid `CompilerError: Stack too deep, try removing local variables.`
        (Error err1, Exp memory blocksTimesRate) = mulScalar(
            Exp({mantissa: interestRateMantissa}),
            blockDelta
        );
        if (err1 != Error.NO_ERROR) {
            return (err1, 0);
        }

        // Add one to that result (which is really Exp({mantissa: expScale}) which equals 1.0)
        (Error err2, Exp memory onePlusBlocksTimesRate) = addExp(
            blocksTimesRate,
            Exp({mantissa: mantissaOne})
        );
        if (err2 != Error.NO_ERROR) {
            return (err2, 0);
        }

        // Then scale that accumulated interest by the old interest index to get the new interest index
        (Error err3, Exp memory newInterestIndexExp) = mulScalar(
            onePlusBlocksTimesRate,
            startingInterestIndex
        );
        if (err3 != Error.NO_ERROR) {
            return (err3, 0);
        }

        // Finally, truncate the interest index. This works only if interest index starts large enough
        // that is can be accurately represented with a whole number.
        return (Error.NO_ERROR, truncate(newInterestIndexExp));
    }

    /**
     * @dev Calculates a new balance based on a previous balance and a pair of interest indices
     *      This is defined as: `The user's last balance checkpoint is multiplied by the currentSupplyIndex
     *      value and divided by the user's checkpoint index value`
     *
     *      TODO: Is there a way to handle this that is less likely to overflow?
     */
    function calculateBalance(
        uint256 startingBalance,
        uint256 interestIndexStart,
        uint256 interestIndexEnd
    ) internal pure returns (Error, uint256) {
        if (startingBalance == 0) {
            // We are accumulating interest on any previous balance; if there's no previous balance, then there is
            // nothing to accumulate.
            return (Error.NO_ERROR, 0);
        }
        (Error err0, uint256 balanceTimesIndex) = mul(
            startingBalance,
            interestIndexEnd
        );
        if (err0 != Error.NO_ERROR) {
            return (err0, 0);
        }

        return div(balanceTimesIndex, interestIndexStart);
    }

    /**
     * @dev Gets the price for the amount specified of the given asset.
     */
    function getPriceForAssetAmount(address asset, uint256 assetAmount)
        internal
        view
        returns (Error, Exp memory)
    {
        (Error err, Exp memory assetPrice) = fetchAssetPrice(asset);
        if (err != Error.NO_ERROR) {
            return (err, Exp({mantissa: 0}));
        }

        if (isZeroExp(assetPrice)) {
            return (Error.MISSING_ASSET_PRICE, Exp({mantissa: 0}));
        }

        return mulScalar(assetPrice, assetAmount); // assetAmountWei * oraclePrice = assetValueInEth
    }

    /**
     * @dev Gets the price for the amount specified of the given asset multiplied by the current
     *      collateral ratio (i.e., assetAmountWei * collateralRatio * oraclePrice = totalValueInEth).
     *      We will group this as `(oraclePrice * collateralRatio) * assetAmountWei`
     */
    function getPriceForAssetAmountMulCollatRatio(
        address asset,
        uint256 assetAmount
    ) internal view returns (Error, Exp memory) {
        Error err;
        Exp memory assetPrice;
        Exp memory scaledPrice;
        (err, assetPrice) = fetchAssetPrice(asset);
        if (err != Error.NO_ERROR) {
            return (err, Exp({mantissa: 0}));
        }

        if (isZeroExp(assetPrice)) {
            return (Error.MISSING_ASSET_PRICE, Exp({mantissa: 0}));
        }

        // Now, multiply the assetValue by the collateral ratio
        (err, scaledPrice) = mulExp(collateralRatio, assetPrice);
        if (err != Error.NO_ERROR) {
            return (err, Exp({mantissa: 0}));
        }

        // Get the price for the given asset amount
        return mulScalar(scaledPrice, assetAmount);
    }

    /**
     * @dev Calculates the origination fee added to a given borrowAmount
     *      This is simply `(1 + originationFee) * borrowAmount`
     *
     *      TODO: Track at what magnitude this fee rounds down to zero?
     */
    function calculateBorrowAmountWithFee(uint256 borrowAmount)
        internal
        view
        returns (Error, uint256)
    {
        // When origination fee is zero, the amount with fee is simply equal to the amount
        if (isZeroExp(originationFee)) {
            return (Error.NO_ERROR, borrowAmount);
        }

        (Error err0, Exp memory originationFeeFactor) = addExp(
            originationFee,
            Exp({mantissa: mantissaOne})
        );
        if (err0 != Error.NO_ERROR) {
            return (err0, 0);
        }

        (Error err1, Exp memory borrowAmountWithFee) = mulScalar(
            originationFeeFactor,
            borrowAmount
        );
        if (err1 != Error.NO_ERROR) {
            return (err1, 0);
        }

        return (Error.NO_ERROR, truncate(borrowAmountWithFee));
    }

    /**
     * @dev fetches the price of asset from the PriceOracle and converts it to Exp
     * @param asset asset whose price should be fetched
     */
    function fetchAssetPrice(address asset)
        internal
        view
        returns (Error, Exp memory)
    {
        if (oracle == address(0)) {
            return (Error.ZERO_ORACLE_ADDRESS, Exp({mantissa: 0}));
        }

        PriceOracleInterface oracleInterface = PriceOracleInterface(oracle);
        uint256 priceMantissa = oracleInterface.assetPrices(asset);

        return (Error.NO_ERROR, Exp({mantissa: priceMantissa}));
    }

    /**
     * @notice Reads scaled price of specified asset from the price oracle
     * @dev Reads scaled price of specified asset from the price oracle.
     *      The plural name is to match a previous storage mapping that this function replaced.
     * @param asset Asset whose price should be retrieved
     * @return 0 on an error or missing price, the price scaled by 1e18 otherwise
     */
    function assetPrices(address asset) public view returns (uint256) {
        (Error err, Exp memory result) = fetchAssetPrice(asset);
        if (err != Error.NO_ERROR) {
            return 0;
        }
        return result.mantissa;
    }

    /**
     * @dev Gets the amount of the specified asset given the specified Eth value
     *      ethValue / oraclePrice = assetAmountWei
     *      If there's no oraclePrice, this returns (Error.DIVISION_BY_ZERO, 0)
     */
    function getAssetAmountForValue(address asset, Exp ethValue)
        internal
        view
        returns (Error, uint256)
    {
        Error err;
        Exp memory assetPrice;
        Exp memory assetAmount;

        (err, assetPrice) = fetchAssetPrice(asset);
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, assetAmount) = divExp(ethValue, assetPrice);
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        return (Error.NO_ERROR, truncate(assetAmount));
    }

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     *
     * TODO: Should we add a second arg to verify, like a checksum of `newAdmin` address?
     */
    function _setPendingAdmin(address newPendingAdmin)
        public
        returns (uint256)
    {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK
                );
        }

        // save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;
        // Store pendingAdmin = newPendingAdmin
        pendingAdmin = newPendingAdmin;

        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _acceptAdmin() public returns (uint256) {
        // Check caller = pendingAdmin
        // msg.sender can't be zero
        if (msg.sender != pendingAdmin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldAdmin = admin;
        // Store admin = pendingAdmin
        admin = pendingAdmin;
        // Clear the pending value
        pendingAdmin = 0;

        emit NewAdmin(oldAdmin, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set new oracle, who can set asset prices
     * @dev Admin function to change oracle
     * @param newOracle New oracle address
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setOracle(address newOracle) public returns (uint256) {
        // Check caller = admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_ORACLE_OWNER_CHECK);
        }

        // Verify contract at newOracle address supports assetPrices call.
        // This will revert if it doesn't.
        PriceOracleInterface oracleInterface = PriceOracleInterface(newOracle);
        oracleInterface.assetPrices(address(0));

        address oldOracle = oracle;

        // Store oracle = newOracle
        oracle = newOracle;

        emit NewOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice set `paused` to the specified state
     * @dev Admin function to pause or resume the market
     * @param requestedState value to assign to `paused`
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPaused(bool requestedState) public returns (uint256) {
        // Check caller = admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSED_OWNER_CHECK);
        }

        paused = requestedState;
        emit SetPaused(requestedState);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice returns the liquidity for given account.
     *         a positive result indicates ability to borrow, whereas
     *         a negative result indicates a shortfall which may be liquidated
     * @dev returns account liquidity in terms of eth-wei value, scaled by 1e18
     *      note: this includes interest trued up on all balances
     * @param account the account to examine
     * @return signed integer in terms of eth-wei (negative indicates a shortfall)
     */
    function getAccountLiquidity(address account) public view returns (int256) {
        (
            Error err,
            Exp memory accountLiquidity,
            Exp memory accountShortfall
        ) = calculateAccountLiquidity(account);
        require(err == Error.NO_ERROR);

        if (isZeroExp(accountLiquidity)) {
            return -1 * int256(truncate(accountShortfall));
        } else {
            return int256(truncate(accountLiquidity));
        }
    }

    /**
     * @notice return supply balance with any accumulated interest for `asset` belonging to `account`
     * @dev returns supply balance with any accumulated interest for `asset` belonging to `account`
     * @param account the account to examine
     * @param asset the market asset whose supply balance belonging to `account` should be checked
     * @return uint supply balance on success, throws on failed assertion otherwise
     */
    function getSupplyBalance(address account, address asset)
        public
        view
        returns (uint256)
    {
        Error err;
        uint256 newSupplyIndex;
        uint256 userSupplyCurrent;

        Market storage market = markets[asset];
        Balance storage supplyBalance = supplyBalances[account][asset];

        // Calculate the newSupplyIndex, needed to calculate user's supplyCurrent
        (err, newSupplyIndex) = calculateInterestIndex(
            market.supplyIndex,
            market.supplyRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        require(err == Error.NO_ERROR);

        // Use newSupplyIndex and stored principal to calculate the accumulated balance
        (err, userSupplyCurrent) = calculateBalance(
            supplyBalance.principal,
            supplyBalance.interestIndex,
            newSupplyIndex
        );
        require(err == Error.NO_ERROR);

        return userSupplyCurrent;
    }

    /**
     * @notice return borrow balance with any accumulated interest for `asset` belonging to `account`
     * @dev returns borrow balance with any accumulated interest for `asset` belonging to `account`
     * @param account the account to examine
     * @param asset the market asset whose borrow balance belonging to `account` should be checked
     * @return uint borrow balance on success, throws on failed assertion otherwise
     */
    function getBorrowBalance(address account, address asset)
        public
        view
        returns (uint256)
    {
        Error err;
        uint256 newBorrowIndex;
        uint256 userBorrowCurrent;

        Market storage market = markets[asset];
        Balance storage borrowBalance = borrowBalances[account][asset];

        // Calculate the newBorrowIndex, needed to calculate user's borrowCurrent
        (err, newBorrowIndex) = calculateInterestIndex(
            market.borrowIndex,
            market.borrowRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        require(err == Error.NO_ERROR);

        // Use newBorrowIndex and stored principal to calculate the accumulated balance
        (err, userBorrowCurrent) = calculateBalance(
            borrowBalance.principal,
            borrowBalance.interestIndex,
            newBorrowIndex
        );
        require(err == Error.NO_ERROR);

        return userBorrowCurrent;
    }

    /**
     * @notice Supports a given market (asset) for use
     * @dev Admin function to add support for a market
     * @param asset Asset to support; MUST already have a non-zero price set
     * @param interestRateModel InterestRateModel to use for the asset
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _supportMarket(address asset, InterestRateModel interestRateModel)
        public
        returns (uint256)
    {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUPPORT_MARKET_OWNER_CHECK
                );
        }

        (Error err, Exp memory assetPrice) = fetchAssetPrice(asset);
        if (err != Error.NO_ERROR) {
            return fail(err, FailureInfo.SUPPORT_MARKET_FETCH_PRICE_FAILED);
        }

        if (isZeroExp(assetPrice)) {
            return
                fail(
                    Error.ASSET_NOT_PRICED,
                    FailureInfo.SUPPORT_MARKET_PRICE_CHECK
                );
        }

        // Set the interest rate model to `modelAddress`
        markets[asset].interestRateModel = interestRateModel;

        // Append asset to collateralAssets if not set
        addCollateralMarket(asset);

        // Set market isSupported to true
        markets[asset].isSupported = true;

        // Default supply and borrow index to 1e18
        if (markets[asset].supplyIndex == 0) {
            markets[asset].supplyIndex = initialInterestIndex;
        }

        if (markets[asset].borrowIndex == 0) {
            markets[asset].borrowIndex = initialInterestIndex;
        }

        emit SupportedMarket(asset, interestRateModel);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Suspends a given *supported* market (asset) from use.
     *         Assets in this state do count for collateral, but users may only withdraw, payBorrow,
     *         and liquidate the asset. The liquidate function no longer checks collateralization.
     * @dev Admin function to suspend a market
     * @param asset Asset to suspend
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _suspendMarket(address asset) public returns (uint256) {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUSPEND_MARKET_OWNER_CHECK
                );
        }

        // If the market is not configured at all, we don't want to add any configuration for it.
        // If we find !markets[asset].isSupported then either the market is not configured at all, or it
        // has already been marked as unsupported. We can just return without doing anything.
        // Caller is responsible for knowing the difference between not-configured and already unsupported.
        if (!markets[asset].isSupported) {
            return uint256(Error.NO_ERROR);
        }

        // If we get here, we know market is configured and is supported, so set isSupported to false
        markets[asset].isSupported = false;

        emit SuspendedMarket(asset);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the risk parameters: collateral ratio and liquidation discount
     * @dev Owner function to set the risk parameters
     * @param collateralRatioMantissa rational collateral ratio, scaled by 1e18. The de-scaled value must be >= 1.1
     * @param liquidationDiscountMantissa rational liquidation discount, scaled by 1e18. The de-scaled value must be <= 0.1 and must be less than (descaled collateral ratio minus 1)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setRiskParameters(
        uint256 collateralRatioMantissa,
        uint256 liquidationDiscountMantissa
    ) public returns (uint256) {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_RISK_PARAMETERS_OWNER_CHECK
                );
        }

        Exp memory newCollateralRatio = Exp({
            mantissa: collateralRatioMantissa
        });
        Exp memory newLiquidationDiscount = Exp({
            mantissa: liquidationDiscountMantissa
        });
        Exp memory minimumCollateralRatio = Exp({
            mantissa: minimumCollateralRatioMantissa
        });
        Exp memory maximumLiquidationDiscount = Exp({
            mantissa: maximumLiquidationDiscountMantissa
        });

        Error err;
        Exp memory newLiquidationDiscountPlusOne;

        // Make sure new collateral ratio value is not below minimum value
        if (lessThanExp(newCollateralRatio, minimumCollateralRatio)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_RATIO,
                    FailureInfo.SET_RISK_PARAMETERS_VALIDATION
                );
        }

        // Make sure new liquidation discount does not exceed the maximum value, but reverse operands so we can use the
        // existing `lessThanExp` function rather than adding a `greaterThan` function to Exponential.
        if (lessThanExp(maximumLiquidationDiscount, newLiquidationDiscount)) {
            return
                fail(
                    Error.INVALID_LIQUIDATION_DISCOUNT,
                    FailureInfo.SET_RISK_PARAMETERS_VALIDATION
                );
        }

        // C = L+1 is not allowed because it would cause division by zero error in `calculateDiscountedRepayToEvenAmount`
        // C < L+1 is not allowed because it would cause integer underflow error in `calculateDiscountedRepayToEvenAmount`
        (err, newLiquidationDiscountPlusOne) = addExp(
            newLiquidationDiscount,
            Exp({mantissa: mantissaOne})
        );
        assert(err == Error.NO_ERROR); // We already validated that newLiquidationDiscount does not approach overflow size

        if (
            lessThanOrEqualExp(
                newCollateralRatio,
                newLiquidationDiscountPlusOne
            )
        ) {
            return
                fail(
                    Error.INVALID_COMBINED_RISK_PARAMETERS,
                    FailureInfo.SET_RISK_PARAMETERS_VALIDATION
                );
        }

        // Save current values so we can emit them in log.
        Exp memory oldCollateralRatio = collateralRatio;
        Exp memory oldLiquidationDiscount = liquidationDiscount;

        // Store new values
        collateralRatio = newCollateralRatio;
        liquidationDiscount = newLiquidationDiscount;

        emit NewRiskParameters(
            oldCollateralRatio.mantissa,
            collateralRatioMantissa,
            oldLiquidationDiscount.mantissa,
            liquidationDiscountMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the origination fee (which is a multiplier on new borrows)
     * @dev Owner function to set the origination fee
     * @param originationFeeMantissa rational collateral ratio, scaled by 1e18. The de-scaled value must be >= 1.1
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setOriginationFee(uint256 originationFeeMantissa)
        public
        returns (uint256)
    {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_ORIGINATION_FEE_OWNER_CHECK
                );
        }

        // Save current value so we can emit it in log.
        Exp memory oldOriginationFee = originationFee;

        originationFee = Exp({mantissa: originationFeeMantissa});

        emit NewOriginationFee(
            oldOriginationFee.mantissa,
            originationFeeMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the interest rate model for a given market
     * @dev Admin function to set interest rate model
     * @param asset Asset to support
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setMarketInterestRateModel(
        address asset,
        InterestRateModel interestRateModel
    ) public returns (uint256) {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_MARKET_INTEREST_RATE_MODEL_OWNER_CHECK
                );
        }

        // Set the interest rate model to `modelAddress`
        markets[asset].interestRateModel = interestRateModel;

        emit SetMarketInterestRateModel(asset, interestRateModel);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice withdraws `amount` of `asset` from equity for asset, as long as `amount` <= equity. Equity= cash - (supply + borrows)
     * @dev withdraws `amount` of `asset` from equity  for asset, enforcing amount <= cash - (supply + borrows)
     * @param asset asset whose equity should be withdrawn
     * @param amount amount of equity to withdraw; must not exceed equity available
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _withdrawEquity(address asset, uint256 amount)
        public
        returns (uint256)
    {
        // Check caller = admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.EQUITY_WITHDRAWAL_MODEL_OWNER_CHECK
                );
        }

        // Check that amount is less than cash (from ERC-20 of self) plus borrows minus supply.
        uint256 cash = getCash(asset);
        (Error err0, uint256 equity) = addThenSub(
            cash,
            markets[asset].totalBorrows,
            markets[asset].totalSupply
        );
        if (err0 != Error.NO_ERROR) {
            return fail(err0, FailureInfo.EQUITY_WITHDRAWAL_CALCULATE_EQUITY);
        }

        if (amount > equity) {
            return
                fail(
                    Error.EQUITY_INSUFFICIENT_BALANCE,
                    FailureInfo.EQUITY_WITHDRAWAL_AMOUNT_VALIDATION
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset out of the protocol to the admin
        Error err2 = doTransferOut(asset, admin, amount);
        if (err2 != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return
                fail(err2, FailureInfo.EQUITY_WITHDRAWAL_TRANSFER_OUT_FAILED);
        }

        //event EquityWithdrawn(address asset, uint equityAvailableBefore, uint amount, address owner)
        emit EquityWithdrawn(asset, equity, amount, admin);

        return uint256(Error.NO_ERROR); // success
    }

    /**
     * The `SupplyLocalVars` struct is used internally in the `supply` function.
     *
     * To avoid solidity limits on the number of local variables we:
     * 1. Use a struct to hold local computation localResults
     * 2. Re-use a single variable for Error returns. (This is required with 1 because variable binding to tuple localResults
     *    requires either both to be declared inline or both to be previously declared.
     * 3. Re-use a boolean error-like return variable.
     */
    struct SupplyLocalVars {
        uint256 startingBalance;
        uint256 newSupplyIndex;
        uint256 userSupplyCurrent;
        uint256 userSupplyUpdated;
        uint256 newTotalSupply;
        uint256 currentCash;
        uint256 updatedCash;
        uint256 newSupplyRateMantissa;
        uint256 newBorrowIndex;
        uint256 newBorrowRateMantissa;
    }

    /**
     * @notice supply `amount` of `asset` (which must be supported) to `msg.sender` in the protocol
     * @dev add amount of supported asset to msg.sender's account
     * @param asset The market asset to supply
     * @param amount The amount to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function supply(address asset, uint256 amount)
        public
        nonReentrant
        returns (uint256)
    {
        if (paused) {
            return
                fail(Error.CONTRACT_PAUSED, FailureInfo.SUPPLY_CONTRACT_PAUSED);
        }

        require(
            isWhitelist(msg.sender, this.supply.selector, asset),
            "supply: Do not have permission!"
        );

        Market storage market = markets[asset];
        Balance storage balance = supplyBalances[msg.sender][asset];

        SupplyLocalVars memory localResults; // Holds all our uint calculation results
        Error err; // Re-used for every function call that includes an Error in its return value(s).
        uint256 rateCalculationResultCode; // Used for 2 interest rate calculation calls

        // Fail if market not supported
        if (!market.isSupported) {
            return
                fail(
                    Error.MARKET_NOT_SUPPORTED,
                    FailureInfo.SUPPLY_MARKET_NOT_SUPPORTED
                );
        }

        // Fail gracefully if asset is not approved or has insufficient balance
        err = checkTransferIn(asset, msg.sender, amount);
        if (err != Error.NO_ERROR) {
            return fail(err, FailureInfo.SUPPLY_TRANSFER_IN_NOT_POSSIBLE);
        }

        // We calculate the newSupplyIndex, user's supplyCurrent and supplyUpdated for the asset
        (err, localResults.newSupplyIndex) = calculateInterestIndex(
            market.supplyIndex,
            market.supplyRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.SUPPLY_NEW_SUPPLY_INDEX_CALCULATION_FAILED
                );
        }

        (err, localResults.userSupplyCurrent) = calculateBalance(
            balance.principal,
            balance.interestIndex,
            localResults.newSupplyIndex
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.SUPPLY_ACCUMULATED_BALANCE_CALCULATION_FAILED
                );
        }

        (err, localResults.userSupplyUpdated) = add(
            localResults.userSupplyCurrent,
            amount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.SUPPLY_NEW_TOTAL_BALANCE_CALCULATION_FAILED
                );
        }

        // We calculate the protocol's totalSupply by subtracting the user's prior checkpointed balance, adding user's updated supply
        (err, localResults.newTotalSupply) = addThenSub(
            market.totalSupply,
            localResults.userSupplyUpdated,
            balance.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.SUPPLY_NEW_TOTAL_SUPPLY_CALCULATION_FAILED
                );
        }

        // We need to calculate what the updated cash will be after we transfer in from user
        localResults.currentCash = getCash(asset);

        (err, localResults.updatedCash) = add(localResults.currentCash, amount);
        if (err != Error.NO_ERROR) {
            return
                fail(err, FailureInfo.SUPPLY_NEW_TOTAL_CASH_CALCULATION_FAILED);
        }

        // The utilization rate has changed! We calculate a new supply index and borrow index for the asset, and save it.
        (rateCalculationResultCode, localResults.newSupplyRateMantissa) = market
            .interestRateModel
            .getSupplyRate(
            asset,
            localResults.updatedCash,
            market.totalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.SUPPLY_NEW_SUPPLY_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        // We calculate the newBorrowIndex (we already had newSupplyIndex)
        (err, localResults.newBorrowIndex) = calculateInterestIndex(
            market.borrowIndex,
            market.borrowRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.SUPPLY_NEW_BORROW_INDEX_CALCULATION_FAILED
                );
        }

        (rateCalculationResultCode, localResults.newBorrowRateMantissa) = market
            .interestRateModel
            .getBorrowRate(
            asset,
            localResults.updatedCash,
            market.totalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.SUPPLY_NEW_BORROW_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset into the protocol (note: pre-conditions already checked above)
        err = doTransferIn(asset, msg.sender, amount);
        if (err != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return fail(err, FailureInfo.SUPPLY_TRANSFER_IN_FAILED);
        }

        // Save market updates
        market.blockNumber = getBlockNumber();
        market.totalSupply = localResults.newTotalSupply;
        market.supplyRateMantissa = localResults.newSupplyRateMantissa;
        market.supplyIndex = localResults.newSupplyIndex;
        market.borrowRateMantissa = localResults.newBorrowRateMantissa;
        market.borrowIndex = localResults.newBorrowIndex;

        // Save user updates
        localResults.startingBalance = balance.principal; // save for use in `SupplyReceived` event
        balance.principal = localResults.userSupplyUpdated;
        balance.interestIndex = localResults.newSupplyIndex;

        emit SupplyReceived(
            msg.sender,
            asset,
            amount,
            localResults.startingBalance,
            localResults.userSupplyUpdated
        );

        return uint256(Error.NO_ERROR); // success
    }

    struct WithdrawLocalVars {
        uint256 withdrawAmount;
        uint256 startingBalance;
        uint256 newSupplyIndex;
        uint256 userSupplyCurrent;
        uint256 userSupplyUpdated;
        uint256 newTotalSupply;
        uint256 currentCash;
        uint256 updatedCash;
        uint256 newSupplyRateMantissa;
        uint256 newBorrowIndex;
        uint256 newBorrowRateMantissa;
        Exp accountLiquidity;
        Exp accountShortfall;
        Exp ethValueOfWithdrawal;
        uint256 withdrawCapacity;
    }

    /**
     * @notice withdraw `amount` of `asset` from sender's account to sender's address
     * @dev withdraw `amount` of `asset` from msg.sender's account to msg.sender
     * @param asset The market asset to withdraw
     * @param requestedAmount The amount to withdraw (or -1 for max)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function withdraw(address asset, uint256 requestedAmount)
        public
        nonReentrant
        returns (uint256)
    {
        if (paused) {
            return
                fail(
                    Error.CONTRACT_PAUSED,
                    FailureInfo.WITHDRAW_CONTRACT_PAUSED
                );
        }

        Market storage market = markets[asset];
        Balance storage supplyBalance = supplyBalances[msg.sender][asset];

        WithdrawLocalVars memory localResults; // Holds all our calculation results
        Error err; // Re-used for every function call that includes an Error in its return value(s).
        uint256 rateCalculationResultCode; // Used for 2 interest rate calculation calls

        // We calculate the user's accountLiquidity and accountShortfall.
        (
            err,
            localResults.accountLiquidity,
            localResults.accountShortfall
        ) = calculateAccountLiquidity(msg.sender);
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.WITHDRAW_ACCOUNT_LIQUIDITY_CALCULATION_FAILED
                );
        }

        // We calculate the newSupplyIndex, user's supplyCurrent and supplyUpdated for the asset
        (err, localResults.newSupplyIndex) = calculateInterestIndex(
            market.supplyIndex,
            market.supplyRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.WITHDRAW_NEW_SUPPLY_INDEX_CALCULATION_FAILED
                );
        }

        (err, localResults.userSupplyCurrent) = calculateBalance(
            supplyBalance.principal,
            supplyBalance.interestIndex,
            localResults.newSupplyIndex
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.WITHDRAW_ACCUMULATED_BALANCE_CALCULATION_FAILED
                );
        }

        // If the user specifies -1 amount to withdraw ("max"),  withdrawAmount => the lesser of withdrawCapacity and supplyCurrent
        if (requestedAmount == uint256(-1)) {
            (err, localResults.withdrawCapacity) = getAssetAmountForValue(
                asset,
                localResults.accountLiquidity
            );
            if (err != Error.NO_ERROR) {
                return
                    fail(err, FailureInfo.WITHDRAW_CAPACITY_CALCULATION_FAILED);
            }
            localResults.withdrawAmount = min(
                localResults.withdrawCapacity,
                localResults.userSupplyCurrent
            );
        } else {
            localResults.withdrawAmount = requestedAmount;
        }

        // From here on we should NOT use requestedAmount.

        // Fail gracefully if protocol has insufficient cash
        // If protocol has insufficient cash, the sub operation will underflow.
        localResults.currentCash = getCash(asset);
        (err, localResults.updatedCash) = sub(
            localResults.currentCash,
            localResults.withdrawAmount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    Error.TOKEN_INSUFFICIENT_CASH,
                    FailureInfo.WITHDRAW_TRANSFER_OUT_NOT_POSSIBLE
                );
        }

        // We check that the amount is less than or equal to supplyCurrent
        // If amount is greater than supplyCurrent, this will fail with Error.INTEGER_UNDERFLOW
        (err, localResults.userSupplyUpdated) = sub(
            localResults.userSupplyCurrent,
            localResults.withdrawAmount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    Error.INSUFFICIENT_BALANCE,
                    FailureInfo.WITHDRAW_NEW_TOTAL_BALANCE_CALCULATION_FAILED
                );
        }

        // Fail if customer already has a shortfall
        if (!isZeroExp(localResults.accountShortfall)) {
            return
                fail(
                    Error.INSUFFICIENT_LIQUIDITY,
                    FailureInfo.WITHDRAW_ACCOUNT_SHORTFALL_PRESENT
                );
        }

        // We want to know the user's withdrawCapacity, denominated in the asset
        // Customer's withdrawCapacity of asset is (accountLiquidity in Eth)/ (price of asset in Eth)
        // Equivalently, we calculate the eth value of the withdrawal amount and compare it directly to the accountLiquidity in Eth
        (err, localResults.ethValueOfWithdrawal) = getPriceForAssetAmount(
            asset,
            localResults.withdrawAmount
        ); // amount * oraclePrice = ethValueOfWithdrawal
        if (err != Error.NO_ERROR) {
            return
                fail(err, FailureInfo.WITHDRAW_AMOUNT_VALUE_CALCULATION_FAILED);
        }

        // We check that the amount is less than withdrawCapacity (here), and less than or equal to supplyCurrent (below)
        if (
            lessThanExp(
                localResults.accountLiquidity,
                localResults.ethValueOfWithdrawal
            )
        ) {
            return
                fail(
                    Error.INSUFFICIENT_LIQUIDITY,
                    FailureInfo.WITHDRAW_AMOUNT_LIQUIDITY_SHORTFALL
                );
        }

        // We calculate the protocol's totalSupply by subtracting the user's prior checkpointed balance, adding user's updated supply.
        // Note that, even though the customer is withdrawing, if they've accumulated a lot of interest since their last
        // action, the updated balance *could* be higher than the prior checkpointed balance.
        (err, localResults.newTotalSupply) = addThenSub(
            market.totalSupply,
            localResults.userSupplyUpdated,
            supplyBalance.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.WITHDRAW_NEW_TOTAL_SUPPLY_CALCULATION_FAILED
                );
        }

        // The utilization rate has changed! We calculate a new supply index and borrow index for the asset, and save it.
        (rateCalculationResultCode, localResults.newSupplyRateMantissa) = market
            .interestRateModel
            .getSupplyRate(
            asset,
            localResults.updatedCash,
            market.totalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.WITHDRAW_NEW_SUPPLY_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        // We calculate the newBorrowIndex
        (err, localResults.newBorrowIndex) = calculateInterestIndex(
            market.borrowIndex,
            market.borrowRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.WITHDRAW_NEW_BORROW_INDEX_CALCULATION_FAILED
                );
        }

        (rateCalculationResultCode, localResults.newBorrowRateMantissa) = market
            .interestRateModel
            .getBorrowRate(
            asset,
            localResults.updatedCash,
            market.totalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.WITHDRAW_NEW_BORROW_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset into the protocol (note: pre-conditions already checked above)
        err = doTransferOut(asset, msg.sender, localResults.withdrawAmount);
        if (err != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return fail(err, FailureInfo.WITHDRAW_TRANSFER_OUT_FAILED);
        }

        // Save market updates
        market.blockNumber = getBlockNumber();
        market.totalSupply = localResults.newTotalSupply;
        market.supplyRateMantissa = localResults.newSupplyRateMantissa;
        market.supplyIndex = localResults.newSupplyIndex;
        market.borrowRateMantissa = localResults.newBorrowRateMantissa;
        market.borrowIndex = localResults.newBorrowIndex;

        // Save user updates
        localResults.startingBalance = supplyBalance.principal; // save for use in `SupplyWithdrawn` event
        supplyBalance.principal = localResults.userSupplyUpdated;
        supplyBalance.interestIndex = localResults.newSupplyIndex;

        emit SupplyWithdrawn(
            msg.sender,
            asset,
            localResults.withdrawAmount,
            localResults.startingBalance,
            localResults.userSupplyUpdated
        );

        return uint256(Error.NO_ERROR); // success
    }

    struct AccountValueLocalVars {
        address assetAddress;
        uint256 collateralMarketsLength;
        uint256 newSupplyIndex;
        uint256 userSupplyCurrent;
        Exp supplyTotalValue;
        Exp sumSupplies;
        uint256 newBorrowIndex;
        uint256 userBorrowCurrent;
        Exp borrowTotalValue;
        Exp sumBorrows;
    }

    /**
     * @dev Gets the user's account liquidity and account shortfall balances. This includes
     *      any accumulated interest thus far but does NOT actually update anything in
     *      storage, it simply calculates the account liquidity and shortfall with liquidity being
     *      returned as the first Exp, ie (Error, accountLiquidity, accountShortfall).
     */
    function calculateAccountLiquidity(address userAddress)
        internal
        view
        returns (
            Error,
            Exp memory,
            Exp memory
        )
    {
        Error err;
        uint256 sumSupplyValuesMantissa;
        uint256 sumBorrowValuesMantissa;
        (
            err,
            sumSupplyValuesMantissa,
            sumBorrowValuesMantissa
        ) = calculateAccountValuesInternal(userAddress);
        if (err != Error.NO_ERROR) {
            return (err, Exp({mantissa: 0}), Exp({mantissa: 0}));
        }

        Exp memory result;

        Exp memory sumSupplyValuesFinal = Exp({
            mantissa: sumSupplyValuesMantissa
        });
        Exp memory sumBorrowValuesFinal; // need to apply collateral ratio

        (err, sumBorrowValuesFinal) = mulExp(
            collateralRatio,
            Exp({mantissa: sumBorrowValuesMantissa})
        );
        if (err != Error.NO_ERROR) {
            return (err, Exp({mantissa: 0}), Exp({mantissa: 0}));
        }

        // if sumSupplies < sumBorrows, then the user is under collateralized and has account shortfall.
        // else the user meets the collateral ratio and has account liquidity.
        if (lessThanExp(sumSupplyValuesFinal, sumBorrowValuesFinal)) {
            // accountShortfall = borrows - supplies
            (err, result) = subExp(sumBorrowValuesFinal, sumSupplyValuesFinal);
            assert(err == Error.NO_ERROR); // Note: we have checked that sumBorrows is greater than sumSupplies directly above, therefore `subExp` cannot fail.

            return (Error.NO_ERROR, Exp({mantissa: 0}), result);
        } else {
            // accountLiquidity = supplies - borrows
            (err, result) = subExp(sumSupplyValuesFinal, sumBorrowValuesFinal);
            assert(err == Error.NO_ERROR); // Note: we have checked that sumSupplies is greater than sumBorrows directly above, therefore `subExp` cannot fail.

            return (Error.NO_ERROR, result, Exp({mantissa: 0}));
        }
    }

    /**
     * @notice Gets the ETH values of the user's accumulated supply and borrow balances, scaled by 10e18.
     *         This includes any accumulated interest thus far but does NOT actually update anything in
     *         storage
     * @dev Gets ETH values of accumulated supply and borrow balances
     * @param userAddress account for which to sum values
     * @return (error code, sum ETH value of supplies scaled by 10e18, sum ETH value of borrows scaled by 10e18)
     * TODO: Possibly should add a Min(500, collateralMarkets.length) for extra safety
     * TODO: To help save gas we could think about using the current Market.interestIndex
     *       accumulate interest rather than calculating it
     */
    function calculateAccountValuesInternal(address userAddress)
        internal
        view
        returns (
            Error,
            uint256,
            uint256
        )
    {
        /** By definition, all collateralMarkets are those that contribute to the user's
         * liquidity and shortfall so we need only loop through those markets.
         * To handle avoiding intermediate negative results, we will sum all the user's
         * supply balances and borrow balances (with collateral ratio) separately and then
         * subtract the sums at the end.
         */

        AccountValueLocalVars memory localResults; // Re-used for all intermediate results
        localResults.sumSupplies = Exp({mantissa: 0});
        localResults.sumBorrows = Exp({mantissa: 0});
        Error err; // Re-used for all intermediate errors
        localResults.collateralMarketsLength = collateralMarkets.length;

        for (uint256 i = 0; i < localResults.collateralMarketsLength; i++) {
            localResults.assetAddress = collateralMarkets[i];
            Market storage currentMarket = markets[localResults.assetAddress];


                Balance storage supplyBalance
             = supplyBalances[userAddress][localResults.assetAddress];


                Balance storage borrowBalance
             = borrowBalances[userAddress][localResults.assetAddress];

            if (supplyBalance.principal > 0) {
                // We calculate the newSupplyIndex and user’s supplyCurrent (includes interest)
                (err, localResults.newSupplyIndex) = calculateInterestIndex(
                    currentMarket.supplyIndex,
                    currentMarket.supplyRateMantissa,
                    currentMarket.blockNumber,
                    getBlockNumber()
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                (err, localResults.userSupplyCurrent) = calculateBalance(
                    supplyBalance.principal,
                    supplyBalance.interestIndex,
                    localResults.newSupplyIndex
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                // We have the user's supply balance with interest so let's multiply by the asset price to get the total value
                (err, localResults.supplyTotalValue) = getPriceForAssetAmount(
                    localResults.assetAddress,
                    localResults.userSupplyCurrent
                ); // supplyCurrent * oraclePrice = supplyValueInEth
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                // Add this to our running sum of supplies
                (err, localResults.sumSupplies) = addExp(
                    localResults.supplyTotalValue,
                    localResults.sumSupplies
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }
            }

            if (borrowBalance.principal > 0) {
                // We perform a similar actions to get the user's borrow balance
                (err, localResults.newBorrowIndex) = calculateInterestIndex(
                    currentMarket.borrowIndex,
                    currentMarket.borrowRateMantissa,
                    currentMarket.blockNumber,
                    getBlockNumber()
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                (err, localResults.userBorrowCurrent) = calculateBalance(
                    borrowBalance.principal,
                    borrowBalance.interestIndex,
                    localResults.newBorrowIndex
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                // In the case of borrow, we multiply the borrow value by the collateral ratio
                (err, localResults.borrowTotalValue) = getPriceForAssetAmount(
                    localResults.assetAddress,
                    localResults.userBorrowCurrent
                ); // ( borrowCurrent* oraclePrice * collateralRatio) = borrowTotalValueInEth
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }

                // Add this to our running sum of borrows
                (err, localResults.sumBorrows) = addExp(
                    localResults.borrowTotalValue,
                    localResults.sumBorrows
                );
                if (err != Error.NO_ERROR) {
                    return (err, 0, 0);
                }
            }
        }

        return (
            Error.NO_ERROR,
            localResults.sumSupplies.mantissa,
            localResults.sumBorrows.mantissa
        );
    }

    /**
     * @notice Gets the ETH values of the user's accumulated supply and borrow balances, scaled by 10e18.
     *         This includes any accumulated interest thus far but does NOT actually update anything in
     *         storage
     * @dev Gets ETH values of accumulated supply and borrow balances
     * @param userAddress account for which to sum values
     * @return (uint 0=success; otherwise a failure (see ErrorReporter.sol for details),
     *          sum ETH value of supplies scaled by 10e18,
     *          sum ETH value of borrows scaled by 10e18)
     */
    function calculateAccountValues(address userAddress)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 supplyValue,
            uint256 borrowValue
        ) = calculateAccountValuesInternal(userAddress);
        if (err != Error.NO_ERROR) {
            return (uint256(err), 0, 0);
        }

        return (0, supplyValue, borrowValue);
    }

    struct PayBorrowLocalVars {
        uint256 newBorrowIndex;
        uint256 userBorrowCurrent;
        uint256 repayAmount;
        uint256 userBorrowUpdated;
        uint256 newTotalBorrows;
        uint256 currentCash;
        uint256 updatedCash;
        uint256 newSupplyIndex;
        uint256 newSupplyRateMantissa;
        uint256 newBorrowRateMantissa;
        uint256 startingBalance;
    }

    /**
     * @notice Users repay borrowed assets from their own address to the protocol.
     * @param asset The market asset to repay
     * @param amount The amount to repay (or -1 for max)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(address asset, uint256 amount)
        public
        nonReentrant
        returns (uint256)
    {
        if (paused) {
            return
                fail(
                    Error.CONTRACT_PAUSED,
                    FailureInfo.REPAY_BORROW_CONTRACT_PAUSED
                );
        }
        PayBorrowLocalVars memory localResults;
        Market storage market = markets[asset];
        Balance storage borrowBalance = borrowBalances[msg.sender][asset];
        Error err;
        uint256 rateCalculationResultCode;

        // We calculate the newBorrowIndex, user's borrowCurrent and borrowUpdated for the asset
        (err, localResults.newBorrowIndex) = calculateInterestIndex(
            market.borrowIndex,
            market.borrowRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.REPAY_BORROW_NEW_BORROW_INDEX_CALCULATION_FAILED
                );
        }

        (err, localResults.userBorrowCurrent) = calculateBalance(
            borrowBalance.principal,
            borrowBalance.interestIndex,
            localResults.newBorrowIndex
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .REPAY_BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED
                );
        }

        // If the user specifies -1 amount to repay (“max”), repayAmount =>
        // the lesser of the senders ERC-20 balance and borrowCurrent
        if (amount == uint256(-1)) {
            localResults.repayAmount = min(
                getBalanceOf(asset, msg.sender),
                localResults.userBorrowCurrent
            );
        } else {
            localResults.repayAmount = amount;
        }

        // Subtract the `repayAmount` from the `userBorrowCurrent` to get `userBorrowUpdated`
        // Note: this checks that repayAmount is less than borrowCurrent
        (err, localResults.userBorrowUpdated) = sub(
            localResults.userBorrowCurrent,
            localResults.repayAmount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .REPAY_BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED
                );
        }

        // Fail gracefully if asset is not approved or has insufficient balance
        // Note: this checks that repayAmount is less than or equal to their ERC-20 balance
        err = checkTransferIn(asset, msg.sender, localResults.repayAmount);
        if (err != Error.NO_ERROR) {
            return fail(err, FailureInfo.REPAY_BORROW_TRANSFER_IN_NOT_POSSIBLE);
        }

        // We calculate the protocol's totalBorrow by subtracting the user's prior checkpointed balance, adding user's updated borrow
        // Note that, even though the customer is paying some of their borrow, if they've accumulated a lot of interest since their last
        // action, the updated balance *could* be higher than the prior checkpointed balance.
        (err, localResults.newTotalBorrows) = addThenSub(
            market.totalBorrows,
            localResults.userBorrowUpdated,
            borrowBalance.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.REPAY_BORROW_NEW_TOTAL_BORROW_CALCULATION_FAILED
                );
        }

        // We need to calculate what the updated cash will be after we transfer in from user
        localResults.currentCash = getCash(asset);

        (err, localResults.updatedCash) = add(
            localResults.currentCash,
            localResults.repayAmount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.REPAY_BORROW_NEW_TOTAL_CASH_CALCULATION_FAILED
                );
        }

        // The utilization rate has changed! We calculate a new supply index and borrow index for the asset, and save it.

        // We calculate the newSupplyIndex, but we have newBorrowIndex already
        (err, localResults.newSupplyIndex) = calculateInterestIndex(
            market.supplyIndex,
            market.supplyRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.REPAY_BORROW_NEW_SUPPLY_INDEX_CALCULATION_FAILED
                );
        }

        (rateCalculationResultCode, localResults.newSupplyRateMantissa) = market
            .interestRateModel
            .getSupplyRate(
            asset,
            localResults.updatedCash,
            localResults.newTotalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.REPAY_BORROW_NEW_SUPPLY_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        (rateCalculationResultCode, localResults.newBorrowRateMantissa) = market
            .interestRateModel
            .getBorrowRate(
            asset,
            localResults.updatedCash,
            localResults.newTotalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.REPAY_BORROW_NEW_BORROW_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset into the protocol (note: pre-conditions already checked above)
        err = doTransferIn(asset, msg.sender, localResults.repayAmount);
        if (err != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return fail(err, FailureInfo.REPAY_BORROW_TRANSFER_IN_FAILED);
        }

        // Save market updates
        market.blockNumber = getBlockNumber();
        market.totalBorrows = localResults.newTotalBorrows;
        market.supplyRateMantissa = localResults.newSupplyRateMantissa;
        market.supplyIndex = localResults.newSupplyIndex;
        market.borrowRateMantissa = localResults.newBorrowRateMantissa;
        market.borrowIndex = localResults.newBorrowIndex;

        // Save user updates
        localResults.startingBalance = borrowBalance.principal; // save for use in `BorrowRepaid` event
        borrowBalance.principal = localResults.userBorrowUpdated;
        borrowBalance.interestIndex = localResults.newBorrowIndex;

        emit BorrowRepaid(
            msg.sender,
            asset,
            localResults.repayAmount,
            localResults.startingBalance,
            localResults.userBorrowUpdated
        );

        return uint256(Error.NO_ERROR); // success
    }

    struct BorrowLocalVars {
        uint256 newBorrowIndex;
        uint256 userBorrowCurrent;
        uint256 borrowAmountWithFee;
        uint256 userBorrowUpdated;
        uint256 newTotalBorrows;
        uint256 currentCash;
        uint256 updatedCash;
        uint256 newSupplyIndex;
        uint256 newSupplyRateMantissa;
        uint256 newBorrowRateMantissa;
        uint256 startingBalance;
        Exp accountLiquidity;
        Exp accountShortfall;
        Exp ethValueOfBorrowAmountWithFee;
    }

    struct LiquidateLocalVars {
        // we need these addresses in the struct for use with `emitLiquidationEvent` to avoid `CompilerError: Stack too deep, try removing local variables.`
        address targetAccount;
        address assetBorrow;
        address liquidator;
        address assetCollateral;
        // borrow index and supply index are global to the asset, not specific to the user
        uint256 newBorrowIndex_UnderwaterAsset;
        uint256 newSupplyIndex_UnderwaterAsset;
        uint256 newBorrowIndex_CollateralAsset;
        uint256 newSupplyIndex_CollateralAsset;
        // the target borrow's full balance with accumulated interest
        uint256 currentBorrowBalance_TargetUnderwaterAsset;
        // currentBorrowBalance_TargetUnderwaterAsset minus whatever gets repaid as part of the liquidation
        uint256 updatedBorrowBalance_TargetUnderwaterAsset;
        uint256 newTotalBorrows_ProtocolUnderwaterAsset;
        uint256 startingBorrowBalance_TargetUnderwaterAsset;
        uint256 startingSupplyBalance_TargetCollateralAsset;
        uint256 startingSupplyBalance_LiquidatorCollateralAsset;
        uint256 currentSupplyBalance_TargetCollateralAsset;
        uint256 updatedSupplyBalance_TargetCollateralAsset;
        // If liquidator already has a balance of collateralAsset, we will accumulate
        // interest on it before transferring seized collateral from the borrower.
        uint256 currentSupplyBalance_LiquidatorCollateralAsset;
        // This will be the liquidator's accumulated balance of collateral asset before the liquidation (if any)
        // plus the amount seized from the borrower.
        uint256 updatedSupplyBalance_LiquidatorCollateralAsset;
        uint256 newTotalSupply_ProtocolCollateralAsset;
        uint256 currentCash_ProtocolUnderwaterAsset;
        uint256 updatedCash_ProtocolUnderwaterAsset;
        // cash does not change for collateral asset

        uint256 newSupplyRateMantissa_ProtocolUnderwaterAsset;
        uint256 newBorrowRateMantissa_ProtocolUnderwaterAsset;
        // Why no variables for the interest rates for the collateral asset?
        // We don't need to calculate new rates for the collateral asset since neither cash nor borrows change

        uint256 discountedRepayToEvenAmount;
        //[supplyCurrent / (1 + liquidationDiscount)] * (Oracle price for the collateral / Oracle price for the borrow) (discountedBorrowDenominatedCollateral)
        uint256 discountedBorrowDenominatedCollateral;
        uint256 maxCloseableBorrowAmount_TargetUnderwaterAsset;
        uint256 closeBorrowAmount_TargetUnderwaterAsset;
        uint256 seizeSupplyAmount_TargetCollateralAsset;
        Exp collateralPrice;
        Exp underwaterAssetPrice;
    }

    /**
     * @notice users repay all or some of an underwater borrow and receive collateral
     * @param targetAccount The account whose borrow should be liquidated
     * @param assetBorrow The market asset to repay
     * @param assetCollateral The borrower's market asset to receive in exchange
     * @param requestedAmountClose The amount to repay (or -1 for max)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address targetAccount,
        address assetBorrow,
        address assetCollateral,
        uint256 requestedAmountClose
    ) public nonReentrant returns (uint256) {
        if (paused) {
            return
                fail(
                    Error.CONTRACT_PAUSED,
                    FailureInfo.LIQUIDATE_CONTRACT_PAUSED
                );
        }
        LiquidateLocalVars memory localResults;
        // Copy these addresses into the struct for use with `emitLiquidationEvent`
        // We'll use localResults.liquidator inside this function for clarity vs using msg.sender.
        localResults.targetAccount = targetAccount;
        localResults.assetBorrow = assetBorrow;
        localResults.liquidator = msg.sender;
        localResults.assetCollateral = assetCollateral;

        Market storage borrowMarket = markets[assetBorrow];
        Market storage collateralMarket = markets[assetCollateral];


            Balance storage borrowBalance_TargeUnderwaterAsset
         = borrowBalances[targetAccount][assetBorrow];


            Balance storage supplyBalance_TargetCollateralAsset
         = supplyBalances[targetAccount][assetCollateral];

        // Liquidator might already hold some of the collateral asset


            Balance storage supplyBalance_LiquidatorCollateralAsset
         = supplyBalances[localResults.liquidator][assetCollateral];

        uint256 rateCalculationResultCode; // Used for multiple interest rate calculation calls
        Error err; // re-used for all intermediate errors

        (err, localResults.collateralPrice) = fetchAssetPrice(assetCollateral);
        if (err != Error.NO_ERROR) {
            return fail(err, FailureInfo.LIQUIDATE_FETCH_ASSET_PRICE_FAILED);
        }

        (err, localResults.underwaterAssetPrice) = fetchAssetPrice(assetBorrow);
        // If the price oracle is not set, then we would have failed on the first call to fetchAssetPrice
        assert(err == Error.NO_ERROR);

        // We calculate newBorrowIndex_UnderwaterAsset and then use it to help calculate currentBorrowBalance_TargetUnderwaterAsset
        (
            err,
            localResults.newBorrowIndex_UnderwaterAsset
        ) = calculateInterestIndex(
            borrowMarket.borrowIndex,
            borrowMarket.borrowRateMantissa,
            borrowMarket.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_BORROW_INDEX_CALCULATION_FAILED_BORROWED_ASSET
                );
        }

        (
            err,
            localResults.currentBorrowBalance_TargetUnderwaterAsset
        ) = calculateBalance(
            borrowBalance_TargeUnderwaterAsset.principal,
            borrowBalance_TargeUnderwaterAsset.interestIndex,
            localResults.newBorrowIndex_UnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_ACCUMULATED_BORROW_BALANCE_CALCULATION_FAILED
                );
        }

        // We calculate newSupplyIndex_CollateralAsset and then use it to help calculate currentSupplyBalance_TargetCollateralAsset
        (
            err,
            localResults.newSupplyIndex_CollateralAsset
        ) = calculateInterestIndex(
            collateralMarket.supplyIndex,
            collateralMarket.supplyRateMantissa,
            collateralMarket.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_SUPPLY_INDEX_CALCULATION_FAILED_COLLATERAL_ASSET
                );
        }

        (
            err,
            localResults.currentSupplyBalance_TargetCollateralAsset
        ) = calculateBalance(
            supplyBalance_TargetCollateralAsset.principal,
            supplyBalance_TargetCollateralAsset.interestIndex,
            localResults.newSupplyIndex_CollateralAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_ACCUMULATED_SUPPLY_BALANCE_CALCULATION_FAILED_BORROWER_COLLATERAL_ASSET
                );
        }

        // Liquidator may or may not already have some collateral asset.
        // If they do, we need to accumulate interest on it before adding the seized collateral to it.
        // We re-use newSupplyIndex_CollateralAsset calculated above to help calculate currentSupplyBalance_LiquidatorCollateralAsset
        (
            err,
            localResults.currentSupplyBalance_LiquidatorCollateralAsset
        ) = calculateBalance(
            supplyBalance_LiquidatorCollateralAsset.principal,
            supplyBalance_LiquidatorCollateralAsset.interestIndex,
            localResults.newSupplyIndex_CollateralAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_ACCUMULATED_SUPPLY_BALANCE_CALCULATION_FAILED_LIQUIDATOR_COLLATERAL_ASSET
                );
        }

        // We update the protocol's totalSupply for assetCollateral in 2 steps, first by adding target user's accumulated
        // interest and then by adding the liquidator's accumulated interest.

        // Step 1 of 2: We add the target user's supplyCurrent and subtract their checkpointedBalance
        // (which has the desired effect of adding accrued interest from the target user)
        (err, localResults.newTotalSupply_ProtocolCollateralAsset) = addThenSub(
            collateralMarket.totalSupply,
            localResults.currentSupplyBalance_TargetCollateralAsset,
            supplyBalance_TargetCollateralAsset.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_TOTAL_SUPPLY_BALANCE_CALCULATION_FAILED_BORROWER_COLLATERAL_ASSET
                );
        }

        // Step 2 of 2: We add the liquidator's supplyCurrent of collateral asset and subtract their checkpointedBalance
        // (which has the desired effect of adding accrued interest from the calling user)
        (err, localResults.newTotalSupply_ProtocolCollateralAsset) = addThenSub(
            localResults.newTotalSupply_ProtocolCollateralAsset,
            localResults.currentSupplyBalance_LiquidatorCollateralAsset,
            supplyBalance_LiquidatorCollateralAsset.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_TOTAL_SUPPLY_BALANCE_CALCULATION_FAILED_LIQUIDATOR_COLLATERAL_ASSET
                );
        }

        // We calculate maxCloseableBorrowAmount_TargetUnderwaterAsset, the amount of borrow that can be closed from the target user
        // This is equal to the lesser of
        // 1. borrowCurrent; (already calculated)
        // 2. ONLY IF MARKET SUPPORTED: discountedRepayToEvenAmount:
        // discountedRepayToEvenAmount=
        //      shortfall / [Oracle price for the borrow * (collateralRatio - liquidationDiscount - 1)]
        // 3. discountedBorrowDenominatedCollateral
        //      [supplyCurrent / (1 + liquidationDiscount)] * (Oracle price for the collateral / Oracle price for the borrow)

        // Here we calculate item 3. discountedBorrowDenominatedCollateral =
        // [supplyCurrent / (1 + liquidationDiscount)] * (Oracle price for the collateral / Oracle price for the borrow)
        (
            err,
            localResults.discountedBorrowDenominatedCollateral
        ) = calculateDiscountedBorrowDenominatedCollateral(
            localResults.underwaterAssetPrice,
            localResults.collateralPrice,
            localResults.currentSupplyBalance_TargetCollateralAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_BORROW_DENOMINATED_COLLATERAL_CALCULATION_FAILED
                );
        }

        if (borrowMarket.isSupported) {
            // Market is supported, so we calculate item 2 from above.
            (
                err,
                localResults.discountedRepayToEvenAmount
            ) = calculateDiscountedRepayToEvenAmount(
                targetAccount,
                localResults.underwaterAssetPrice
            );
            if (err != Error.NO_ERROR) {
                return
                    fail(
                        err,
                        FailureInfo
                            .LIQUIDATE_DISCOUNTED_REPAY_TO_EVEN_AMOUNT_CALCULATION_FAILED
                    );
            }

            // We need to do a two-step min to select from all 3 values
            // min1&3 = min(item 1, item 3)
            localResults.maxCloseableBorrowAmount_TargetUnderwaterAsset = min(
                localResults.currentBorrowBalance_TargetUnderwaterAsset,
                localResults.discountedBorrowDenominatedCollateral
            );

            // min1&3&2 = min(min1&3, 2)
            localResults.maxCloseableBorrowAmount_TargetUnderwaterAsset = min(
                localResults.maxCloseableBorrowAmount_TargetUnderwaterAsset,
                localResults.discountedRepayToEvenAmount
            );
        } else {
            // Market is not supported, so we don't need to calculate item 2.
            localResults.maxCloseableBorrowAmount_TargetUnderwaterAsset = min(
                localResults.currentBorrowBalance_TargetUnderwaterAsset,
                localResults.discountedBorrowDenominatedCollateral
            );
        }

        // If liquidateBorrowAmount = -1, then closeBorrowAmount_TargetUnderwaterAsset = maxCloseableBorrowAmount_TargetUnderwaterAsset
        if (requestedAmountClose == uint256(-1)) {
            localResults.closeBorrowAmount_TargetUnderwaterAsset = localResults
                .maxCloseableBorrowAmount_TargetUnderwaterAsset;
        } else {
            localResults
                .closeBorrowAmount_TargetUnderwaterAsset = requestedAmountClose;
        }

        // From here on, no more use of `requestedAmountClose`

        // Verify closeBorrowAmount_TargetUnderwaterAsset <= maxCloseableBorrowAmount_TargetUnderwaterAsset
        if (
            localResults.closeBorrowAmount_TargetUnderwaterAsset >
            localResults.maxCloseableBorrowAmount_TargetUnderwaterAsset
        ) {
            return
                fail(
                    Error.INVALID_CLOSE_AMOUNT_REQUESTED,
                    FailureInfo.LIQUIDATE_CLOSE_AMOUNT_TOO_HIGH
                );
        }

        // seizeSupplyAmount_TargetCollateralAsset = closeBorrowAmount_TargetUnderwaterAsset * priceBorrow/priceCollateral *(1+liquidationDiscount)
        (
            err,
            localResults.seizeSupplyAmount_TargetCollateralAsset
        ) = calculateAmountSeize(
            localResults.underwaterAssetPrice,
            localResults.collateralPrice,
            localResults.closeBorrowAmount_TargetUnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.LIQUIDATE_AMOUNT_SEIZE_CALCULATION_FAILED
                );
        }

        // We are going to ERC-20 transfer closeBorrowAmount_TargetUnderwaterAsset of assetBorrow into Lendf.me
        // Fail gracefully if asset is not approved or has insufficient balance
        err = checkTransferIn(
            assetBorrow,
            localResults.liquidator,
            localResults.closeBorrowAmount_TargetUnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            return fail(err, FailureInfo.LIQUIDATE_TRANSFER_IN_NOT_POSSIBLE);
        }

        // We are going to repay the target user's borrow using the calling user's funds
        // We update the protocol's totalBorrow for assetBorrow, by subtracting the target user's prior checkpointed balance,
        // adding borrowCurrent, and subtracting closeBorrowAmount_TargetUnderwaterAsset.

        // Subtract the `closeBorrowAmount_TargetUnderwaterAsset` from the `currentBorrowBalance_TargetUnderwaterAsset` to get `updatedBorrowBalance_TargetUnderwaterAsset`
        (err, localResults.updatedBorrowBalance_TargetUnderwaterAsset) = sub(
            localResults.currentBorrowBalance_TargetUnderwaterAsset,
            localResults.closeBorrowAmount_TargetUnderwaterAsset
        );
        // We have ensured above that localResults.closeBorrowAmount_TargetUnderwaterAsset <= localResults.currentBorrowBalance_TargetUnderwaterAsset, so the sub can't underflow
        assert(err == Error.NO_ERROR);

        // We calculate the protocol's totalBorrow for assetBorrow by subtracting the user's prior checkpointed balance, adding user's updated borrow
        // Note that, even though the liquidator is paying some of the borrow, if the borrow has accumulated a lot of interest since the last
        // action, the updated balance *could* be higher than the prior checkpointed balance.
        (
            err,
            localResults.newTotalBorrows_ProtocolUnderwaterAsset
        ) = addThenSub(
            borrowMarket.totalBorrows,
            localResults.updatedBorrowBalance_TargetUnderwaterAsset,
            borrowBalance_TargeUnderwaterAsset.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_TOTAL_BORROW_CALCULATION_FAILED_BORROWED_ASSET
                );
        }

        // We need to calculate what the updated cash will be after we transfer in from liquidator
        localResults.currentCash_ProtocolUnderwaterAsset = getCash(assetBorrow);
        (err, localResults.updatedCash_ProtocolUnderwaterAsset) = add(
            localResults.currentCash_ProtocolUnderwaterAsset,
            localResults.closeBorrowAmount_TargetUnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_TOTAL_CASH_CALCULATION_FAILED_BORROWED_ASSET
                );
        }

        // The utilization rate has changed! We calculate a new supply index, borrow index, supply rate, and borrow rate for assetBorrow
        // (Please note that we don't need to do the same thing for assetCollateral because neither cash nor borrows of assetCollateral happen in this process.)

        // We calculate the newSupplyIndex_UnderwaterAsset, but we already have newBorrowIndex_UnderwaterAsset so don't recalculate it.
        (
            err,
            localResults.newSupplyIndex_UnderwaterAsset
        ) = calculateInterestIndex(
            borrowMarket.supplyIndex,
            borrowMarket.supplyRateMantissa,
            borrowMarket.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_SUPPLY_INDEX_CALCULATION_FAILED_BORROWED_ASSET
                );
        }

        (
            rateCalculationResultCode,
            localResults.newSupplyRateMantissa_ProtocolUnderwaterAsset
        ) = borrowMarket.interestRateModel.getSupplyRate(
            assetBorrow,
            localResults.updatedCash_ProtocolUnderwaterAsset,
            localResults.newTotalBorrows_ProtocolUnderwaterAsset
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo
                        .LIQUIDATE_NEW_SUPPLY_RATE_CALCULATION_FAILED_BORROWED_ASSET,
                    rateCalculationResultCode
                );
        }

        (
            rateCalculationResultCode,
            localResults.newBorrowRateMantissa_ProtocolUnderwaterAsset
        ) = borrowMarket.interestRateModel.getBorrowRate(
            assetBorrow,
            localResults.updatedCash_ProtocolUnderwaterAsset,
            localResults.newTotalBorrows_ProtocolUnderwaterAsset
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo
                        .LIQUIDATE_NEW_BORROW_RATE_CALCULATION_FAILED_BORROWED_ASSET,
                    rateCalculationResultCode
                );
        }

        // Now we look at collateral. We calculated target user's accumulated supply balance and the supply index above.
        // Now we need to calculate the borrow index.
        // We don't need to calculate new rates for the collateral asset because we have not changed utilization:
        //  - accumulating interest on the target user's collateral does not change cash or borrows
        //  - transferring seized amount of collateral internally from the target user to the liquidator does not change cash or borrows.
        (
            err,
            localResults.newBorrowIndex_CollateralAsset
        ) = calculateInterestIndex(
            collateralMarket.borrowIndex,
            collateralMarket.borrowRateMantissa,
            collateralMarket.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo
                        .LIQUIDATE_NEW_BORROW_INDEX_CALCULATION_FAILED_COLLATERAL_ASSET
                );
        }

        // We checkpoint the target user's assetCollateral supply balance, supplyCurrent - seizeSupplyAmount_TargetCollateralAsset at the updated index
        (err, localResults.updatedSupplyBalance_TargetCollateralAsset) = sub(
            localResults.currentSupplyBalance_TargetCollateralAsset,
            localResults.seizeSupplyAmount_TargetCollateralAsset
        );
        // The sub won't underflow because because seizeSupplyAmount_TargetCollateralAsset <= target user's collateral balance
        // maxCloseableBorrowAmount_TargetUnderwaterAsset is limited by the discounted borrow denominated collateral. That limits closeBorrowAmount_TargetUnderwaterAsset
        // which in turn limits seizeSupplyAmount_TargetCollateralAsset.
        assert(err == Error.NO_ERROR);

        // We checkpoint the liquidating user's assetCollateral supply balance, supplyCurrent + seizeSupplyAmount_TargetCollateralAsset at the updated index
        (
            err,
            localResults.updatedSupplyBalance_LiquidatorCollateralAsset
        ) = add(
            localResults.currentSupplyBalance_LiquidatorCollateralAsset,
            localResults.seizeSupplyAmount_TargetCollateralAsset
        );
        // We can't overflow here because if this would overflow, then we would have already overflowed above and failed
        // with LIQUIDATE_NEW_TOTAL_SUPPLY_BALANCE_CALCULATION_FAILED_LIQUIDATOR_COLLATERAL_ASSET
        assert(err == Error.NO_ERROR);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset into the protocol (note: pre-conditions already checked above)
        err = doTransferIn(
            assetBorrow,
            localResults.liquidator,
            localResults.closeBorrowAmount_TargetUnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return fail(err, FailureInfo.LIQUIDATE_TRANSFER_IN_FAILED);
        }

        // Save borrow market updates
        borrowMarket.blockNumber = getBlockNumber();
        borrowMarket.totalBorrows = localResults
            .newTotalBorrows_ProtocolUnderwaterAsset;
        // borrowMarket.totalSupply does not need to be updated
        borrowMarket.supplyRateMantissa = localResults
            .newSupplyRateMantissa_ProtocolUnderwaterAsset;
        borrowMarket.supplyIndex = localResults.newSupplyIndex_UnderwaterAsset;
        borrowMarket.borrowRateMantissa = localResults
            .newBorrowRateMantissa_ProtocolUnderwaterAsset;
        borrowMarket.borrowIndex = localResults.newBorrowIndex_UnderwaterAsset;

        // Save collateral market updates
        // We didn't calculate new rates for collateralMarket (because neither cash nor borrows changed), just new indexes and total supply.
        collateralMarket.blockNumber = getBlockNumber();
        collateralMarket.totalSupply = localResults
            .newTotalSupply_ProtocolCollateralAsset;
        collateralMarket.supplyIndex = localResults
            .newSupplyIndex_CollateralAsset;
        collateralMarket.borrowIndex = localResults
            .newBorrowIndex_CollateralAsset;

        // Save user updates

        localResults
            .startingBorrowBalance_TargetUnderwaterAsset = borrowBalance_TargeUnderwaterAsset
            .principal; // save for use in event
        borrowBalance_TargeUnderwaterAsset.principal = localResults
            .updatedBorrowBalance_TargetUnderwaterAsset;
        borrowBalance_TargeUnderwaterAsset.interestIndex = localResults
            .newBorrowIndex_UnderwaterAsset;

        localResults
            .startingSupplyBalance_TargetCollateralAsset = supplyBalance_TargetCollateralAsset
            .principal; // save for use in event
        supplyBalance_TargetCollateralAsset.principal = localResults
            .updatedSupplyBalance_TargetCollateralAsset;
        supplyBalance_TargetCollateralAsset.interestIndex = localResults
            .newSupplyIndex_CollateralAsset;

        localResults
            .startingSupplyBalance_LiquidatorCollateralAsset = supplyBalance_LiquidatorCollateralAsset
            .principal; // save for use in event
        supplyBalance_LiquidatorCollateralAsset.principal = localResults
            .updatedSupplyBalance_LiquidatorCollateralAsset;
        supplyBalance_LiquidatorCollateralAsset.interestIndex = localResults
            .newSupplyIndex_CollateralAsset;

        emitLiquidationEvent(localResults);

        return uint256(Error.NO_ERROR); // success
    }

    /**
     * @dev this function exists to avoid error `CompilerError: Stack too deep, try removing local variables.` in `liquidateBorrow`
     */
    function emitLiquidationEvent(LiquidateLocalVars memory localResults)
        internal
    {
        // event BorrowLiquidated(address targetAccount, address assetBorrow, uint borrowBalanceBefore, uint borrowBalanceAccumulated, uint amountRepaid, uint borrowBalanceAfter,
        // address liquidator, address assetCollateral, uint collateralBalanceBefore, uint collateralBalanceAccumulated, uint amountSeized, uint collateralBalanceAfter);
        emit BorrowLiquidated(
            localResults.targetAccount,
            localResults.assetBorrow,
            localResults.startingBorrowBalance_TargetUnderwaterAsset,
            localResults.currentBorrowBalance_TargetUnderwaterAsset,
            localResults.closeBorrowAmount_TargetUnderwaterAsset,
            localResults.updatedBorrowBalance_TargetUnderwaterAsset,
            localResults.liquidator,
            localResults.assetCollateral,
            localResults.startingSupplyBalance_TargetCollateralAsset,
            localResults.currentSupplyBalance_TargetCollateralAsset,
            localResults.seizeSupplyAmount_TargetCollateralAsset,
            localResults.updatedSupplyBalance_TargetCollateralAsset
        );
    }

    /**
     * @dev This should ONLY be called if market is supported. It returns shortfall / [Oracle price for the borrow * (collateralRatio - liquidationDiscount - 1)]
     *      If the market isn't supported, we support liquidation of asset regardless of shortfall because we want borrows of the unsupported asset to be closed.
     *      Note that if collateralRatio = liquidationDiscount + 1, then the denominator will be zero and the function will fail with DIVISION_BY_ZERO.
     */
    function calculateDiscountedRepayToEvenAmount(
        address targetAccount,
        Exp memory underwaterAssetPrice
    ) internal view returns (Error, uint256) {
        Error err;
        Exp memory _accountLiquidity; // unused return value from calculateAccountLiquidity
        Exp memory accountShortfall_TargetUser;
        Exp memory collateralRatioMinusLiquidationDiscount; // collateralRatio - liquidationDiscount
        Exp memory discountedCollateralRatioMinusOne; // collateralRatioMinusLiquidationDiscount - 1, aka collateralRatio - liquidationDiscount - 1
        Exp memory discountedPrice_UnderwaterAsset;
        Exp memory rawResult;

        // we calculate the target user's shortfall, denominated in Ether, that the user is below the collateral ratio
        (
            err,
            _accountLiquidity,
            accountShortfall_TargetUser
        ) = calculateAccountLiquidity(targetAccount);
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, collateralRatioMinusLiquidationDiscount) = subExp(
            collateralRatio,
            liquidationDiscount
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, discountedCollateralRatioMinusOne) = subExp(
            collateralRatioMinusLiquidationDiscount,
            Exp({mantissa: mantissaOne})
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, discountedPrice_UnderwaterAsset) = mulExp(
            underwaterAssetPrice,
            discountedCollateralRatioMinusOne
        );
        // calculateAccountLiquidity multiplies underwaterAssetPrice by collateralRatio
        // discountedCollateralRatioMinusOne < collateralRatio
        // so if underwaterAssetPrice * collateralRatio did not overflow then
        // underwaterAssetPrice * discountedCollateralRatioMinusOne can't overflow either
        assert(err == Error.NO_ERROR);

        (err, rawResult) = divExp(
            accountShortfall_TargetUser,
            discountedPrice_UnderwaterAsset
        );
        // It's theoretically possible an asset could have such a low price that it truncates to zero when discounted.
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        return (Error.NO_ERROR, truncate(rawResult));
    }

    /**
     * @dev discountedBorrowDenominatedCollateral = [supplyCurrent / (1 + liquidationDiscount)] * (Oracle price for the collateral / Oracle price for the borrow)
     */
    function calculateDiscountedBorrowDenominatedCollateral(
        Exp memory underwaterAssetPrice,
        Exp memory collateralPrice,
        uint256 supplyCurrent_TargetCollateralAsset
    ) internal view returns (Error, uint256) {
        // To avoid rounding issues, we re-order and group the operations so we do 1 division and only at the end
        // [supplyCurrent * (Oracle price for the collateral)] / [ (1 + liquidationDiscount) * (Oracle price for the borrow) ]
        Error err;
        Exp memory onePlusLiquidationDiscount; // (1 + liquidationDiscount)
        Exp memory supplyCurrentTimesOracleCollateral; // supplyCurrent * Oracle price for the collateral
        Exp memory onePlusLiquidationDiscountTimesOracleBorrow; // (1 + liquidationDiscount) * Oracle price for the borrow
        Exp memory rawResult;

        (err, onePlusLiquidationDiscount) = addExp(
            Exp({mantissa: mantissaOne}),
            liquidationDiscount
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, supplyCurrentTimesOracleCollateral) = mulScalar(
            collateralPrice,
            supplyCurrent_TargetCollateralAsset
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, onePlusLiquidationDiscountTimesOracleBorrow) = mulExp(
            onePlusLiquidationDiscount,
            underwaterAssetPrice
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, rawResult) = divExp(
            supplyCurrentTimesOracleCollateral,
            onePlusLiquidationDiscountTimesOracleBorrow
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        return (Error.NO_ERROR, truncate(rawResult));
    }

    /**
     * @dev returns closeBorrowAmount_TargetUnderwaterAsset * (1+liquidationDiscount) * priceBorrow/priceCollateral
     */
    function calculateAmountSeize(
        Exp memory underwaterAssetPrice,
        Exp memory collateralPrice,
        uint256 closeBorrowAmount_TargetUnderwaterAsset
    ) internal view returns (Error, uint256) {
        // To avoid rounding issues, we re-order and group the operations to move the division to the end, rather than just taking the ratio of the 2 prices:
        // underwaterAssetPrice * (1+liquidationDiscount) *closeBorrowAmount_TargetUnderwaterAsset) / collateralPrice

        // re-used for all intermediate errors
        Error err;

        // (1+liquidationDiscount)
        Exp memory liquidationMultiplier;

        // assetPrice-of-underwaterAsset * (1+liquidationDiscount)
        Exp memory priceUnderwaterAssetTimesLiquidationMultiplier;

        // priceUnderwaterAssetTimesLiquidationMultiplier * closeBorrowAmount_TargetUnderwaterAsset
        // or, expanded:
        // underwaterAssetPrice * (1+liquidationDiscount) * closeBorrowAmount_TargetUnderwaterAsset
        Exp memory finalNumerator;

        // finalNumerator / priceCollateral
        Exp memory rawResult;

        (err, liquidationMultiplier) = addExp(
            Exp({mantissa: mantissaOne}),
            liquidationDiscount
        );
        // liquidation discount will be enforced < 1, so 1 + liquidationDiscount can't overflow.
        assert(err == Error.NO_ERROR);

        (err, priceUnderwaterAssetTimesLiquidationMultiplier) = mulExp(
            underwaterAssetPrice,
            liquidationMultiplier
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, finalNumerator) = mulScalar(
            priceUnderwaterAssetTimesLiquidationMultiplier,
            closeBorrowAmount_TargetUnderwaterAsset
        );
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        (err, rawResult) = divExp(finalNumerator, collateralPrice);
        if (err != Error.NO_ERROR) {
            return (err, 0);
        }

        return (Error.NO_ERROR, truncate(rawResult));
    }

    /**
     * @notice Users borrow assets from the protocol to their own address
     * @param asset The market asset to borrow
     * @param amount The amount to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(address asset, uint256 amount)
        public
        nonReentrant
        returns (uint256)
    {
        if (paused) {
            return
                fail(Error.CONTRACT_PAUSED, FailureInfo.BORROW_CONTRACT_PAUSED);
        }
        require(
            isWhitelist(msg.sender, this.supply.selector, asset),
            "borrow: Do not have permission!"
        );

        BorrowLocalVars memory localResults;
        Market storage market = markets[asset];
        Balance storage borrowBalance = borrowBalances[msg.sender][asset];

        Error err;
        uint256 rateCalculationResultCode;

        // Fail if market not supported
        if (!market.isSupported) {
            return
                fail(
                    Error.MARKET_NOT_SUPPORTED,
                    FailureInfo.BORROW_MARKET_NOT_SUPPORTED
                );
        }

        // We calculate the newBorrowIndex, user's borrowCurrent and borrowUpdated for the asset
        (err, localResults.newBorrowIndex) = calculateInterestIndex(
            market.borrowIndex,
            market.borrowRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_NEW_BORROW_INDEX_CALCULATION_FAILED
                );
        }

        (err, localResults.userBorrowCurrent) = calculateBalance(
            borrowBalance.principal,
            borrowBalance.interestIndex,
            localResults.newBorrowIndex
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED
                );
        }

        // Calculate origination fee.
        (err, localResults.borrowAmountWithFee) = calculateBorrowAmountWithFee(
            amount
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_ORIGINATION_FEE_CALCULATION_FAILED
                );
        }

        // Add the `borrowAmountWithFee` to the `userBorrowCurrent` to get `userBorrowUpdated`
        (err, localResults.userBorrowUpdated) = add(
            localResults.userBorrowCurrent,
            localResults.borrowAmountWithFee
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED
                );
        }

        // We calculate the protocol's totalBorrow by subtracting the user's prior checkpointed balance, adding user's updated borrow with fee
        (err, localResults.newTotalBorrows) = addThenSub(
            market.totalBorrows,
            localResults.userBorrowUpdated,
            borrowBalance.principal
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_NEW_TOTAL_BORROW_CALCULATION_FAILED
                );
        }

        // Check customer liquidity
        (
            err,
            localResults.accountLiquidity,
            localResults.accountShortfall
        ) = calculateAccountLiquidity(msg.sender);
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_ACCOUNT_LIQUIDITY_CALCULATION_FAILED
                );
        }

        // Fail if customer already has a shortfall
        if (!isZeroExp(localResults.accountShortfall)) {
            return
                fail(
                    Error.INSUFFICIENT_LIQUIDITY,
                    FailureInfo.BORROW_ACCOUNT_SHORTFALL_PRESENT
                );
        }

        // Would the customer have a shortfall after this borrow (including origination fee)?
        // We calculate the eth-equivalent value of (borrow amount + fee) of asset and fail if it exceeds accountLiquidity.
        // This implements: `[(collateralRatio*oraclea*borrowAmount)*(1+borrowFee)] > accountLiquidity`
        (
            err,
            localResults.ethValueOfBorrowAmountWithFee
        ) = getPriceForAssetAmountMulCollatRatio(
            asset,
            localResults.borrowAmountWithFee
        );
        if (err != Error.NO_ERROR) {
            return
                fail(err, FailureInfo.BORROW_AMOUNT_VALUE_CALCULATION_FAILED);
        }
        if (
            lessThanExp(
                localResults.accountLiquidity,
                localResults.ethValueOfBorrowAmountWithFee
            )
        ) {
            return
                fail(
                    Error.INSUFFICIENT_LIQUIDITY,
                    FailureInfo.BORROW_AMOUNT_LIQUIDITY_SHORTFALL
                );
        }

        // Fail gracefully if protocol has insufficient cash
        localResults.currentCash = getCash(asset);
        // We need to calculate what the updated cash will be after we transfer out to the user
        (err, localResults.updatedCash) = sub(localResults.currentCash, amount);
        if (err != Error.NO_ERROR) {
            // Note: we ignore error here and call this token insufficient cash
            return
                fail(
                    Error.TOKEN_INSUFFICIENT_CASH,
                    FailureInfo.BORROW_NEW_TOTAL_CASH_CALCULATION_FAILED
                );
        }

        // The utilization rate has changed! We calculate a new supply index and borrow index for the asset, and save it.

        // We calculate the newSupplyIndex, but we have newBorrowIndex already
        (err, localResults.newSupplyIndex) = calculateInterestIndex(
            market.supplyIndex,
            market.supplyRateMantissa,
            market.blockNumber,
            getBlockNumber()
        );
        if (err != Error.NO_ERROR) {
            return
                fail(
                    err,
                    FailureInfo.BORROW_NEW_SUPPLY_INDEX_CALCULATION_FAILED
                );
        }

        (rateCalculationResultCode, localResults.newSupplyRateMantissa) = market
            .interestRateModel
            .getSupplyRate(
            asset,
            localResults.updatedCash,
            localResults.newTotalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.BORROW_NEW_SUPPLY_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        (rateCalculationResultCode, localResults.newBorrowRateMantissa) = market
            .interestRateModel
            .getBorrowRate(
            asset,
            localResults.updatedCash,
            localResults.newTotalBorrows
        );
        if (rateCalculationResultCode != 0) {
            return
                failOpaque(
                    FailureInfo.BORROW_NEW_BORROW_RATE_CALCULATION_FAILED,
                    rateCalculationResultCode
                );
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We ERC-20 transfer the asset into the protocol (note: pre-conditions already checked above)
        err = doTransferOut(asset, msg.sender, amount);
        if (err != Error.NO_ERROR) {
            // This is safe since it's our first interaction and it didn't do anything if it failed
            return fail(err, FailureInfo.BORROW_TRANSFER_OUT_FAILED);
        }

        // Save market updates
        market.blockNumber = getBlockNumber();
        market.totalBorrows = localResults.newTotalBorrows;
        market.supplyRateMantissa = localResults.newSupplyRateMantissa;
        market.supplyIndex = localResults.newSupplyIndex;
        market.borrowRateMantissa = localResults.newBorrowRateMantissa;
        market.borrowIndex = localResults.newBorrowIndex;

        // Save user updates
        localResults.startingBalance = borrowBalance.principal; // save for use in `BorrowTaken` event
        borrowBalance.principal = localResults.userBorrowUpdated;
        borrowBalance.interestIndex = localResults.newBorrowIndex;

        emit BorrowTaken(
            msg.sender,
            asset,
            amount,
            localResults.startingBalance,
            localResults.borrowAmountWithFee,
            localResults.userBorrowUpdated
        );

        return uint256(Error.NO_ERROR); // success
    }
}