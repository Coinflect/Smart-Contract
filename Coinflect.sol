//SPDX-License-Identifier: Unlicense
pragma solidity >=0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapPair.sol";

interface IPinkAntiBot {
  function setTokenOwner(address owner) external;

  function onPreTransferCheck(
    address from,
    address to,
    uint256 amount
  ) external;
}

contract Coinflect is Context, ERC20, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant MAX_FEE = 10000;
    address public feeRecipient;

    uint256 public constant FEE_LIMIT = 1000; // max 10%
    uint256 public liquidityFee = 400;
    uint256 public operationFee = 1000;
    uint256 public minSwapAmount = 100000 ether;
    bool private inSwap;
    bool public startedSale;
    mapping(address => bool) private isExcludedFromFee;

    address public uniswapPair;
    address public unirouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    IERC20 public constant WBNB =
        IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPinkAntiBot public pinkAntiBot;

    constructor(address _pinkAntiBot) ERC20("Coinflect", "CFLT") {
        pinkAntiBot = IPinkAntiBot(_pinkAntiBot);
        pinkAntiBot.setTokenOwner(msg.sender);

        feeRecipient = msg.sender;
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[msg.sender] = true;

        _mint(msg.sender, uint256(42000000000 ether)); // 42 billion
    }

    function setLiquidityFee(uint256 _percentage) external onlyOwner {
        require (_percentage <= FEE_LIMIT, "!available");
        liquidityFee = _percentage;
    }

    function setOperationFee(uint256 _percentage) external onlyOwner {
        require (_percentage <= FEE_LIMIT, "!available");
        operationFee = _percentage;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        isExcludedFromFee[_feeRecipient] = true;
    }

    function startSale() external onlyOwner {
        startedSale = true;
    }

    function setMinimumSwapAmount(uint256 _amount) external onlyOwner {
        minSwapAmount = _amount;
    }

    function setUniswapRouter(address _router) external onlyOwner {
        unirouter = _router;
    }

    function excludeFromFee(address _account) external onlyOwner {
        isExcludedFromFee[_account] = true;
    }

    function includeFromFee(address _account) external onlyOwner {
        isExcludedFromFee[_account] = false;
    }

    function createLP() external onlyOwner {
        address pair = IUniswapV2Factory(IUniswapV2Router02(unirouter).factory()).getPair(address(this), IUniswapV2Router02(unirouter).WETH());
        if (pair != address(0)) return;

        uniswapPair = IUniswapV2Factory(IUniswapV2Router02(unirouter).factory())
            .createPair(address(this), IUniswapV2Router02(unirouter).WETH());
    }

    function addLiquidity(uint256 _amount) external payable onlyOwner {
        require (msg.value > 0, "!bnb");
        IERC20(address(this)).safeTransferFrom(msg.sender, address(this), _amount);
        _addLiquidity(_amount, msg.value);
    }

    /**
     Transfer
     */

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) internal override {
        pinkAntiBot.onPreTransferCheck(_sender, _recipient, _amount);

        address pair = IUniswapV2Factory(IUniswapV2Router02(unirouter).factory()).getPair(address(this), IUniswapV2Router02(unirouter).WETH());

        // Ignore tax process in case that remove liquidity
        if (!startedSale || (_sender == pair && _recipient == unirouter) || _sender == unirouter) {
            super._transfer(_sender, _recipient, _amount);
            return;
        }

        uint collectedTaxes = balanceOf(address(this));
        if (collectedTaxes >= minSwapAmount && !_isTrading(_sender, _recipient) && !inSwap) {
            swapAndLiquify();
        }

        uint256 tFee = _amount.mul(liquidityFee.add(operationFee)).div(MAX_FEE);
        if (tFee > 0 && _isTrading(_sender, _recipient) && !(isExcludedFromFee[_sender] || isExcludedFromFee[_recipient])) {
            super._transfer(_sender, feeRecipient, tFee.mul(operationFee).div(liquidityFee.add(operationFee)));
            super._transfer(_sender, address(this), tFee.sub(tFee.mul(operationFee).div(liquidityFee.add(operationFee))));
            _amount -= tFee;
        }
        super._transfer(_sender, _recipient, _amount);
    }

    /**
     Buyback WBNB and supply to liquidity
     */

    function swapAndLiquify() public {
        if (inSwap) return;
        inSwap = true;

        uint256 collectedTaxes = balanceOf(address(this));

        // split the contract balance into halves
        uint256 half = collectedTaxes.div(2);
        
        if (address(this).balance > 0) payable(feeRecipient).transfer(address(this).balance);

        // swap tokens for BNB
        _swapTokensForETH(half);

        // add liquidity
        _addLiquidity(half, address(this).balance);

        inSwap = false;
    }

    function _swapTokensForETH(uint256 tokenAmount) private {
        if (tokenAmount == 0) return;

        // Generate the uniswap pair path of token -> WETH
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IUniswapV2Router02(unirouter).WETH();

        _approve(address(this), address(unirouter), tokenAmount);

        // Make the swap
        IUniswapV2Router02(unirouter).swapExactTokensForETH(
            tokenAmount,
            0, // Accept any amount of ETH
            path,
            address(this), // The contract
            block.timestamp.add(180)
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // Approve token transfer to cover all possible scenarios
        _approve(address(this), address(unirouter), tokenAmount);

        // Add the liquidity
        IUniswapV2Router02(unirouter).addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // Slippage is unavoidable
            0, // Slippage is unavoidable
            address(this),
            block.timestamp
        );
    }

    function _isTrading(address _sender, address _recipient)
        internal view
        returns (bool)
    {
        address pair = IUniswapV2Factory(IUniswapV2Router02(unirouter).factory()).getPair(address(this), IUniswapV2Router02(unirouter).WETH());

        if (pair == address(0)) return false; // There is no liquidity yet

        if (_sender == pair && _recipient != unirouter) return true; // Sell Case

        if (_recipient == pair) return true; // Sell Case

        return false;
    }

    //to recieve ETH from unirouter when swaping
    receive() external payable {}
}