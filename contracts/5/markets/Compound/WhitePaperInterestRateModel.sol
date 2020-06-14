pragma solidity ^0.5.8;

/**
 * @title Careful Math
 * @author Compound
 * @notice Derived from OpenZeppelin's SafeMath library
 *         https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/math/SafeMath.sol
 */
contract CarefulMath {
    /**
     * @dev Possible error codes that we can return
     */
    enum MathError {
        NO_ERROR,
        DIVISION_BY_ZERO,
        INTEGER_OVERFLOW,
        INTEGER_UNDERFLOW
    }

    /**
     * @dev Multiplies two numbers, returns an error on overflow.
     */
    function mulUInt(uint256 a, uint256 b)
        internal
        pure
        returns (MathError, uint256)
    {
        if (a == 0) {
            return (MathError.NO_ERROR, 0);
        }

        uint256 c = a * b;

        if (c / a != b) {
            return (MathError.INTEGER_OVERFLOW, 0);
        } else {
            return (MathError.NO_ERROR, c);
        }
    }

    /**
     * @dev Integer division of two numbers, truncating the quotient.
     */
    function divUInt(uint256 a, uint256 b)
        internal
        pure
        returns (MathError, uint256)
    {
        if (b == 0) {
            return (MathError.DIVISION_BY_ZERO, 0);
        }

        return (MathError.NO_ERROR, a / b);
    }

    /**
     * @dev Subtracts two numbers, returns an error on overflow (i.e. if subtrahend is greater than minuend).
     */
    function subUInt(uint256 a, uint256 b)
        internal
        pure
        returns (MathError, uint256)
    {
        if (b <= a) {
            return (MathError.NO_ERROR, a - b);
        } else {
            return (MathError.INTEGER_UNDERFLOW, 0);
        }
    }

    /**
     * @dev Adds two numbers, returns an error on overflow.
     */
    function addUInt(uint256 a, uint256 b)
        internal
        pure
        returns (MathError, uint256)
    {
        uint256 c = a + b;

        if (c >= a) {
            return (MathError.NO_ERROR, c);
        } else {
            return (MathError.INTEGER_OVERFLOW, 0);
        }
    }

    /**
     * @dev add a and b and then subtract c
     */
    function addThenSubUInt(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (MathError, uint256) {
        (MathError err0, uint256 sum) = addUInt(a, b);

        if (err0 != MathError.NO_ERROR) {
            return (err0, 0);
        }

        return subUInt(sum, c);
    }
}

// File: contracts/Exponential.sol

pragma solidity ^0.5.8;

/**
 * @title Exponential module for storing fixed-decision decimals
 * @author Compound
 * @notice Exp is a struct which stores decimals with a fixed precision of 18 decimal places.
 *         Thus, if we wanted to store the 5.1, mantissa would store 5.1e18. That is:
 *         `Exp({mantissa: 5100000000000000000})`.
 */
contract Exponential is CarefulMath {
    uint256 constant expScale = 1e18;
    uint256 constant halfExpScale = expScale / 2;
    uint256 constant mantissaOne = expScale;

    struct Exp {
        uint256 mantissa;
    }

    /**
     * @dev Creates an exponential from numerator and denominator values.
     *      Note: Returns an error if (`num` * 10e18) > MAX_INT,
     *            or if `denom` is zero.
     */
    function getExp(uint256 num, uint256 denom)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError err0, uint256 scaledNumerator) = mulUInt(num, expScale);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        (MathError err1, uint256 rational) = divUInt(scaledNumerator, denom);
        if (err1 != MathError.NO_ERROR) {
            return (err1, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: rational}));
    }

    /**
     * @dev Adds two exponentials, returning a new exponential.
     */
    function addExp(Exp memory a, Exp memory b)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError error, uint256 result) = addUInt(a.mantissa, b.mantissa);

        return (error, Exp({mantissa: result}));
    }

    /**
     * @dev Subtracts two exponentials, returning a new exponential.
     */
    function subExp(Exp memory a, Exp memory b)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError error, uint256 result) = subUInt(a.mantissa, b.mantissa);

        return (error, Exp({mantissa: result}));
    }

    /**
     * @dev Multiply an Exp by a scalar, returning a new Exp.
     */
    function mulScalar(Exp memory a, uint256 scalar)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError err0, uint256 scaledMantissa) = mulUInt(a.mantissa, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: scaledMantissa}));
    }

    /**
     * @dev Multiply an Exp by a scalar, then truncate to return an unsigned integer.
     */
    function mulScalarTruncate(Exp memory a, uint256 scalar)
        internal
        pure
        returns (MathError, uint256)
    {
        (MathError err, Exp memory product) = mulScalar(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return (MathError.NO_ERROR, truncate(product));
    }

    /**
     * @dev Multiply an Exp by a scalar, truncate, then add an to an unsigned integer, returning an unsigned integer.
     */
    function mulScalarTruncateAddUInt(
        Exp memory a,
        uint256 scalar,
        uint256 addend
    ) internal pure returns (MathError, uint256) {
        (MathError err, Exp memory product) = mulScalar(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return addUInt(truncate(product), addend);
    }

    /**
     * @dev Divide an Exp by a scalar, returning a new Exp.
     */
    function divScalar(Exp memory a, uint256 scalar)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError err0, uint256 descaledMantissa) = divUInt(
            a.mantissa,
            scalar
        );
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        return (MathError.NO_ERROR, Exp({mantissa: descaledMantissa}));
    }

    /**
     * @dev Divide a scalar by an Exp, returning a new Exp.
     */
    function divScalarByExp(uint256 scalar, Exp memory divisor)
        internal
        pure
        returns (MathError, Exp memory)
    {
        /*
          We are doing this as:
          getExp(mulUInt(expScale, scalar), divisor.mantissa)

          How it works:
          Exp = a / b;
          Scalar = s;
          `s / (a / b)` = `b * s / a` and since for an Exp `a = mantissa, b = expScale`
        */
        (MathError err0, uint256 numerator) = mulUInt(expScale, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }
        return getExp(numerator, divisor.mantissa);
    }

    /**
     * @dev Divide a scalar by an Exp, then truncate to return an unsigned integer.
     */
    function divScalarByExpTruncate(uint256 scalar, Exp memory divisor)
        internal
        pure
        returns (MathError, uint256)
    {
        (MathError err, Exp memory fraction) = divScalarByExp(scalar, divisor);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }

        return (MathError.NO_ERROR, truncate(fraction));
    }

    /**
     * @dev Multiplies two exponentials, returning a new exponential.
     */
    function mulExp(Exp memory a, Exp memory b)
        internal
        pure
        returns (MathError, Exp memory)
    {
        (MathError err0, uint256 doubleScaledProduct) = mulUInt(
            a.mantissa,
            b.mantissa
        );
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }

        // We add half the scale before dividing so that we get rounding instead of truncation.
        //  See "Listing 6" and text above it at https://accu.org/index.php/journals/1717
        // Without this change, a result like 6.6...e-19 will be truncated to 0 instead of being rounded to 1e-18.
        (MathError err1, uint256 doubleScaledProductWithHalfScale) = addUInt(
            halfExpScale,
            doubleScaledProduct
        );
        if (err1 != MathError.NO_ERROR) {
            return (err1, Exp({mantissa: 0}));
        }

        (MathError err2, uint256 product) = divUInt(
            doubleScaledProductWithHalfScale,
            expScale
        );
        // The only error `div` can return is MathError.DIVISION_BY_ZERO but we control `expScale` and it is not zero.
        assert(err2 == MathError.NO_ERROR);

        return (MathError.NO_ERROR, Exp({mantissa: product}));
    }

    /**
     * @dev Multiplies two exponentials given their mantissas, returning a new exponential.
     */
    function mulExp(uint256 a, uint256 b)
        internal
        pure
        returns (MathError, Exp memory)
    {
        return mulExp(Exp({mantissa: a}), Exp({mantissa: b}));
    }

    /**
     * @dev Multiplies three exponentials, returning a new exponential.
     */
    function mulExp3(
        Exp memory a,
        Exp memory b,
        Exp memory c
    ) internal pure returns (MathError, Exp memory) {
        (MathError err, Exp memory ab) = mulExp(a, b);
        if (err != MathError.NO_ERROR) {
            return (err, ab);
        }
        return mulExp(ab, c);
    }

    /**
     * @dev Divides two exponentials, returning a new exponential.
     *     (a/scale) / (b/scale) = (a/scale) * (scale/b) = a/b,
     *  which we can scale as an Exp by calling getExp(a.mantissa, b.mantissa)
     */
    function divExp(Exp memory a, Exp memory b)
        internal
        pure
        returns (MathError, Exp memory)
    {
        return getExp(a.mantissa, b.mantissa);
    }

    /**
     * @dev Truncates the given exp to a whole number value.
     *      For example, truncate(Exp{mantissa: 15 * expScale}) = 15
     */
    function truncate(Exp memory exp) internal pure returns (uint256) {
        // Note: We are not using careful math here as we're performing a division that cannot fail
        return exp.mantissa / expScale;
    }

    /**
     * @dev Checks if first Exp is less than second Exp.
     */
    function lessThanExp(Exp memory left, Exp memory right)
        internal
        pure
        returns (bool)
    {
        return left.mantissa < right.mantissa; //TODO: Add some simple tests and this in another PR yo.
    }

    /**
     * @dev Checks if left Exp <= right Exp.
     */
    function lessThanOrEqualExp(Exp memory left, Exp memory right)
        internal
        pure
        returns (bool)
    {
        return left.mantissa <= right.mantissa;
    }

    /**
     * @dev returns true if Exp is exactly zero
     */
    function isZeroExp(Exp memory value) internal pure returns (bool) {
        return value.mantissa == 0;
    }
}

// File: contracts/InterestRateModel.sol

pragma solidity ^0.5.8;

/**
 * @title The Compound InterestRateModel Interface
 * @author Compound
 * @notice Any interest rate model should derive from this contract.
 * @dev These functions are specifically not marked `pure` as implementations of this
 *      contract may read from storage variables.
 */
interface InterestRateModel {
    /**
     * @notice Gets the current borrow interest rate based on the given asset, total cash, total borrows
     *         and total reserves.
     * @dev The return value should be scaled by 1e18, thus a return value of
     *      `(true, 1000000000000)` implies an interest rate of 0.000001 or 0.0001% *per block*.
     * @param cash The total cash of the underlying asset in the CToken
     * @param borrows The total borrows of the underlying asset in the CToken
     * @param reserves The total reserves of the underlying asset in the CToken
     * @return Success or failure and the borrow interest rate per block scaled by 10e18
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256, uint256);

    /**
     * @notice Marker function used for light validation when updating the interest rate model of a market
     * @dev Marker function used for light validation when updating the interest rate model of a market. Implementations should simply return true.
     * @return Success or failure
     */
    function isInterestRateModel() external view returns (bool);
}

// File: contracts/WhitePaperInterestRateModel.sol

pragma solidity ^0.5.8;

/**
 * @title The Compound Standard Interest Rate Model with pluggable constants
 * @author Compound
 * @notice See Section 2.4 of the Compound Whitepaper
 */
contract WhitePaperInterestRateModel is InterestRateModel, Exponential {
    /**
     * @notice Indicator that this is an InterestRateModel contract (for inspection)
     */
    bool public constant isInterestRateModel = true;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    uint256 public multiplier;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    uint256 public baseRate;

    /**
     * @notice The approximate number of blocks per year that is assumed by the interest rate model
     */
    uint256 public constant blocksPerYear = 2102400;

    constructor(uint256 baseRate_, uint256 multiplier_) public {
        baseRate = baseRate_;
        multiplier = multiplier_;
    }

    enum IRError {
        NO_ERROR,
        FAILED_TO_ADD_CASH_PLUS_BORROWS,
        FAILED_TO_GET_EXP,
        FAILED_TO_MUL_UTILIZATION_RATE,
        FAILED_TO_ADD_BASE_RATE
    }

    /*
     * @dev Calculates the utilization rate (borrows / (cash + borrows)) as an Exp
     */
    function getUtilizationRate(uint256 cash, uint256 borrows)
        internal
        pure
        returns (IRError, Exp memory)
    {
        if (borrows == 0) {
            // Utilization rate is zero when there's no borrows
            return (IRError.NO_ERROR, Exp({mantissa: 0}));
        }

        (MathError err0, uint256 cashPlusBorrows) = addUInt(cash, borrows);
        if (err0 != MathError.NO_ERROR) {
            return (
                IRError.FAILED_TO_ADD_CASH_PLUS_BORROWS,
                Exp({mantissa: 0})
            );
        }

        (MathError err1, Exp memory utilizationRate) = getExp(
            borrows,
            cashPlusBorrows
        );
        if (err1 != MathError.NO_ERROR) {
            return (IRError.FAILED_TO_GET_EXP, Exp({mantissa: 0}));
        }

        return (IRError.NO_ERROR, utilizationRate);
    }

    /*
     * @dev Calculates the utilization and borrow rates for use by getBorrowRate function
     */
    function getUtilizationAndAnnualBorrowRate(uint256 cash, uint256 borrows)
        internal
        view
        returns (
            IRError,
            Exp memory,
            Exp memory
        )
    {
        (IRError err0, Exp memory utilizationRate) = getUtilizationRate(
            cash,
            borrows
        );
        if (err0 != IRError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}), Exp({mantissa: 0}));
        }

        // Borrow Rate is 5% + UtilizationRate * 45% (baseRate + UtilizationRate * multiplier);
        // 45% of utilizationRate, is `rate * 45 / 100`
        (MathError err1, Exp memory utilizationRateMuled) = mulScalar(
            utilizationRate,
            multiplier
        );
        // `mulScalar` only overflows when the product is >= 2^256.
        // utilizationRate is a real number on the interval [0,1], which means that
        // utilizationRate.mantissa is in the interval [0e18,1e18], which means that 45 times
        // that is in the interval [0e18,45e18]. That interval has no intersection with 2^256, and therefore
        // this can never overflow for the standard rates.
        if (err1 != MathError.NO_ERROR) {
            return (
                IRError.FAILED_TO_MUL_UTILIZATION_RATE,
                Exp({mantissa: 0}),
                Exp({mantissa: 0})
            );
        }

        (MathError err2, Exp memory utilizationRateScaled) = divScalar(
            utilizationRateMuled,
            mantissaOne
        );
        // 100 is a constant, and therefore cannot be zero, which is the only error case of divScalar.
        assert(err2 == MathError.NO_ERROR);

        // Add the 5% for (5% + 45% * Ua)
        (MathError err3, Exp memory annualBorrowRate) = addExp(
            utilizationRateScaled,
            Exp({mantissa: baseRate})
        );
        // `addExp` only fails when the addition of mantissas overflow.
        // As per above, utilizationRateMuled is capped at 45e18,
        // and utilizationRateScaled is capped at 4.5e17. mantissaFivePercent = 0.5e17, and thus the addition
        // is capped at 5e17, which is less than 2^256. This only applies to the standard rates
        if (err3 != MathError.NO_ERROR) {
            return (
                IRError.FAILED_TO_ADD_BASE_RATE,
                Exp({mantissa: 0}),
                Exp({mantissa: 0})
            );
        }

        return (IRError.NO_ERROR, utilizationRate, annualBorrowRate);
    }

    /**
     * @notice Gets the current borrow interest rate based on the given asset, total cash, total borrows
     *         and total reserves.
     * @dev The return value should be scaled by 1e18, thus a return value of
     *      `(true, 1000000000000)` implies an interest rate of 0.000001 or 0.0001% *per block*.
     * @param cash The total cash of the underlying asset in the CToken
     * @param borrows The total borrows of the underlying asset in the CToken
     * @param _reserves The total reserves of the underlying asset in the CToken
     * @return Success or failure and the borrow interest rate per block scaled by 10e18
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 _reserves
    ) public view returns (uint256, uint256) {
        _reserves; // pragma ignore unused argument

        (
            IRError err0,
            Exp memory _utilizationRate,
            Exp memory annualBorrowRate
        ) = getUtilizationAndAnnualBorrowRate(cash, borrows);
        if (err0 != IRError.NO_ERROR) {
            return (uint256(err0), 0);
        }

        // And then divide down by blocks per year.
        (MathError err1, Exp memory borrowRate) = divScalar(
            annualBorrowRate,
            blocksPerYear
        ); // basis points * blocks per year
        // divScalar only fails when divisor is zero. This is clearly not the case.
        assert(err1 == MathError.NO_ERROR);

        _utilizationRate; // pragma ignore unused variable

        // Note: mantissa is the rate scaled 1e18, which matches the expected result
        return (uint256(IRError.NO_ERROR), borrowRate.mantissa);
    }
}
