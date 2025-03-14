// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {LibString} from "solady/src/utils/LibString.sol";

import {AccessManager} from "../../src/modules/AccessManager.sol";
import {AggregationRouter, RouterPayload} from "../../src/modules/aggregator/AggregationRouter.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;
import "src/Constants.sol" as Constants;
import "src/Errors.sol";

using {TokenType.intoToken} for address;

contract AggregationRouterTest is Test {
    using LibString for uint256;

    AggregationRouter public router;
    AccessManager public accessManagerImplementation;
    AccessManager public accessManager;

    Token constant WETH = Token.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    Token constant USDC = Token.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    Token constant GRT = Token.wrap(0xc944E90C64B2c07662A292be6244BDf05Cda44a7);
    Token constant USDT = Token.wrap(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    Token constant STETH = Token.wrap(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant OPENOCEAN_ROUTER = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    address payable constant ROUTER_ADDRESS = payable(address(0x1234567890123456789012345678901234567890));

    bytes constant WETH_STETH_PAYLOAD =
        hex"e2c95c82000000000000000000000000a73d0a3fcd77bbb4d2148e25abc32bfa7aae24a1000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000dbd4b173c96142b08000000000000003b6d03404028daac072e492d34a3afdbef0ba7e35d8b55c49432a17f";

    address public owner = makeAddr("owner");
    address public account = 0xa73d0a3fcd77BbB4D2148e25aBc32BFA7aAe24A1;

    uint256 public arbitrumFork;
    uint256 public mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork(vm.rpcUrl("mainnet"), 20963318);
        arbitrumFork = vm.createFork(vm.rpcUrl("arbitrum"));

        accessManagerImplementation = new AccessManager();
        bytes memory encodedArgs = abi.encode(owner);
        address accessManagerAddress = LibClone.clone(address(accessManagerImplementation), encodedArgs);
        accessManager = AccessManager(accessManagerAddress);
        accessManager.initializeOwner(owner);

        address[] memory initialRouters = new address[](2);
        initialRouters[0] = ONEINCH_ROUTER;
        initialRouters[1] = OPENOCEAN_ROUTER;

        deployCodeTo(
            "src/modules/aggregator/AggregationRouter.sol",
            abi.encode(address(accessManager), initialRouters),
            ROUTER_ADDRESS
        );
        router = AggregationRouter(ROUTER_ADDRESS);
        uint256 roleId = Constants.DEV_ROLE;
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AggregationRouter.addRouter.selector;
        selectors[1] = AggregationRouter.removeRouter.selector;

        vm.startPrank(owner);
        accessManager.grantRoles(address(this), roleId);
        accessManager.grantTargetFunctionRoles(address(router), selectors, roleId);
        vm.stopPrank();
        vm.makePersistent(address(router));
    }

    function test_SwapOpenOcean() public {
        vm.selectFork(arbitrumFork);
        vm.warp(block.timestamp + 5);
        vm.roll(block.number + 5);
        Token weth = Token.wrap(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        Token wsteth = Token.wrap(0x5979D7b546E38E414F7E9822514be443A4800529);
        uint256 amount = 5 ether;

        deal(weth.unwrap(), address(this), amount);
        weth.erc20().approve(address(router), amount);

        bytes memory payload = _getOpenOceanData(weth, wsteth, amount, address(this), 5);
        RouterPayload memory data = RouterPayload({router: OPENOCEAN_ROUTER, payload: payload});

        uint256 balanceBefore = wsteth.erc20().balanceOf(address(this));
        uint256 returnAmount = router.swap(weth, wsteth, 5 ether, address(this), data);
        uint256 balanceAfter = wsteth.erc20().balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, returnAmount, "WSTETH balance should increase");
    }

    function test_SwapWETHToSTETH() public {
        vm.selectFork(mainnetFork);
        uint256 amountIn = 1 ether;
        vm.startPrank(account);
        address receiver = address(account);

        deal(WETH.unwrap(), address(account), amountIn);

        WETH.erc20().approve(address(router), amountIn);

        RouterPayload memory oneInchSwapData = RouterPayload({router: ONEINCH_ROUTER, payload: WETH_STETH_PAYLOAD});

        uint256 balanceBefore = STETH.erc20().balanceOf(receiver);

        uint256 returnAmount = router.swap(WETH, STETH, amountIn, receiver, oneInchSwapData);

        uint256 balanceAfter = STETH.erc20().balanceOf(receiver);

        assertEq(balanceAfter - balanceBefore, returnAmount, "Return amount should match balance increase");
        vm.stopPrank();
    }

    function test_AddAndRemoveRouter() public {
        address newRouter = address(0x123);

        // Add new router
        router.addRouter(newRouter);
        assertTrue(router.s_routers(newRouter), "New router should be added");

        //Remove router
        router.removeRouter(newRouter);
        assertFalse(router.s_routers(newRouter), "Router should be removed");
    }

    function test_RevertWhen_UnsupportedRouter() public {
        RouterPayload memory badPayload = RouterPayload({router: address(0x123), payload: WETH_STETH_PAYLOAD});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        router.swap(WETH, STETH, 1e18, account, badPayload);
    }

    function test_RevertWhen_InsufficientMsgValue() public {
        vm.expectRevert(Errors.AggregationRouter_InvalidMsgValue.selector);
        router.swap{value: 1 ether - 1 wei}(
            Token.wrap(Constants.NATIVE_ETH),
            STETH,
            1 ether,
            account,
            RouterPayload({router: ONEINCH_ROUTER, payload: WETH_STETH_PAYLOAD})
        );
    }

    function test_RevertWhen_SwapFailed() public {
        vm.skip(true);
    }

    function test_RevertWhen_ZeroReturn() public {
        vm.skip(true);
    }

    function uint256ToStringFloat(uint256 num, uint8 decimals) private pure returns (string memory) {
        uint256 leftPart = num / 10 ** decimals;
        uint256 rightPart = num % 10 ** decimals;
        uint256 rightPartLength = bytes(rightPart.toString()).length;

        string memory leadingZero = "";
        for (uint256 i = 0; i < decimals - rightPartLength; i++) {
            leadingZero = string(abi.encodePacked(leadingZero, "0"));
        }

        return string(abi.encodePacked(leftPart.toString(), ".", leadingZero, rightPart.toString()));
    }

    // OpenOcean
    function _getOpenOceanData(Token fromToken, Token toToken, uint256 amount, address fromAddress, uint256 slippage)
        internal
        returns (bytes memory)
    {
        string memory amountStringWithoutDecimals = uint256ToStringFloat(amount, fromToken.erc20().decimals());

        string memory curlParams = "curl -s ";

        string memory quotedUrl = string.concat(
            '"',
            "https://open-api.openocean.finance/v3/arbitrum/swap_quote?inTokenAddress=",
            LibString.toHexString(uint256(uint160(fromToken.unwrap())), 20),
            "&outTokenAddress=",
            LibString.toHexString(uint256(uint160(toToken.unwrap())), 20),
            "&amount=",
            amountStringWithoutDecimals,
            "&slippage=",
            slippage.toString(),
            "&account=",
            LibString.toHexString(uint256(uint160(fromAddress)), 20),
            "&gasPrice=1&disabledDexIds=2,14",
            '"'
        );

        string memory jqParams = " | jq -r .data.data";

        console.log(string.concat(curlParams, quotedUrl, jqParams));

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(curlParams, quotedUrl, jqParams);

        return vm.ffi(inputs);
    }

    receive() external payable {}
}
