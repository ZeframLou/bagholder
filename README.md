# Bagholder

Bagholder is a protocol for NFT loyalty programs.

Bagholder introduces a new design pattern called **optimistic staking**, where NFT holders can receive token rewards while keeping their NFTs in their wallets (instead of in a staking pool contract). Optimistic staking has several advantages over conventional staking:

- NFT holders can keep enjoying the benefits of holding the NFT such as accessing private groupchats while also receiving rewards.
- Each NFT can participate in multiple loyalty programs and receive the corresponding rewards, whereas conventional staking contracts only allow each NFT to be staked in one pool.
- Gas costs are lower since NFT transfers are no longer necessary.

Optimistic staking works in a similar way as optimistic rollups. At staking time, Bagholder verifies that the staker owns the NFT and optimistically assumes that it won't be transferred to another address, and the staker must deposit a "bond". If an NFT is transferred while staked into a program, the staker can be "slashed", which would give the bond to the slasher as reward and unstake the NFT from the program. The bond is denominated in ETH, and it only needs to be enough to cover the gas cost of slashing (30-50k gas). The bond is returned to the staker when an NFT is unstaked from a program.

Bagholder currently supports ERC-721 NFTs.

## Installation

To install with [DappTools](https://github.com/dapphub/dapptools):

```
dapp install zeframlou/bagholder
```

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install zeframlou/bagholder
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
make install
```

### Compilation

```
make build
```

### Testing

```
make test
```
