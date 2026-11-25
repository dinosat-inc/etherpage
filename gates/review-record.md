# Review record

The record has two parts, because a file cannot hold the hash of the commit that contains it.

- Part 1, the build, is committed with the code. Its values are taken from the build of the tree that is
  about to be committed, which builds the same bytes as the commit, and are checked again on a clean
  checkout of the commit before sign-off. Gate G-43 of `gates/gates.py` at sign-off reads the three source
  sha256 values, the six build hashes, their byte counts, the sizes, the immutable ranges and the output of
  `forge --version` from this part, and `gates/deployed.py` on deploy day reads the six build hashes and the
  output of `forge --version`.
- Part 2, the signed part, is written after the commit is made: the commit hash, the output of the gates,
  the reviews, the sign-off, the deployer and its expected nonce. Its template is below. The filled copy is
  signed and kept outside the repository tree.

A value of Part 1 that depends on the build is final only when it equals the value taken from a clean
checkout of the signed-off commit, rebuilt with `forge clean && forge build --sizes` in a shell with no
`FOUNDRY_` or `DAPP_` variable set. A value taken from any other tree is not a value of the signed-off
build.

## Part 1. The build

Draft: the values below come from the default profile build of a fresh copy of the working tree of the
Etherpage contracts, not yet committed, made on 1 November 2026 with forge 1.8.7 (commit `985eeea`), no
build output present and no `FOUNDRY_` or `DAPP_` variable set. Its sources, libraries and `foundry.toml`
are those of the working tree, and its three sources have the sha256 values in the first table. The
`forge --version` row is the build that `foundryup --install v1.8.7` installs on a Mac with Apple silicon
(DEPLOY.md, "Before deploy day" item 1).

### Sources and toolchain

| Item | Value |
| --- | --- |
| `src/PageNFT.sol` | sha256 `8133711ef6a42caddff7f51b427afe23740fbf32a3c1b62527477751124850be` |
| `src/PageCard.sol` | sha256 `fdd8d2b8c6542f3d9022a7b66e0feb3330062fb16f57ddaa679ae44506c96494` |
| `src/SubpageRegistrar.sol` | sha256 `e5d16f8484283587ffea447032553a1fec0277bc62203c3036463cc035ef2905` |
| `forge --version` | `forge Version: 1.8.7`, `Commit SHA: 985eeea031d79922cd654d4e94e6c3701e1c7d73`, `Build Timestamp: 2026-10-29T15:03:05.234633000Z (1793286185)`, `Build Profile: dist` |
| Compiler | solc `0.8.38+commit.1835d247`, optimizer on with 200 runs, `viaIR` true, `evmVersion` `prague`, `bytecodeHash` `ipfs`, CBOR metadata appended |
| Library trees | the git tree of each folder, which gate G-28 checks: `lib/forge-std` `fdebd8d87fdd3939cb7e1d1b1b5f3d528d7e9aba`, `lib/solady` `5f5c62dc0f41c8e53d73d5e6462bc9ed3cf1103c`, `lib/soledge` `ef8e1038ed7bed3b25978d2d236e67c5a104ae99` |

### Build hashes

keccak256 of `bytecode.object` and of `deployedBytecode.object` in `out/<Contract>.sol/<Contract>.json`,
metadata included. The deployed objects are hashed as built, with their immutable ranges zero.

| Contract | Field | Bytes | keccak256 |
| --- | --- | --- | --- |
| `PageCard` | `bytecode.object` | 24,155 | `0xd3386b4bda3efc637fe000a96087242ff90679af6c02e03afc3a70ea5a5ce88a` |
| `PageCard` | `deployedBytecode.object` | 24,129 | `0x7a70800de7a89e4834c7907286272e56c9fbdbf195b55c43dc690058ac9c0a6b` |
| `PageNFT` | `bytecode.object` | 24,818 | `0x6805ef18a8fc53092015403e40e5554cc0b5c7a7bf8eb53f4cfd34409159839c` |
| `PageNFT` | `deployedBytecode.object` | 24,395 | `0x4e87a6b98e69749e31b5cd788cefda656454ffeb075b7ce26da7218ea4ac9df7` |
| `SubpageRegistrar` | `bytecode.object` | 6,402 | `0x3a10d06de459ecee74b42189903b7fb370d66546d1f17a5b145095ce88a8ca71` |
| `SubpageRegistrar` | `deployedBytecode.object` | 6,214 | `0x5bcb7278c48845da22b8745df0475f83179ac51721abf0854b49090e9328daf7` |

### Sizes

From `forge build --sizes`. The limits are 24,576 bytes of runtime code and 49,152 bytes of initcode.

| Contract | Runtime bytes | Runtime margin | Initcode bytes | Initcode margin |
| --- | --- | --- | --- | --- |
| `PageCard` | 24,129 | 447 | 24,155 | 24,997 |
| `PageNFT` | 24,395 | 181 | 24,818 | 24,334 |
| `SubpageRegistrar` | 6,214 | 18,362 | 6,402 | 42,750 |

### Immutables and constructor arguments

Each range is a byte offset into `deployedBytecode.object`, from `deployedBytecode.immutableReferences`.
At deployment each range holds the constructor argument, an address left padded to 32 bytes.
`gates/deployed.py` fills the ranges with the expected addresses before it compares the deployed code.

| Contract | Constructor argument | Immutable | Ranges, 32 bytes each |
| --- | --- | --- | --- |
| `PageCard` | none | none | none |
| `PageNFT` | the `PageCard` address | `card` | 1,939 and 6,069 |
| `SubpageRegistrar` | the `PageNFT` address | `registry` | 507, 1,618, 2,300, 2,510, 3,370 and 5,260 |

The input of each deploy transaction is the `bytecode.object` above followed by the ABI encoding of the
constructor argument: nothing for `PageCard`, and one 32 byte word holding the address for the other two.
`gates/deployed.py` checks this, and that each deploy transaction is a plain CREATE by the deployer, at
the expected nonce and the two after it, in the order `PageCard`, `PageNFT`, `SubpageRegistrar`.

## Part 2. The signed part (template)

Copy this part into a file outside the repository tree once the commit to sign off exists, fill in every
value, and sign it. The deploy compares `git rev-parse HEAD` of its fresh clone with the commit hash
written here, and the deploy script reads the deployer and its expected nonce from the environment of
its run, set from the values written here. A redeploy at a new nonce adds a row to the redeploy table
and changes nothing in Part 1, so the signed-off commit stays the same.

### Commit and gates

| Item | Value |
| --- | --- |
| Repository | (to fill: the repository that holds the signed-off commit, which deploy day clones as `REPO_URL`; or the folder path of a local copy of it) |
| Signed-off commit | (to fill: the full hash `git rev-parse HEAD` prints on a clean checkout) |
| Sources at that commit | (to fill: the three sha256 values, which must equal Part 1) |
| Part 1 at that commit | (to fill: the six build hashes and the output of `forge --version` taken again from a clean checkout of the commit, and found equal to Part 1) |
| Gate run | (to fill: `python3 gates/gates.py` with no flag on a clean checkout of the commit: date, log file, number of checks, and the final line, which must be `ALL GATES PASS`) |
| Deep run | (to fill: the fuzz seed gate G-12 printed, and the number it printed as the fewest calls that went through, with its handler action, at least 100) |

### Reviews

| Review | Reviewer | Findings | Outcome per item |
| --- | --- | --- | --- |
| (to fill) | | | |

### Deployer

| Item | Value |
| --- | --- |
| Deployer address | (to fill) |
| Expected nonce | (to fill: the deployer's nonce for the `PageCard` deployment) |

The deployer is a fresh account on a Ledger, with no code and no EIP7702 delegation, used for nothing but this
deployment, on any chain, until the end of S4 of `DEPLOY.md`. Until then it only deploys, and in S3 item 7
sends 0 ETH to itself on Ethereum until its nonce there is the expected nonce plus 3: it never commits,
reveals, renews or holds a page, and pays no fee. After S4 it is an ordinary wallet of the product owner,
which also claims and manages the collection page at opensea.io. No other contract is ever deployed from it,
and it is never upgraded to a smart account, on any chain.

### Redeploys

A deployment whose checks fail after the broadcast is abandoned before any address is published. The
contracts are then deployed again from the deployer's next nonce, written here first.

| Date | Deployer, new only after S3 item 7 found code on Ethereum | New expected nonce | Why the earlier deployment was abandoned |
| --- | --- | --- | --- |
| | | | |

### Sign-off

Product owner: (to fill: name, date and the commit hash signed off)
