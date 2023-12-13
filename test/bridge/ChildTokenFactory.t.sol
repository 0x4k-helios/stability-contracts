// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console, Vm} from "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../src/core/proxy/Proxy.sol";
import "../../src/interfaces/IChildTokenFactory.sol";
import "../../src/interfaces/IChildERC20.sol";
import "../../src/interfaces/IChildERC721.sol";
import "../../src/bridge/ChildTokenFactory.sol";
import "../../chains/PolygonLib.sol";
import "../base/MockSetup.sol";

contract ChildTokenFactoryTest is Test, MockSetup {
    ChildTokenFactory public childTokenFactory;
    address constant parentERC20Token = address(PolygonLib.TOKEN_USDT);
    address constant parentERC721Token = address(PolygonLib.TOKEN_PM);
    address bridge;

    function setUp() public {
        ChildTokenFactory implementation = new ChildTokenFactory();
        Proxy proxy = new Proxy();
        proxy.initProxy(address(implementation));
        childTokenFactory = ChildTokenFactory(address(proxy));
        childTokenFactory.initialize(address(platform));
        bridge = platform.bridge();
    }

    function testInitializeChild() public {
        ChildTokenFactory implementation = new ChildTokenFactory();
        Proxy proxy = new Proxy();
        proxy.initProxy(address(implementation));
        ChildTokenFactory factory2 = ChildTokenFactory(address(proxy));
        factory2.initialize(address(platform));
    }

    function testDeployChildERC20() public {
        address childERC20 = childTokenFactory.deployChildERC20(parentERC20Token, 1, "USDT token", "USDT", bridge);
        assertEq(childTokenFactory.getChildTokenOf(parentERC20Token), childERC20);
        assertEq(childTokenFactory.getParentTokenOf(childERC20), parentERC20Token);

        assertEq(IChildERC20(childERC20).bridge(), bridge);
        (address token, uint chainId) = IChildERC20(childERC20).parent();
        assertEq(token, address(0));
        assertEq(chainId, 0);

        vm.startPrank(bridge);
        IChildERC20(childERC20).mint(address(123), 100e18);
        assertEq(IERC20(childERC20).balanceOf(address(123)), 100e18);
        IChildERC20(childERC20).burn(address(123), 100e18);
        assertEq(IERC20(childERC20).balanceOf(address(123)), 0);
        vm.stopPrank();
    }

    function testDeployChildERC721() public {
        address childERC721 = childTokenFactory.deployChildERC721(
            parentERC721Token, 1, "Profit Maker", "PM", "https://example.com", platform.bridge()
        );
        assertEq(childTokenFactory.getChildTokenOf(parentERC721Token), childERC721);
        assertEq(childTokenFactory.getParentTokenOf(childERC721), parentERC721Token);

        assertEq(IChildERC721(childERC721).bridge(), platform.bridge());
        (address token, uint chainId) = IChildERC721(childERC721).parent();
        assertEq(token, parentERC721Token);
        assertEq(chainId, 1);

        vm.startPrank(platform.bridge());
        IChildERC721(childERC721).mint(address(123), 0);
        assertEq(IERC721(childERC721).balanceOf(address(123)), 1);
        IChildERC721(childERC721).burn(0);
        assertEq(IERC721(childERC721).balanceOf(address(123)), 0);
        vm.stopPrank();
    }
}
