# Etherpage contracts

Pages on OP Mainnet. Every page is an ERC721 token that carries addresses for any chain, a profile and
a website, and can serve as a display page. The contracts have no owner, no admin key, no proxy and no upgrade
path: once deployed, nobody can change, pause or reverse them.

| Contract | What it does |
| --- | --- |
| `PageNFT` | The registry. Registration, renewal, trials, deposits, subpages, records, display pages and the token metadata. |
| `PageCard` | Draws the SVG card of a page, every letter as a shape, so a card needs no font. It holds no state and every function is `pure`. `PageNFT` fixes its address at deployment. |
| `SubpageRegistrar` | Sells subpages of a page on terms its holder sets: a price in ETH or an ERC20 token, an optional gate token, and an optional commit and reveal. |

## Deployments

Deployed on OP Mainnet (chain id 10) on 9 November 2026. The sources in `src` are the ones verified on
Etherscan and Sourcify at these addresses.

| Contract | Address |
| --- | --- |
| `PageCard` | [`0x12b8a12c1f2CDf10f40b3a60041AeA530D12bE8a`](https://optimistic.etherscan.io/address/0x12b8a12c1f2CDf10f40b3a60041AeA530D12bE8a#code) |
| `PageNFT` | [`0xCA18d91C6ec64638bFb4C1650B6a614EbE855EEB`](https://optimistic.etherscan.io/address/0xCA18d91C6ec64638bFb4C1650B6a614EbE855EEB#code) |
| `SubpageRegistrar` | [`0xbBfc833C5Fb39BBEf22190157933Aa864eA568b1`](https://optimistic.etherscan.io/address/0xbBfc833C5Fb39BBEf22190157933Aa864eA568b1#code) |

Website: [etherpage.com](https://etherpage.com).

## Page names

A page's name is a label such as `alice`, and a subpage adds one label in front of it, such as `bob.alice`.
There is no suffix and no third level.

A label has 1 to 63 characters from `a` to `z`, `0` to `9` and the hyphen. `A` to `Z` are lowercased.
A hyphen may not come first or last, nor in both the third and the fourth place, and a label that reads
as an Ethereum address (`0x` and 40 hexadecimal characters) is refused.

The token id is a namehash under the root `keccak256("etherpage.root.v1")`. `computeId("bob.alice")`
gives the id of any name, and `normalize` lowercases and checks a label.

## Registering and the deposit

Registration takes two steps, so nobody can see which name is being registered and take it first. Call `commit` with
`makeCommitment(label, owner, referrerId, secret)`, wait at least 20 seconds and at most one day, then
call `reveal` with the same values and the price from `quote`. Anyone may pay, and the page goes to
`owner`. Anything paid above the price is sent back.

The reveal shows the label, so it is safe only when it lands at once and succeeds. Send it within 23
hours: a reveal that reverts or lands after the day makes the label, owner, referrer and secret public,
and a watcher that commits at once can reveal twenty seconds later. A reveal whose arguments are public
before it lands, such as a multisig proposal waiting for signatures or a message or deposit from
Ethereum, can be taken the same way, so a multisig should have a personal account on OP Mainnet commit
and reveal with the multisig as `owner`.

No label is reserved, and `getPremium` is zero for a page that was never registered, so the first
registration of every label costs only its fee: first come, first served.

| Label length | Yearly fee |
| --- | --- |
| 1 or 2 | 0.01 ETH |
| 3 or 4 | 0.001 ETH |
| 5 or more | 0.0001 ETH |

Every yearly fee paid for a page is added to the page's deposit (`depositOf`). The deposit stays with
the page:

- Anyone may `renew` a page before its grace period ends. Each renewal adds one year and pays one more
  yearly fee into the deposit. The expiry may be at most 3650 days ahead. `renew` takes only the token
  id, and a page keeps its id whoever registers it, so a renewal that lands after someone else registered
  the page renews theirs and pays into their deposit.
- After expiry a page with a deposit has a 90 day grace period. It stops answering and cannot move, but it
  can still be renewed and nobody else can register it.
- After the grace period anyone may register the page again. During the 21 day premium period that
  follows, the new registrant pays the deposit taken over to the last payee, plus a premium that falls
  from 10 ETH to zero over those 21 days. The last payee gets 75 percent of the premium and the payee of
  the last registration's referrer gets 25 percent, which goes to the dead address instead when that
  referrer is not a top level page.
- Once the premium period is over, the whole deposit goes back to the page's payee. Anyone may call
  `release` for that, and the next registration or trial of the page does it by itself first, so it
  costs only the yearly fee or the trial price.

The payee is the main address the current holder saved, or the holder itself when it saved none. It
still counts after expiry, when the page can no longer move and its main address can no longer change.
Money is credited to `owed`, and `withdraw(account)` sends an account everything credited to it. Anyone
may call it for any account. It sends ETH from inside a contract call, which an exchange deposit address
may never credit, so never make one a main address.

A registration may name a referrer, the id of another top level page. It is part of the commitment and
cannot be the page itself. The referrer earns nothing at registration; it is recorded so that its payee
receives 25 percent of any premium paid when the page is next registered after a lapse.

## Trials

`revealTrial` registers a page for 14 days for a tenth of the yearly fee. It has its own commitment: the
same four values as `makeCommitment` with a trial flag added, that is
`keccak256(abi.encode(label in lowercase, owner, referrerId, secret, true))`. So a commitment for a paid
year can never be revealed as a trial, and someone who has only seen a paid commitment cannot work out
the trial one. The money is held for the account that paid it and is always credited back to that
account: when the trial is renewed, when `release` is called after it ends, or when the page is
registered again.

During a trial the page works like any other, with three limits: it has no grace period, it cannot have
subpages, and it can move only to the dead address. A renewal before the end makes it a normal page
that expires one year after the trial would have ended. A trial is refused while a paid page is live,
in grace or in its premium period, and for 14 days after the page's last registration ended. After the
premium period a trial first sends any deposit left in the page back to its payee. A paid registration
is open at once.

## Addresses

`setAddr` sets the main address, which is the address on OP Mainnet. `setAddrForCoin` sets the address
for any other chain by its coin type. An address counts only while the account that saved it holds the
page. After a transfer to an account that saved nothing in this registration, the main address is the new
holder and no other chain answers anything until it saves its own addresses. When a page comes back to an
account that held it before in the same registration, each address that account saved counts again unless
another holder has since written that coin type or the main address, zero or empty included; `clearRecords`
by any holder, a new registration or a new subpage mint retires them all for good. So a contract that holds
pages for different people over time must call `clearRecords`, or save again, each time it receives one, or
its save for an earlier depositor points the page at that depositor and pays it.

The coin type `0x80000000` is the default address for every EVM chain. The holder may save it with
`setAddrForCoin` like any other chain, and it counts only while the account that saved it holds the page.
An EVM chain other than OP answers the address the holder saved for that chain, else the saved default,
else nothing. OP always answers the main address. No answer is ever computed from the code at an address:
a page answers on another chain only what its holder saved, so an account with no code, an EIP7702
delegation, a smart account deployed or not yet deployed, or the alias of an Ethereum contract on OP
Mainnet is never published on a chain its holder did not choose. Saving the default announces the coin
type 60 answer it implies, and it never moves the main address, the payee or a display page.

Save a default only for an address you control on every EVM chain, such as an account with a key or one that
a deterministic deployment can recreate at the same address on any chain: every EVM chain without its own
entry, future chains included, answers it. Saving zero for one chain clears that entry, which then falls back
to the default. To answer only some chains, leave the default empty and save one entry per chain. An app
that registers a page for an account with the same address on every chain should have the holder save the
default right after, in the same wallet batch where the wallet can batch: only the holder can save it, and
`multicall` is not payable, so it cannot hold the paying `reveal`.

`addr(bytes32)` gives the same answer as `addr(node, 60)`, the address of coin type 60, and `AddrChanged`
carries that answer, always right after the `AddressChanged` of coin type 60. The main address on OP Mainnet
is `resolve(id)` and `addr(id, 0x8000000a)`, announced by `AddressChanged` of coin type `0x8000000a`.

`clearRecords` clears every address, text, website and data record at once.

`addressesUpdatedAt(id)` is the time of the latest `setAddr`, `setAddrForCoin` or `clearRecords` of the page,
or zero. `holderSince(id)` is the time of its latest mint, or of its latest transfer to another account, or
zero; a subpage keeps it when its parent is registered again. A wallet can warn before a payment when either
is recent, treating `addressesUpdatedAt >= holderSince` as an address change by the current holder. These
writes store the block time in `addressesUpdatedAt`, and mints and transfers store it in `holderSince`. A gas
estimate made in the block of the page's last write to the same field is about 2,800 gas short a block later.
Batch the writes for a page in one `multicall`, and send every write, not only these, with about 25 percent
more gas than its estimate, so a write whose cost grows is never left out. From a smart account (ERC-4337) the
headroom belongs on the user operation's `callGasLimit`, which the wallet or bundler sets. A fixed buffer of
about 2,800 is too tight there: the shortfall measured on `callGasLimit` is 2,844 gas, or 2,889 behind an
ERC-1167 proxy, so add 25 percent to `callGasLimit` too.

Events. `AddressChanged` carries the answer at the moment it is emitted. A save announces the coin type it
saves (a save of the default also announces coin type 60), and a transfer, a mint or a change of the main
address announces only OP and coin type 60. Some answers change with no event of their own. Every coin type,
OP and 60 included, goes empty at expiry and comes back on a renewal in grace, which emits `PageRenewed` and no
address event; a subpage does the same when its parent expires or is renewed, and goes empty when its parent is
registered again, with events only for the parent. The answers for every coin type but OP and 60,
`0x80000000` included, also change with no event on a transfer, a new registration or subpage mint and
`clearRecords`, and for every EVM chain without its own entry when the default is saved. The code at an
address never changes an answer. An indexer must read `addr` live, or read it again for every coin type it
shows after each `Transfer`, `VersionChanged`, `AddrChanged`, `PageRenewed` or default save of the page or of
its parent, and at its expiry, and never carry entries over from an earlier holder. Data records, text and the
website also change with no `DataChanged`, `TextChanged` or `ContenthashChanged`: they go empty on a transfer,
a new registration or subpage mint, `clearRecords`, a send to the dead address and at expiry, and can come back
on a renewal in grace or when the page returns to the account that saved them. Read `data`, `text` and
`contenthash` live, or read them again after each `Transfer`, `VersionChanged`, `ProfileWriterChanged` or
`PageRenewed` of the page or of its parent, and at its expiry.

## Profile and website

Text records (`setText`) and the website (`setContenthash`) form the page's profile. A profile counts
only while the account that wrote it holds the page. After a transfer the profile reads empty. It counts
again only when the page comes back to the account that wrote it while no other holder has called
`keepProfile` or written a field, and nobody has called `clearRecords`, registered the page again or minted the
subpage again since; after a `clearRecords` the profile stays empty even though `profileWriter` may still name
its writer. The new
holder either calls `keepProfile` to take the profile it found as its own, or writes a field, which
starts a new empty profile. `profileWriter` tells which account's profile counts.

## Data records

`setData(id, key, value)` saves raw bytes under a key and `data(node, key)` reads them, empty unless the
page is active. A data record follows the rule of addresses: it counts only while the account that saved it
holds the page, so it never carries over to a new holder and `keepProfile` does not bring it back.
`clearRecords`, a new registration and a new subpage mint empty it. `setData` emits `DataChanged`, whose value
is indexed, so apps read the value with `data`.

## Display pages

`setPrimaryPage(id)` chooses the caller's display page; the caller must hold the page or be its main
address. `reverseResolve(address)` shows its name only while the page is active, is still held by the
account that held it when it was chosen, and still points at the address. A transfer clears the
sender's display page when it is the page that moves.

## Subpages

The holder of a live, paid top level page creates subpages with `registerSubpage` or
`registerSubpageFor`, and may replace any subpage. A subpage follows its parent's expiry and grace
period, and it becomes invalid when the parent is registered again.

The holder may pick one subpage minter with `setSubpageMinter`. The minter only creates free
subpages, and it counts only while the account that picked it holds the parent in the same
registration. After the parent moves, the account that picked it may only clear it.

A page sent to the dead address is deleted: it answers nothing, shows Invalid and cannot move. A subpage is
then free to be created again, while its parent is live, paid and not held by the dead address. A top level
page stays registered until its expiry and grace period end, and anyone may still renew it; its payee is the
dead address, so its deposit, its renewal fees and the last payee's share of a premium are burned. Its
subpages keep answering until its expiry, but nobody can create or replace subpages under it, so sending a
parent to the dead address does not revoke its subpages: to revoke them, mint each one again first. A trial
sent to the dead address is free again when the trial ends, unless someone renews it before then.

The description in a subpage's metadata ends with `This subpage relies on <parent>'s holder, who can take it
away.` A subpage's metadata never shows when it ends: read `expiresAt(parentOf(id))`.

## Transfers and receiving

A page moves only while it is active; a top level page in its grace period cannot move. `approve` and
`transferFrom` refuse ETH. They also refuse the zero address as the caller, and so does a subpage mint
by anyone but the parent's holder: the ERC721 library skips its approval checks for that caller, and only
a protocol fixed transaction, such as an OP network upgrade transaction, can come from it. A new page
minted to a contract must be accepted by its `onERC721Received`, unless the contract is the caller itself
or a key wallet: an account with no code or with an EIP7702 delegation. This is the only use of the key
wallet test; no address answer depends on it.

`multicall` runs several calls on `PageNFT` in order, as the same caller and with their own checks.
It is not payable, and the first failure reverts them all with its revert data.

`status(id)` returns what the metadata shows: Active, Grace, Expired, Invalid or Trial.

## SubpageRegistrar

A holder sets the terms with `configure` and picks the registrar as the subpage minter in `PageNFT`.
Buyers call `registerSubpage`, or `commitSubpage` and `revealSubpage` when the terms ask for commit and
reveal, and pass the highest price and the fee token they accept, so the terms cannot change under
them. The terms sell only while the holder who set them holds the page in the same registration and
keeps the registrar as its minter. When a gate token is set, the buyer must hold its minimum balance.
ETH proceeds are credited to the payout and claimed with `claimProceeds` or `claimProceedsFor`; a token
price goes from the buyer straight to the payout.

The registrar never moves a page, and every mint or safe transfer into it reverts. A plain
`transferFrom` by a holder or an approved account can still leave a page with it, and nothing can move
that page out again. Never send a page to the registrar.

## Build and test

Built with [Foundry](https://getfoundry.sh). The libraries are vendored in `lib` (solady, soledge and
forge-std). The default profile holds the deploy settings: solc 0.8.38, EVM version prague, optimizer
with 200 runs and the IR pipeline.

```sh
forge build
forge test
```

A plain `forge test` runs a fuzz test 256 times and an invariant campaign for 64 runs of 64 calls.
The full campaigns run a fuzz test 1000 times and an invariant campaign for 512 runs of 256 calls,
which takes hours:

```sh
FOUNDRY_PROFILE=deep forge test
```

A test may set its own count in a `forge-config` comment above it, and then that count applies instead,
under both profiles: the walks of `DeletedDifferentialTest`, `ClearPrimaryDifferentialTest` and
`MulticallDifferentialTest` run 100 times and their focused walks 200 times, `RegistrarModelWalkTest`
1500 times, `MinterAuthWalkTest` 1000 times, `LedgerRulesWalkTest` 128 times and 512 times under the
deep profile, and the card fuzz tests of `CardBoundFuzzTest` and `CardAnyTextTest` 5000 times. The two
invariants of `RegistrarInvariantTest` drive the registrar through a handler that lets a failed registrar
call revert, with no try or catch, so they turn `fail_on_revert` off, and the campaign table tells the calls
that went through from those that reverted. Gate G-42 pins these counts and the settings of both profiles.

The gas reports measure each call as its own transaction:

```sh
forge test --match-path 'test/gas/*' --isolate -vv
```

The tests are grouped by kind:

| Folder | Contents |
| --- | --- |
| `test/unit` | Behaviour of each feature, by topic. |
| `test/attack` | Attempts to break the rules: authority, reentrancy, money, display pages, trials, the mint rule. |
| `test/invariant` | Handler driven campaigns that check the whole state against a model after every call. |
| `test/differential` | The contracts against reference builds in `test/differential/harness` that each lack one feature, with every difference predicted. |
| `test/gas` | Gas of the main paths. |
| `test/utils` | Shared setup and mock contracts, and `CardReader`, which reads a card back into its name, pills and squares and checks every letter's place on the way. |
| `test/fixtures` | Files the tests read: the expected cards and the code of contracts deployed on OP Mainnet. The tests also read the card's letters from `tools/card-glyphs.json`. |

Campaign statistics and drawn cards are written to `logs`.

The tests read their fixed inputs from `test/fixtures`:

| Path | Contents |
| --- | --- |
| `cards/*.svg` | The expected card of eleven states: a top level page active, in a trial, renewed out of a trial, in grace, expired, and after its trial ended, and a subpage active, in grace, expired, invalid and deleted. `test/unit/cards/Cards.t.sol` draws each state and compares the SVG byte for byte; the drawn cards go to `logs/cards`. A deleted top level page has no file here: `Cards.t.sol` and `TrialCardBytes.t.sol` compare its card with `PageCard.render` for an invalid page with no parent. |
| `safe141/*.hex` | The runtime code of the Safe 1.4.1 contracts: `singleton.hex` (Safe), `singletonL2.hex` (SafeL2), `factory.hex` (SafeProxyFactory) and `fallback.hex` (CompatibilityFallbackHandler). `test/unit/deploy/RealSafe.t.sol` puts each at its canonical address and builds real Safe wallets from them, with no fork. |
| `safe141/codehashes.txt` | The address and keccak256 of each of those four files. Each hash equals the code hash at that address on OP Mainnet and on Ethereum, read on 5 October 2026; the file names the blocks and RPC sources. The tests check the hash of the code they put in place. |
| `cbsw/*.hex` | The runtime code of the Coinbase Smart Wallet contracts of versions 1 and 1.1 and of the EntryPoint v0.6 they use: `factory.hex` and `factory11.hex` (CoinbaseSmartWalletFactory 1 and 1.1), `wallet.hex` and `wallet11.hex` (CoinbaseSmartWallet 1 and 1.1), `entrypoint.hex` (EntryPoint v0.6) and `sendercreator.hex` (its SenderCreator). `test/unit/deploy/RealCoinbaseWallet.t.sol` puts each at its canonical address and builds real wallets from them, run by their owner key directly and through user operations of that EntryPoint, with no fork. |
| `cbsw/codehashes.txt` | The address and keccak256 of each of those six files, and the code hash of the 61 byte proxy that every wallet of the two factories is. Each hash equals the code hash on OP Mainnet at block 159074208, read on 4 November 2026, the proxy's that of three wallets the factories made there; the file names the block and RPC sources. The tests check the hash of the code they put in place and of each wallet they make. |
| `multicall3-op.hex` | The runtime code of Multicall3 at `0xcA11bde05977b3631167028862bE2a173976CA11` on OP Mainnet. The accepted behaviour tests in `test/attack/accepted` put it at that address and check its keccak256 before using it. |

Four reference builds in `test/differential/harness` are generated from `src/PageNFT.sol`: three
that differ only in the mint rule, and `PageNFTManualRelease`, which leaves a deposit in its page after
the premium period until `release` is called:

```sh
python3 tools/make_harness.py          # write them
python3 tools/make_harness.py --check  # confirm they are current
```

The sign-off gates and the files they compare against are in `gates`. `gates/gates.py` runs them in order: the
source checks for the rules that must hold by construction (every value transfer, guards, every writer of the
money ledgers, display pages and profiles, the mint rule, event sites, low level calls), the build settings
and sizes, with the size rows of `DEPLOY.md`, the public surface, events, errors and storage layout against
the committed files, the library trees, the suite, the proof results, the gas snapshot, the coverage floor,
the campaign sizes, the source sha256 values, build hashes, sizes, immutable ranges and `forge --version`
against Part 1 of `gates/review-record.md`, and last five checks of the code itself: G-44 reads the runtime
code and the optimized IR of each contract and fails on any signature check (a call to a precompile but the
identity, the ORIGIN opcode, an ERC1271 magic value), G-45 checks that the zero address as a caller is
refused, and G-46 checks that holderSince, addressesUpdatedAt and the data records each have only their
reviewed writers, that each writer of addressesUpdatedAt sets it under no condition, and pins the body of
`addr(bytes32)`. G-47 checks that the letters `PageCard` draws are exactly the ones `tools/card-glyphs.json`
holds, that the JSON was made from the website's own font files, and that the letter numbers in the contract
are the places of the letters in the JSON. G-48 runs the searches of `test/svgCard.test.ts` over the small
text of that JSON: for the parents that draw the most bytes in the left pill of an active subpage card, with
and without the ellipsis, and for the code that draws the most bytes in the right pill. It checks that
`PageCard` draws both pills as the searches count them and each square of the grid once whatever its colour,
that the size tests name those parents and draw their widest cards with an id of that code (`WIDEST_ID`), that
the x, the width and the text x of every code pill have three digits, that the widest left pill ends before
the widest code pill starts, and that no parent makes the metadata of an active subpage of 63 eights with that
id larger than `MetadataSize.t.sol` allows. G-49 builds the three contracts alone with every compiler warning
shown (forge hides some kinds by default) and checks that none comes from `src` and that the rest are exactly the
121 known warnings of the vendored solady and soledge files: notices for features Solidity 0.9 removes (the
memory-safe assembly comment, virtual modifiers) and one that transient storage is used. None changes the code
0.8.38 makes, and the libraries stay byte for byte their upstream files. The script builds in `out` and `cache`, so run it on a clean
checkout in a shell with no `FOUNDRY_` or `DAPP_` variable set. `tools/gates.py` runs the same script. The
deep run of gate G-12 uses a fixed fuzz seed, which it prints, and checks that every handler action of every
invariant campaign went through at least 100 times, reverted and discarded calls not counted.

```sh
python3 gates/gates.py                       # every gate
python3 gates/gates.py --list                # the gates and their numbers
python3 gates/gates.py --only G-24,G-30      # some of them
python3 gates/gates.py --no-deep             # without the full campaigns
```

| File | Contents |
| --- | --- |
| `gates/<Contract>.methodIdentifiers.json`, `.events.json`, `.errors.json` | The public surface of each contract. |
| `gates/<Contract>.storage-layout.json` | The storage layout of each contract, without AST ids. |
| `gates/<Contract>.declarations.txt` | The errors and events each source file declares. |
| `gates/equivalent-mutants.md` | Surviving mutants and unreachable branches, each with its reason. |
| `gates/proof-results.json` | The Halmos result of every tier proof and the hashes of the files they depend on. |
| `gates/review-record.md` | Part 1, the build values the deploy checks against, committed with the code. Part 2, the template of the signed part: the commit, the gate output, the reviews, the sign-off, and the deployer and its nonce, filled in after the commit and kept outside the repository. |

`gates/record.py` writes the compared files from the current build. A change to any of them is a
change of the public surface or the storage of a contract that can never change, and is reviewed as
such.

The gas snapshot uses a fixed fuzz seed. Its fuzz figures repeat only from a clean build, so it is
written after `forge clean`. The check is gate G-14: it runs `forge clean`, writes a fresh snapshot with
the same seed and compares it with `.gas-snapshot` byte for byte, fuzz and invariant lines included.
One number is left out: the revert count of the two `RegistrarInvariantTest` campaigns, the only ones
with fail-on-revert off. Forge 1.8.7 does not repeat an invariant campaign call for call under a fixed
seed, and only a count of reverted calls shows it (five clean runs of the same tree gave 2785 to 2797).
`forge snapshot --check` is not the gate. It compares only the tests that already have a line, and of
each only the gas of a unit test or the median of a fuzz test: a test with no line fails it, while a
changed run count or mean of a fuzz test, a changed invariant line and a line left for a removed test
pass it (measured with forge 1.5.1).

```sh
forge clean && forge snapshot --fuzz-seed 0x2a   # write .gas-snapshot
python3 gates/gates.py --only G-14               # the check, gate G-14
forge snapshot --fuzz-seed 0x2a --check          # a partial comparison, not the gate
```

`tools/bytecode.sh` builds the contracts with the deploy settings but without the metadata hash, and
prints the size and sha256 of their code. Comments change the metadata hash but not these values.
`tools/sum_stats.py` adds up the per run statistics a campaign writes to `logs`.
`tools/card_glyphs.py` makes the letters of the card from the website's fonts, kept in `tools/fonts`: it writes
`tools/card-glyphs.json` and the six letter constants of `PageCard.sol`, and with `--check` confirms both are
current. It needs fontTools; gate G-47 checks the constants against the JSON with Python alone.

```sh
python3 -m venv /tmp/glyphs && /tmp/glyphs/bin/pip install fonttools==4.60.2 brotli==1.2.1
/tmp/glyphs/bin/python tools/card_glyphs.py --check
```

## Deploy

`DEPLOY.md` is the deploy checklist: building the signed-off commit, the broadcast, the check of the
deployed code and publishing the addresses, with the local rehearsal on a plain anvil node that comes first.

`script/Deploy.s.sol` deploys the three contracts and sends nothing else: `PageCard`, then `PageNFT`
with the card's address, then `SubpageRegistrar` with the address of `PageNFT`, each with a plain
CREATE from the deployer. It refuses any chain but OP Mainnet (10) and a local anvil chain (31337), and
any sender or nonce other than `DEPLOYER` and `EXPECTED_NONCE`, which it reads from the environment of
the run, so a redeploy at a new nonce needs no new commit. Set the two variables on the command only,
never exported in the shell that runs the tests. Until the end of S4 of `DEPLOY.md` the deployer
registers no page.

```sh
DEPLOYER=<address> EXPECTED_NONCE=<nonce> forge script script/Deploy.s.sol --rpc-url <OP Mainnet RPC> \
  --ledger --mnemonic-derivation-paths "<derivation path>" --sender <address> --broadcast --slow
```

`--ledger` signs on the deployer's Ledger at that derivation path, as `DEPLOY.md` does. An encrypted
keystore works too, with `--account <keystore>` in place of the two Ledger options. `--sender` makes forge
run the script as the deployer: with a Ledger or a keystore and no `--sender`, forge runs it as its default
sender, which the script refuses. The script has not been run with a Ledger. `--slow` sends each
transaction only after the one before it is mined. Take the three transaction hashes from the chain, by
the deployer's nonces, rather than from the broadcast record alone.

After the broadcast, `gates/deployed.py` (gate G-20) rebuilds, compares the six build hashes with the
review record, checks that each deploy transaction is a plain CREATE by the deployer at the expected
nonce and the two after it, with the creation code of the build and its constructor argument as input,
and compares the code at the three addresses with the build, byte for byte, from two RPC sources at a
final block. A transaction hash given for the wrong contract fails these checks. Last it checks that
`PageNFT` held no page for the registrar at the block that created the registrar: before that block the
address had no code, so a mint or a safe transfer naming it would have gone through. A page sent to the
registrar with a plain `transferFrom` later in that block counts too, and `DEPLOY.md` abandons the
deployment either way. `--wait` lets it start at once and wait until the finalized block holds the
deployment.

```sh
python3 gates/deployed.py --commit <hash> --card <address> --nft <address> --registrar <address> \
  --card-tx <hash> --nft-tx <hash> --registrar-tx <hash> --deployer <address> --nonce <expected nonce> \
  --rpc <OP Mainnet RPC> --rpc <another OP Mainnet RPC> --wait 3600
```

For the rehearsal it takes `--rehearsal --chain-id 31337 --block latest`, and two addresses of the one
local node, such as `http://127.0.0.1:8545` and `http://localhost:8545`.

Once G-20 passes, the deployer sends 0 ETH to itself on Ethereum until its nonce there equals its nonce on
OP Mainnet (S3 item 7 of `DEPLOY.md`). Until then its key could put other code at the three addresses on
Ethereum, and a deposit from that code could act on OP Mainnet as the contracts once Ethereum lets a
contract start its own transaction (EIP-8141, a draft), for example to send away the ETH `PageNFT` holds.

## Proofs

The `proofs` folder holds symbolic proofs for [Halmos](https://github.com/a16z/halmos). They build
with their own profile, with the optimizer off and separate output folders, so they never mix with the
deploy build.

```sh
FOUNDRY_PROFILE=proofs forge build
tools/proofs/run_queue.sh tools/proofs/tier1.txt 4    # a tier, four at a time; also tier2.txt to tier4.txt
tools/proofs/run_one.sh <tag> <Contract> <function> <seconds> [loop bound]
python3 tools/proofs/collect.py                       # one table of every result
python3 gates/gates.py --record-proofs logs/halmos    # record the results for gate G-13
```

Every proof is listed in one of `tools/proofs/tier1.txt` to `tier4.txt`, with its time limit, or in
`tools/proofs/umbrella.txt`. `umbrella.txt` lists combined proofs that are proven in parts in the tier files, and,
at its end, the proofs of `proofs/wide` that have no recorded PASS, each group with its reason; running them is
optional. `tier4.txt` holds the wide proofs of `proofs/wide` (see Further checks of 6 November 2026).

Each proof runs under a time limit with its own solver scratch folder, which is deleted when it ends.
Results go to `logs/halmos`. `gates/proof-results.json` records the result of every tier proof and the
sha256 of every file the proofs depend on: the sources, every file in `proofs` and its folders, and the
harnesses they import. Gate G-13 passes when every proof function is listed once, every tier proof is recorded
as PASS and every recorded hash matches the current file. `--record-proofs` takes one or more `logs/halmos`
folders of copies of this folder, and uses a run only when its copy holds the same files, unchanged since the
run started. So a proof file cannot change, not even a comment, without its proofs running again.

Halmos 0.3.3 gives the solver 1 ms to tell two storage keys apart while it reads storage. On a busy machine
that can run out, and a proof of the default address that reads past a store under a symbolic coin type then
stops with NotConcreteError or hits the loop bound, while the same files pass on another run. A pass stays
sound; only the result can change. The tier files therefore list versions of those proofs written so that
every such read meets its store by the key alone (DA1nr, DA1r60, DA1rHi, DA2z1r to DA2z3r, DA2e1r to
DA2e3r, DA3r), each proving the same claim over the same inputs; the originals are in `umbrella.txt` with
a note. Proofs that run near the machine's limit, such as the money proof FM1rP0 and the status proofs that
draw the card, have limits well above their measured times.

Several proofs leave out address 0 as the caller, and some of their notes say that address 0 never sends a
transaction. On OP Mainnet it does: its network upgrade transactions come from it. The proofs hold for every
other caller, and the zero caller is covered on its own: `approve`, `transferFrom` and both forms of
`safeTransferFrom` refuse it (ZC1 to ZC4 in `proofs/ZeroCallerProofs.t.sol`), a subpage mint refuses it as a
minter (MPZ in `proofs/MinterProofs.t.sol`), and its every other call acts as a stranger's, as
`test/attack/ZeroCallerGuard.t.sol` and `test/attack/ZeroCallerOrder.t.sol` check.

## Further checks of 6 November 2026

Before deployment the three contracts, unchanged (the sha256 values of Part 1 of `gates/review-record.md`), went
through more checks, each on a clean copy of the signed-off sources. None found a fault in the contracts. Their logs,
and the parts not kept here, are kept with the review records outside the repository.

### Wide proofs

`proofs/wide` holds Halmos proofs that take wider inputs than the tier proofs:

- `normalize` for every byte string of 0 to 6 bytes and of 64 bytes (WLB), and self referral for labels of 1 to 6
  bytes (WRF1, WRF2s);
- `reveal` and `revealTrial` for a label of each fee class, in lower or upper case, every caller and owner the code
  can tell apart, a stored commitment that differs in any way from the call, and amounts up to 2^96 wei, with the
  exact refund, credits, deposit and held money (WRV1 to WRV4, proven in 148 pieces in `WideRevealPieces.t.sol`);
- `release`, `renew` and `withdraw` from any state at all, every storage slot symbolic (WAS1, WAS2 in 18 cases, WAS5);
- the money and routing proofs with wider amounts, the subpage minter, a registrar sale paid in ETH and in a token,
  approvals, both kinds of transfer, `commit`, `renew` and `clearRecords`.

`tools/proofs/tier4.txt` lists the 218 with a recorded PASS, and `umbrella.txt` lists every other one with its reason.
The comments of these files are as they ran: a changed file voids its results, so their dates, notes and line
numbers (of the sources above) stay, and the `extest` they name is `test/unit/naming/LabelExhaustive.t.sol`.

### What the tools could not do

- Halmos 0.3.3 stops at once on a storage slot keyed by the hash of symbolic label bytes, so a reveal of a symbolic
  label (WRV5, WRV6) cannot run. `test/unit/naming/RevealEveryShortLabel.t.sol` reveals every 1 and 2 byte label, and
  10,648 three byte labels, for real instead, as a paid page and as a trial.
- A symbolic second of the 21 day premium window did not finish. The reveal pieces take four fixed seconds of it; the
  tier proofs FM1rR and MC5p and MC5q cover the premium at every second.
- `reveal` and `revealTrial` from any state (WAS3, WAS4) did not finish: the smallest narrowed case already needs
  about 13,000 paths. The reading below covers them.

### Reveal and revealTrial from any state, by reading

Claim: one successful call of `reveal` or `revealTrial`, from any state, raises the sum of all ledgers (every `owed`,
every `depositOf`, every held trial payment) by exactly the ETH the contract keeps, and a failed call changes nothing.

Only `_credit`, `_refundTrial`, `_releaseDeposit`, `_registerTopLevel`, `renew` and `withdraw` write a ledger, and only
`_refundExcess` and `withdraw` send ETH. Every function that writes a ledger is `nonReentrant` under one guard, so the
receiver check and the refund inside a registration cannot re-enter one, and every money sum is checked arithmetic.
`_registerTopLevel` then:

1. releases a deposit left after the premium period to the payee's `owed`, so the sum stays (WAS1 proves this
   helper from any state);
2. takes `carried`, the deposit, which a trial refuses, and the premium, which is zero without a deposit, and needs
   `msg.value` of at least `total = fee + carried + premium`;
3. credits `carried` to the old payee and the premium in two shares that add up to it exactly; `_credit` writes
   nothing for zero and sends a credit for the zero address or the contract itself to the dead address, so `owed`
   rises by exactly each amount;
4. moves held trial money to its payer's `owed`, so the sum stays;
5. holds `fee` for a trial, or adds it to the deposit;
6. sends back `msg.value - total`.

So the ledgers rise by `carried + premium + fee = total`, and the contract keeps `total`. The argument never uses
who the payees are, which is what made Halmos slow. With WAS1, WAS2 and WAS5, and no other entry point writing a
ledger, the contract always holds at least the sum of all ledgers. The reveal pieces check the same steps with the
rest of the state symbolic, and the fuzz and Echidna money campaigns found no failure.

### Fuzzing

The deep campaigns ran with three more seeds, much longer walks (up to 10,000 calls), the coverage guided mode of
forge, campaigns with some actions drawn more often, and every fuzz test with up to 100,000 runs: 66,238 invariant
runs and 36.4 million handler calls, about 20 times the deep run of the gates, and 10.8 million fuzz runs, about 85
times. All passed. Four coverage guided campaigns stopped on a fault of forge 1.8.7: it sent a bool argument as a word
other than 0 or 1, which the handler's ABI decoder refuses before it calls any contract; they passed again with
argument mutation off. `test/invariant` keeps the three reweighted campaigns, `TrialInvariantRareRenew`,
`MinterInvariantMoney` and `MinterInvariantRenew`, on the suite's own handlers; the run counted the refusals of the
minter walks with a copy of `MinterHandler`, which is not kept.

### Echidna

Echidna 2.4.0 ran seven campaigns over ports of the minter, money, multicall, deleted page and registrar handlers:
12.66 million calls, about 46 worker hours, no property failed. A bug planted in a copy (a released deposit credited
to the holder instead of the payee) was found in about a minute. The saved sequences, a fixed sample of 150 of 2,375
for the deleted page campaign, passed again under Foundry. The harness is not kept here: it needs a fourth build
profile, which gate G-9 refuses.

### Static analysis

Slither and Aderyn: every finding in `src` was judged, and none is real. Neither sees the external calls Solady makes
in assembly, so their silence on reentrancy is no evidence; those calls are tested in `test/attack`. The solc
SMTChecker (CHC engine, z3 4.13.3) found nothing real; it cannot model a revert with a custom error or inline assembly.

### Left out

Not kept here: the Echidna harness and its seven campaigns' corpora; the copy of the minter handler that counted
refusals (95 KB); one test that reproduced the forge fault above; the fuzz profile with 100,000 runs; 132 any state
proof cases that never ran and 11 diagnostic proofs of that search (two narrowed cases passed); and a
Halmos runner with a longer branch timeout, whose only run did not finish.

## License

Apache License 2.0, see `LICENSE` and `NOTICE`. Parts are derived from the wei-names contracts
under the MIT License, whose notice is kept in `NOTICE`.
