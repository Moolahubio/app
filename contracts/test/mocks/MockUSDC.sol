// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only USDC: 6 decimals plus the FiatToken behaviours circles depend on. While paused, transfers and
///         approvals revert; a blacklisted sender, recipient or spender makes a transfer revert. Not for production.
contract MockUSDC is ERC20 {
    mapping(address account => bool) public isBlacklisted;
    bool public paused;

    /// @notice Test-only flow ledger for invariant suites: every transfer out of / into a watched account.
    mapping(address account => bool) public watched;
    /// @notice Total sent by watched `from` to `to` (burns are `to == address(0)`).
    mapping(address from => mapping(address to => uint256 amount)) public sent;
    /// @notice Total received by watched `to` from `from` (mints are `from == address(0)`).
    mapping(address to => mapping(address from => uint256 amount)) public received;
    mapping(address from => address[] recipients) internal _recipients;
    mapping(address from => mapping(address to => bool seen)) internal _isRecipient;

    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool blacklisted) external {
        isBlacklisted[account] = blacklisted;
    }

    function setPaused(bool isPaused) external {
        paused = isPaused;
    }

    // FiatToken-style controls (Circle's `Blacklistable` / `Pausable` names).
    function blacklist(address account) external {
        isBlacklisted[account] = true;
    }

    function unBlacklist(address account) external {
        isBlacklisted[account] = false;
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    // Flow ledger (invariant suites).
    function watch(address account) external {
        watched[account] = true;
    }

    /// @notice Every address a watched account ever sent tokens to.
    function recipientsOf(address from) external view returns (address[] memory) {
        return _recipients[from];
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        require(!paused, "Pausable: paused");
        require(
            !isBlacklisted[msg.sender] && !isBlacklisted[spender], "Blacklistable: account is blacklisted"
        );
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!isBlacklisted[msg.sender], "Blacklistable: account is blacklisted");
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "Pausable: paused");
        require(!isBlacklisted[from] && !isBlacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
        if (watched[from]) {
            sent[from][to] += value;
            if (!_isRecipient[from][to]) {
                _isRecipient[from][to] = true;
                _recipients[from].push(to);
            }
        }
        if (watched[to]) received[to][from] += value;
    }
}
