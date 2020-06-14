pragma solidity 0.5.12;

import "./interface/ILendFMe.sol";
import "./library/ERC20SafeTransfer.sol";
import "./library/DSAuth.sol";
import "./library/SafeMath.sol";
import "./dTokenAddresses.sol";
import "./library/Pausable.sol";

contract Handler is ERC20SafeTransfer, Pausable {
    using SafeMath for uint256;

    bool private initialized; // Flags for initializing data
    address public targetAddr; // market address
    address public dTokens; // dToken address

    mapping(address => bool) public tokensEnable;

    mapping(address => uint256) public interestsDetails;

    function disableToken(address _token) external auth {
        tokensEnable[_token] = false;
    }

    function enableToken(address _token) external auth {
        tokensEnable[_token] = true;
    }

    constructor(address _targetAddr, address _dTokens) public {
        initialize(_targetAddr, _dTokens);
    }

    // --- Init ---
    // This function is used with contract proxy, do not modify this function.
    function initialize(address _targetAddr, address _dTokens) public {
        require(!initialized, "initialize: Already initialized!");
        owner = msg.sender;
        targetAddr = _targetAddr;
        dTokens = _dTokens;
        initialized = true;
    }

    /**
     * @dev This token `_token` approves to market and dToken contract.
     * @param _token Token address to approve.
     */
    function approve(address _token) public {
        address _dToken = dTokenAddresses(dTokens).getdToken(_token);
        if (IERC20(_token).allowance(address(this), targetAddr) != uint256(-1))
            require(
                doApprove(_token, targetAddr, uint256(-1)),
                "approve: Approve market failed!"
            );

        if (IERC20(_token).allowance(address(this), _dToken) != uint256(-1))
            require(
                doApprove(_token, _dToken, uint256(-1)),
                "approve: Approve dToken failed!"
            );
    }

    /**
     * @dev Deposit token to market, but only for dToken contract.
     * @param _underlyingToken Token to deposit.
     * @return True is success, false is failure.
     */
    function deposit(address _underlyingToken, uint256 _amount)
        external
        auth
        whenNotPaused
        returns (uint256)
    {
        require(tokensEnable[_underlyingToken], "deposit: token is disabled!");
        uint256 _previousBalance = getBalance(_underlyingToken);
        (uint256 _principalBalance, ) = ILendFMe(targetAddr).supplyBalances(
            address(this),
            _underlyingToken
        );

        uint256 _periodInterests = _previousBalance.sub(_principalBalance);
        interestsDetails[_underlyingToken] = interestsDetails[_underlyingToken]
            .add(_periodInterests);

        if (_amount == 0) {
            return uint256(0);
        }
        require(
            ILendFMe(targetAddr).supply(address(_underlyingToken), _amount) ==
                0,
            "deposit: Fail to supply to money market!"
        );
        return _amount;
    }

    /**
     * @dev Withdraw token from market, but only for dToken contract.
     * @param _underlyingToken Token to withdraw.
     * @param _amount Token amount to withdraw.
     * @return Actually withdraw token amount.
     */
    function withdraw(address _underlyingToken, uint256 _amount)
        external
        auth
        whenNotPaused
        returns (uint256)
    {
        uint256 _previousBalance = getBalance(_underlyingToken);
        (uint256 _principalBalance, ) = ILendFMe(targetAddr).supplyBalances(
            address(this),
            _underlyingToken
        );

        uint256 _periodInterests = _previousBalance.sub(_principalBalance);
        interestsDetails[_underlyingToken] = interestsDetails[_underlyingToken]
            .add(_periodInterests);

        if (_amount == 0) {
            return uint256(0);
        }
        require(
            ILendFMe(targetAddr).withdraw(address(_underlyingToken), _amount) ==
                0,
            "withdraw: Fail to withdraw from money market!"
        );

        return _amount;
    }

    /**
     * @dev Redeem token from market, but only for dToken contract.
     * @param _underlyingToken Token to redeem.
     * @param _amount Token amount to redeem.
     * @return Actually redeem token amount.
     */
    function redeem(address _underlyingToken, uint256 _amount)
        external
        auth
        whenNotPaused
        returns (uint256, uint256)
    {
        uint256 _previousBalance = getBalance(_underlyingToken);
        (uint256 _principalBalance, ) = ILendFMe(targetAddr).supplyBalances(
            address(this),
            _underlyingToken
        );

        uint256 _periodInterests = _previousBalance.sub(_principalBalance);
        interestsDetails[_underlyingToken] = interestsDetails[_underlyingToken]
            .add(_periodInterests);

        if (_amount == 0) {
            return (uint256(0), uint256(0));
        }
        require(
            ILendFMe(targetAddr).withdraw(address(_underlyingToken), _amount) ==
                0,
            "redeem: Fail to redeem from money market!"
        );

        return (_amount, _amount);
    }

    /**
     * @dev Supply balance with any accumulated interest for `_underlyingToken` belonging to `handler`
     * @param _underlyingToken Token to get balance.
     */
    function getBalance(address _underlyingToken)
        public
        view
        returns (uint256)
    {
        return
            ILendFMe(targetAddr).getSupplyBalance(
                address(this),
                _underlyingToken
            );
    }

    /**
     * @dev The maximum withdrawable amount of token `_underlyingToken` in the market.
     * @param _underlyingToken Token to get balance.
     */
    function getLiquidity(address _underlyingToken)
        public
        view
        returns (uint256)
    {
        uint256 _supplyBalance = getBalance(_underlyingToken);
        uint256 _balance = IERC20(_underlyingToken).balanceOf(targetAddr);
        if (_supplyBalance > _balance) return _balance;

        return _supplyBalance;
    }

    /**
     * @dev The maximum withdrawable amount of asset `_underlyingToken` in the market,
     *      and excludes fee, if has.
     * @param _underlyingToken Token to get actual balance.
     */
    function getRealBalance(address _underlyingToken)
        external
        view
        returns (uint256)
    {
        return getLiquidity(_underlyingToken);
    }

    /**
     * @dev Calculate the actual amount of token that has excluded exchange fee
     *      between token and wrapped token, if has.
     * @param _pie Token amount to get.
     */
    function getRealAmount(uint256 _pie) external view returns (uint256) {
        return _pie;
    }

    /**
     * @dev Get token `_underlyingToken` APR in the market.
     * @param _underlyingToken Token to get APR.
     */
    function getInterestRate(address _underlyingToken)
        external
        view
        returns (uint256)
    {
        (, , , , uint256 _apr, , , , ) = ILendFMe(targetAddr).markets(
            _underlyingToken
        );
        return _apr.mul(2102400);
    }

    function getTargetAddress() external view returns (address) {
        return targetAddr;
    }
}
