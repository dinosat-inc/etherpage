# Deploy checklist

This is the list for deploying `PageCard`, `PageNFT` and `SubpageRegistrar` on OP Mainnet. It follows the
steps of R-8.79 of the specification and the review record of R-8.80. Do the steps in order. Each must pass
before the next starts, and none is optional.

The commands below were run on local test chains before they were written here: S1 to S4 on a local chain that
reports chain id 10 on 6 October 2026, and on 14 October 2026 the rehearsal of item 5 with its drill and, on a
chain that reports chain id 10, S2 item 2 with a test key, G-20 in its deploy day form and S4 items 1 and 2.
On 18 October 2026 S3 item 7 ran with a test key after S2 item 2, on two local chains that report chain ids 10
and 1 in place of OP Mainnet and Ethereum: once as written, once with too little ETH and then again, once more
after it had ended, and once for a redeploy at nonce 3. On 22 October 2026, on the Etherpage build, the
rehearsal's deploy with script/Deploy.s.sol, the wiring check of S4 item 2, G-20 in its rehearsal form and
S3 item 7 ran again with a test key on two local chains with chain ids 31337 and 1. On 7 November 2026, with
Foundry 1.8.7, the rehearsal of item 5 ran again with its drill, the lines of S2 to S4 that need no Ledger,
explorer or real chain ran with a test key on a local chain with chain id 10, and the second block of S3 item 7
ran with too little ETH, with a transaction left pending and with a provider that does not answer.
No command was run with a Ledger: S2 item 2 and S3 item 7 ran with a test key in place of the Ledger options,
and the other lines with `--ledger` have never run. The provider check and the nonce check of item 4, the explorer
checks and the source verification need the real chains and were not run. "The rehearsal" below lists what
else only deploy day shows.

N is the deployer's expected nonce, written in the signed part of the review record. It is 0 for a fresh
deployer.

## Rules for the day

- If an output differs from what the step says, stop and do only what the step says for that case. If it
  says nothing, publish nothing and write down what you saw. Never change a command or try something else.
- Nothing is announced or published before the end of S4.
- Until the end of S4 the deployer only deploys, and in S3 item 7 sends 0 ETH to itself on Ethereum: it never
  commits, reveals, renews or holds a page, and pays no fee.
- Never type a private key. The deployer signs on its Ledger, which shows each transaction for you to approve.
- Copy each block of commands whole, as it is. A long command is still one line. A command that uses the
  Ledger is always the last line of its block. Before you paste it, plug the Ledger in by USB, quit Ledger
  Wallet (formerly Ledger Live) and any other wallet app, unlock the Ledger and open its Ethereum app.
  Otherwise the command stops at once with `Could not connect to Ledger device` and sends nothing: do so and
  run that same line again.
- If you reject a transaction on the Ledger, forge asks for it again a few seconds later, up to four more
  times, and stops with `Failed to send transaction` after the fifth rejection. If you rejected it by mistake,
  approve it when it comes back. To stop a command that waits for the Ledger, press Ctrl+C, then reject what
  the Ledger shows. A transaction approved before the stop stays sent: in S2, see "S2 stops half way". In S3
  item 7, cast signs instead of forge and does not ask again: a rejection ends the block, and item 7 says
  when to paste it again.
- Paste a block only at an empty prompt, `sh-3.2$` in the deploy shell, once the block before it has ended,
  never while a command still runs: a line pasted while a command runs can be cut.
- Write nothing inside the clone of the repository. G-20 checks that it is clean.

## Before deploy day

### 1. Tools

Foundry must be the build in the `forge --version` row of Part 1 of `gates/review-record.md`: forge 1.8.7
from its v1.8.7 release, as foundryup installs it on a Mac with Apple silicon. Install it with no `anvil`
running (foundryup refuses while one runs), then check it:

```sh
foundryup --install v1.8.7
forge --version
```

`forge --version` must print the four lines of that row, in the same order: `forge Version: 1.8.7`,
`Commit SHA: 985eeea031d79922cd654d4e94e6c3701e1c7d73`,
`Build Timestamp: 2026-10-29T15:03:05.234633000Z (1793286185)` and `Build Profile: dist`. Do not use
`foundryup --install stable`: foundryup reads `stable` as the newest release, which may be a later one. foundryup switches
`forge`, `cast` and `anvil` to the build it installs. Do not run it again until the deployment is over. You
also need `git`, `python3` and `jq`, and your Ledger with its Ethereum app brought up to date in Ledger
Wallet before deploy day. Do not update the Ledger or its apps on deploy day.

### 2. The deployer

A fresh Ethereum account on your Ledger, made for this deployment: add a new Ethereum account in Ledger
Wallet that has never been used on any chain, and note the address it shows for it. Ledger Wallet shows its
path on the account's page under Edit account, then Advanced, as `freshAddressPath`, for example
`44'/60'/3'/0/0`. Its third number, here 3, is A, and the account's derivation path is `m/44'/60'/A'/0/0`.
Plug the Ledger in by USB, quit Ledger Wallet, unlock the Ledger and open its Ethereum app. Then this line,
with A in place of `<A>`, must print the same address:

```sh
cast wallet address --ledger --mnemonic-derivation-path "m/44'/60'/<A>'/0/0"
```

- Until the end of S4, use this account for nothing else, on any chain. A transaction on OP Mainnet before S2
  would change its nonce, and with it the three addresses, and a contract it created on another chain could
  sit at one of those addresses there. After S4 it is an ordinary wallet of yours (see "After the launch").
- A contract creation cannot be shown in full on the Ledger, so the Ethereum app must have Blind signing
  turned on in its settings to deploy. Until the end of S4, turn it on only for the deployment: S2 and
  "S2 stops half way" say when to turn it on and off.
- Send it 0.01 ETH on OP Mainnet, and nothing on any other chain until S3 item 7, which needs a little ETH on
  Ethereum. The three deploy transactions of the build of 1 November 2026 used 12,594,254 gas on a local chain;
  the rehearsal of this checklist gives the figure of the signed-off commit. At normal OP gas prices that costs
  far less than 0.01 ETH, the L1 data fee included.
- Check it, with one of the OP Mainnet RPC addresses of item 4:

```sh
cast code <deployer address> --rpc-url <OP Mainnet RPC>
cast nonce <deployer address> --rpc-url <OP Mainnet RPC>
```

The first must print `0x`, so it has no code and no EIP7702 delegation. The second must print `0`, which
makes N equal to 0. Item 4 checks the four other chains.

### 3. The signed part of the review record

Part 2 of `gates/review-record.md` is its template. Copy it into a file outside the repository, fill in
every value and sign it. It names the repository that holds the signed-off commit, the commit (the full 40
character hash), the gate run on a clean
checkout of that commit ending with `ALL GATES PASS`, the reviews, your sign-off, and the deployer address
with N. Every value you type on deploy day comes from it.

### 4. RPC addresses, the explorer key and the values file

You need two OP Mainnet RPC addresses from two different providers, for example `https://mainnet.optimism.io`
and one from a paid provider, and the address of a third provider in reserve. You also need one RPC address
each for Ethereum, Base, OP Sepolia and Base Sepolia (for example `https://mainnet.base.org`,
`https://sepolia.optimism.io` and `https://sepolia.base.org` for the last three), and an Etherscan API key for
S4.

S3 reads the chain at the deploy blocks once OP Mainnet has finalized them, about 20 minutes after S2, or later
if it runs again, so each OP Mainnet provider, the one in reserve included, must keep the state of at least the
last day. Check each with this line, with its address in place of `<OP Mainnet RPC>` both times, inside the
quotes. It reads the state of 43,200 blocks ago, a day at two seconds a block, and must print a number. An error
such as `missing trie node` means that the provider keeps no state that old: choose another.

```sh
cast balance 0x000000000000000000000000000000000000dEaD --block $(( $(cast block-number --rpc-url '<OP Mainnet RPC>') - 43200 )) --rpc-url '<OP Mainnet RPC>'
```

Make the folder with `mkdir -p ~/etherpage-deploy`, outside the repository. Then write these lines, with
the values of the signed part and the Ledger path of item 2, into the file `~/etherpage-deploy/values.sh`. It
holds no private key.

```sh
REPO_URL='<the repository of the signed-off commit>'
COMMIT=<signed-off commit>
DEPLOYER_ADDR=<deployer address>
HD_PATH="m/44'/60'/<A>'/0/0"
NONCE=<N>
RPC1='<OP Mainnet RPC of the first provider>'
RPC2='<OP Mainnet RPC of the second provider>'
RPC_ETHEREUM='<Ethereum RPC>'
RPC_BASE='<Base RPC>'
RPC_OP_SEPOLIA='<OP Sepolia RPC>'
RPC_BASE_SEPOLIA='<Base Sepolia RPC>'
EXPLORER_KEY='<Etherscan API key>'
REC=$HOME/etherpage-deploy/record
```

The S3 log `$REC/g20.txt`, `values.sh` and forge's own record of S2 in the clone, `cache/Deploy.s.sol`, hold
the RPC addresses with any API key in them, and `values.sh` also the Etherscan key: none of them is ever
published, only the deployment record of S4 is.

`REPO_URL` is the repository the signed part names, the one that holds the signed-off commit, or the folder
path of your local copy of it.

Then check that the deployer has sent nothing on the four other chains either, since a Ledger account may have
been used before. You must see `chain 1`, `chain 8453`, `chain 11155420` and `chain 84532`, each followed by
`nonce 0`:

```sh
. ~/etherpage-deploy/values.sh
for r in $RPC_ETHEREUM $RPC_BASE $RPC_OP_SEPOLIA $RPC_BASE_SEPOLIA; do echo "chain $(cast chain-id --rpc-url $r) nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $r)"; done
```

Other EVM chains, such as Polygon, Arbitrum or BNB Chain, share the same addresses: if you have used this
Ledger on one of them, check on its explorer that the deployer address has never sent a transaction there
either. If a nonce is not 0, or an explorer shows a transaction sent from the address, do not use this
account: start again from item 2 with a new one.

### 5. The rehearsal

A local dry run of S1 to S3 on a plain anvil node: chain 31337, no fork, no testnet, with a second anvil node
on chain 1 in place of Ethereum for S3 item 7. It is a dry run, not a gate. It ran on 6 October 2026 on a copy
of this folder with seven failure drills, and again on 14 October 2026 with the drill of item 8, and every step
and drill behaved as it should. Run it once more on the signed-off commit before deploy day, so that the commit
checks of S1 also run for real. It never uses the deployer account or the Ledger.

1. In one terminal, start a local chain and leave it running. It prints ten test accounts with their
   private keys, which are public test data. In another terminal, start the second chain, which stands in
   for Ethereum, and leave it running too. It prints the same ten accounts.

```sh
anvil --hardfork prague --chain-id 31337 --port 8545
```

```sh
anvil --hardfork prague --chain-id 1 --port 8546
```

2. In a third terminal, open a rehearsal shell. Anvil's account 5 stands in for the deployer.

```sh
mkdir -p ~/etherpage-rehearsal/record && cd ~/etherpage-rehearsal
env -i HOME="$HOME" PATH="$PATH" HISTFILE= sh
```

```sh
REPO_URL='<the repository of the signed-off commit>'
COMMIT=<signed-off commit>
DEPLOYER_ADDR=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
NONCE=0
RPC1=http://127.0.0.1:8545
RPC2=http://localhost:8545
RPC_ETHEREUM=http://127.0.0.1:8546
REC=$HOME/etherpage-rehearsal/record
git clone "$REPO_URL" repo
cd repo
git checkout --detach $COMMIT
```

3. Do S1 exactly as written below.

4. Deploy with the key of account 5, then check that the nonce is 3:

```sh
DEPLOYER=$DEPLOYER_ADDR EXPECTED_NONCE=$NONCE forge script script/Deploy.s.sol --rpc-url $RPC1 --private-key <the private key (5) anvil printed> --sender $DEPLOYER_ADDR --broadcast --slow
cast nonce $DEPLOYER_ADDR --rpc-url $RPC1
```

5. Do S3 items 1 to 3 as written below, but type this line in place of the first line of item 1:

```sh
BR=broadcast/Deploy.s.sol/31337/run-latest.json
```

6. Mine 64 blocks, which makes anvil call the deploy blocks final, and run G-20 in its rehearsal form. It
   must end with `G-20 PASS`, after 88 `PASS` lines and no `FAIL` line.

```sh
cast rpc anvil_mine 0x40 --rpc-url $RPC1
python3 gates/deployed.py --rehearsal --chain-id 31337 --card $CARD --nft $NFT --registrar $REG --card-tx $CARD_TX --nft-tx $NFT_TX --registrar-tx $REG_TX --deployer $DEPLOYER_ADDR --nonce $NONCE --rpc $RPC1 --rpc $RPC2 --wait 3600
```

7. Do S3 item 7 as written below, with no ETH to send first, since anvil gives account 5 10,000 ETH on both
   chains, and with `--private-key <the private key (5) anvil printed>` in place of
   `--ledger --mnemonic-derivation-path "$HD_PATH"` in its second block. You must see what that item says, with
   N + 3 = 3: three lines with `"status":"0x1"` from the second block.

8. The drill of the registrar check of S3, in the same shell. While a stopped S2 waits, the registrar's
   address has no code, and a page can be minted to it. Anvil's account 6 deploys the three contracts again,
   one at a time. Before the third, account 7 commits to the name `stuck` for the registrar's address, moves
   anvil's clock 30 seconds on, past the 20 seconds a commitment must wait, and reveals it. After the third,
   account 7 registers the page named `later` for itself and sends it to the registrar with a plain `transferFrom`,
   which G-20 must not count, since it reads the block that created the registrar:

```sh
K6=<the private key (6) anvil printed>; K7=<the private key (7) anvil printed>; D6=0x976EA74026E726554dB657fA54763abd0C3a0aa9; N6=$(cast nonce $D6 --rpc-url $RPC1); X=0x$(printf "%064x" 9)
XCARD_TX=$(cast send --private-key $K6 --rpc-url $RPC1 --json --create $(jq -r .bytecode.object out/PageCard.sol/PageCard.json) | jq -r .transactionHash); XCARD=$(cast receipt $XCARD_TX contractAddress --rpc-url $RPC1)
XNFT_TX=$(cast send --private-key $K6 --rpc-url $RPC1 --json --create $(jq -r .bytecode.object out/PageNFT.sol/PageNFT.json)$(cast abi-encode "f(address)" $XCARD | cut -c3-) | jq -r .transactionHash); XNFT=$(cast receipt $XNFT_TX contractAddress --rpc-url $RPC1); XREG=$(cast compute-address $D6 --nonce $((N6 + 2)) | grep -o "0x[0-9a-fA-F]*")
cast send $XNFT "commit(bytes32)" $(cast call $XNFT "makeCommitment(string,address,uint256,bytes32)(bytes32)" stuck $XREG 0 $X --rpc-url $RPC1) --private-key $K7 --rpc-url $RPC1 >/dev/null; cast rpc evm_increaseTime 0x1e --rpc-url $RPC1 >/dev/null; cast send $XNFT "reveal(string,address,uint256,bytes32)" stuck $XREG 0 $X --value 100000000000000 --private-key $K7 --rpc-url $RPC1 --json | jq -c "{status}"
XREG_TX=$(cast send --private-key $K6 --rpc-url $RPC1 --json --create $(jq -r .bytecode.object out/SubpageRegistrar.sol/SubpageRegistrar.json)$(cast abi-encode "f(address)" $XNFT | cut -c3-) | jq -r .transactionHash); echo "registrar at $(cast receipt $XREG_TX contractAddress --rpc-url $RPC1), expected $XREG"
A7=$(cast wallet address --private-key $K7); cast send $XNFT "commit(bytes32)" $(cast call $XNFT "makeCommitment(string,address,uint256,bytes32)(bytes32)" later $A7 0 $X --rpc-url $RPC1) --private-key $K7 --rpc-url $RPC1 >/dev/null; cast rpc evm_increaseTime 0x1e --rpc-url $RPC1 >/dev/null; cast send $XNFT "reveal(string,address,uint256,bytes32)" later $A7 0 $X --value 100000000000000 --private-key $K7 --rpc-url $RPC1 >/dev/null; cast send $XNFT "transferFrom(address,address,uint256)" $A7 $XREG $(cast call $XNFT "computeId(string)" later --rpc-url $RPC1) --private-key $K7 --rpc-url $RPC1 --json | jq -c "{status}"; echo "the registrar holds $(cast call $XNFT "balanceOf(address)(uint256)" $XREG --rpc-url $RPC1) names"
python3 -u gates/deployed.py --rehearsal --chain-id 31337 --block latest --card $XCARD --nft $XNFT --registrar $XREG --card-tx $XCARD_TX --nft-tx $XNFT_TX --registrar-tx $XREG_TX --deployer $D6 --nonce $N6 --rpc $RPC1 --rpc $RPC2 2>&1 | grep -E "^FAIL|^G-20"
```

   You must see `{"status":"0x1"}`, then the registrar at the expected address, then `{"status":"0x1"}`
   again and `the registrar holds 2 names`. After about 8 minutes of building, you must see two `FAIL` lines,
   one for each address of the node, each saying `PageNFT holds no name for the registrar` and ending with
   `1`, the one page it held at the block that created it, then a last line starting with
   `G-20 FAIL: 2 checks`.

9. Leave the shell with `exit`, stop both anvil nodes with Ctrl+C, and delete `~/etherpage-rehearsal`.

What the rehearsal does not show, so deploy day does it for the first time: signing with the Ledger, OP
Mainnet itself, its finalized head about 20 minutes behind the latest block, two independent providers, the
L1 data fee, the explorer, the source verification, the four other chains, Ethereum and its fees, OP
Mainnet's current upgrade with its limit of 16,777,216 gas per transaction (EIP-7825), which anvil does not
apply (the largest deploy transaction, PageNFT, uses 5,923,154), and the address check of S4.

### 6. The address check of S4

S4 needs an automated check that reads the three addresses in the website configuration, in the gateway
configuration and in the published documentation, and compares each with the addresses that passed G-20 in
S3. It also reads `ROOT()` and `card()` through the website's own RPC. It belongs to the website and gateway
work, not to this folder. It must exist, and be seen to fail on a wrong address, before deploy day. S4 shows
the comparisons it must make.

## Deploy day

Plan about an hour. S1 builds for about 8 minutes. S3 builds again, then waits about 20 minutes for OP
Mainnet to finalize the deploy blocks.

### Open the deploy shell

In a new terminal:

```sh
mkdir -p ~/etherpage-deploy/record
cd ~/etherpage-deploy
env -i HOME="$HOME" PATH="$PATH" HISTFILE= sh
```

The last line starts a shell with no other settings, so no `FOUNDRY_` or `DAPP_` variable can change the
build, and it writes no history file of what you type. Its prompt looks like `sh-3.2$`. Do every step below
in this shell. Load the values and print them:

```sh
. ~/etherpage-deploy/values.sh
DEPLOYER_ADDR=$(cast to-check-sum-address $DEPLOYER_ADDR)
echo "repository $REPO_URL, commit $COMMIT, deployer $DEPLOYER_ADDR at nonce $NONCE, Ledger path $HD_PATH"
```

Compare the repository, the commit, the deployer and the nonce with the signed part, character by character.
S2 item 1 checks the Ledger path on the Ledger. Then take a fresh clone of the repository at the signed-off
commit: `REPO_URL` of the values file (item 4 of "Before deploy day"). The folder `repo` must not exist yet.

```sh
git clone "$REPO_URL" repo
cd repo
git checkout --detach $COMMIT
```

### S1. Build the signed-off commit

In `~/etherpage-deploy/repo`.

1. No stray settings, and the right commit:

```sh
env | grep -E "^(FOUNDRY_|DAPP_)"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] && echo "HEAD IS THE SIGNED-OFF COMMIT"
git status --porcelain
```

You must see nothing from the first line, then `HEAD IS THE SIGNED-OFF COMMIT`, then nothing from
`git status`.

2. The library trees:

```sh
python3 gates/gates.py --only G-28
```

You must see 10 `PASS` lines, no `FAIL` line, and at the end `ALL GATES RUN PASS, BUT NOT EVERY GATE RAN`.
That last line is expected, since only G-28 ran.

3. The forge version:

```sh
forge --version
```

The four lines must equal the `forge --version` row of Part 1 of `gates/review-record.md`, as in item 1 of
"Before deploy day".

4. The build, about 8 minutes:

```sh
forge clean && forge build --sizes; echo "exit $?"
```

Warnings are expected: the build shows the two `Warning (8429)` of the soledge library and warnings of the test
helpers, none of the three contracts (gate G-49 lists every library warning). You must see `Compiler run
successful`, these three rows in the size table, and `exit 0` at the end:

| Contract | Runtime Size (B) | Initcode Size (B) |
| --- | --- | --- |
| PageCard | 24,129 | 24,155 |
| PageNFT | 24,395 | 24,818 |
| SubpageRegistrar | 6,214 | 6,402 |

5. The six build hashes and the compiler settings:

```sh
for c in PageCard PageNFT SubpageRegistrar; do for f in bytecode deployedBytecode; do h=$(jq -r .$f.object out/$c.sol/$c.json | cast keccak); if grep -q "^| \`$c\` | \`$f.object\` | [0-9,]* | \`$h\` |\$" gates/review-record.md; then echo "SAME AS THE RECORD  $c $f.object $h"; else echo "DIFFERENT  $c $f.object $h"; fi; done; done
for c in PageCard PageNFT SubpageRegistrar; do jq -c --arg c $c "{contract: \$c, compiler: .metadata.compiler.version, optimizer: .metadata.settings.optimizer, viaIR: .metadata.settings.viaIR, evmVersion: .metadata.settings.evmVersion, metadata: .metadata.settings.metadata}" out/$c.sol/$c.json; done
git status --porcelain
```

You must see six lines starting with `SAME AS THE RECORD`. Then three lines, each with
`"compiler":"0.8.38+commit.1835d247"`, `"optimizer":{"enabled":true,"runs":200}`, `"viaIR":true`,
`"evmVersion":"prague"` and `"metadata":{"bytecodeHash":"ipfs"}`. Then nothing from `git status`.

If anything in S1 differs, stop. Nothing has been sent.

### S2. Deploy the three contracts

Same folder, same shell.

1. The chain and the deployer, with the Ledger unlocked and its Ethereum app open:

```sh
env | grep -E "^(FOUNDRY_|DAPP_|DEPLOYER|EXPECTED_NONCE)"
cast chain-id --rpc-url $RPC1
cast chain-id --rpc-url $RPC2
cast code $DEPLOYER_ADDR --rpc-url $RPC1
cast nonce $DEPLOYER_ADDR --rpc-url $RPC1
cast balance --ether $DEPLOYER_ADDR --rpc-url $RPC1
for n in $NONCE $((NONCE + 1)) $((NONCE + 2)); do cast compute-address $DEPLOYER_ADDR --nonce $n; done
cast wallet address --ledger --mnemonic-derivation-path "$HD_PATH"
```

You must see nothing from `env`, then `10` twice, `0x`, N, and the ETH you sent. Then three
addresses, one per line: write them down as the addresses of `PageCard`, `PageNFT` and `SubpageRegistrar`, in
that order. Last, you must see the deployer address.

2. The deployment. Turn on Blind signing in the Ethereum app of the Ledger. `DEPLOYER` and `EXPECTED_NONCE`
   are set on this command only:

```sh
DEPLOYER=$DEPLOYER_ADDR EXPECTED_NONCE=$NONCE forge script script/Deploy.s.sol --rpc-url $RPC1 --ledger --mnemonic-derivation-paths "$HD_PATH" --sender $DEPLOYER_ADDR --broadcast --slow; echo "exit $?"
```

Before the Ledger asks for anything, you must see `No files changed, compilation skipped`,
`Script ran successfully.`, the three addresses you wrote down under `== Logs ==`, and `Chain 10`. Then the
Ledger asks you to approve three transactions, one after another. Each starts with the warning
`Blind signing ahead`: accept the risk and continue. Check that `From` is the deployer address (if the Ledger
shows a name there, open it to see the address), that `To` shows `Contract` and that `Network` shows
`OP Mainnet`, then sign. No amount is shown, since each sends 0 ETH. The hash the Ledger shows is not the
transaction hash that S3 reads, so there is nothing to compare. If forge asks for a transaction again, check
it the same way. At the end you must see `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.` and `exit 0`. Then turn
Blind signing off in the Ethereum app.

3. The deployer sent three transactions:

```sh
cast nonce $DEPLOYER_ADDR --rpc-url $RPC1
```

It must print N + 3.

If the script stops with `wrong chain`, `wrong deployer or nonce` or `No associated wallet for addresses`,
nothing was sent and the nonce is still N. Such a run may still leave a broadcast record, which proves
nothing. Stop and compare every value with the signed part. If one was mistyped, correct `values.sh`, run
again the three lines of "Open the deploy shell" that load and print the values, and repeat S2. If it stopped
in any other way, for example with `Failed to send transaction`, see "S2 stops half way", whose first step
shows how many went out.

### S3. Compare the live code with the build, then close its addresses on Ethereum

Same folder, same shell.

1. What forge recorded, in its broadcast record for chain 10:

```sh
BR=broadcast/Deploy.s.sol/10/run-latest.json
jq -r ".transactions[] | \"\(.contractName) \(.contractAddress) \(.hash)\"" $BR
jq -c ".receipts[] | {transactionHash, blockNumber, status, contractAddress}" $BR
```

You must see `PageCard`, `PageNFT` and `SubpageRegistrar`, each with its address and a transaction hash, and
three receipts with `"status":"0x1"`. A record without hashes or receipts proves nothing.

2. Keep the addresses and hashes, here and in a file:

```sh
CARD=$(jq -r ".transactions[] | select(.contractName == \"PageCard\") | .contractAddress" $BR)
NFT=$(jq -r ".transactions[] | select(.contractName == \"PageNFT\") | .contractAddress" $BR)
REG=$(jq -r ".transactions[] | select(.contractName == \"SubpageRegistrar\") | .contractAddress" $BR)
CARD_TX=$(jq -r ".transactions[] | select(.contractName == \"PageCard\") | .hash" $BR)
NFT_TX=$(jq -r ".transactions[] | select(.contractName == \"PageNFT\") | .hash" $BR)
REG_TX=$(jq -r ".transactions[] | select(.contractName == \"SubpageRegistrar\") | .hash" $BR)
printf "CARD=%s\nNFT=%s\nREG=%s\nCARD_TX=%s\nNFT_TX=%s\nREG_TX=%s\n" $CARD $NFT $REG $CARD_TX $NFT_TX $REG_TX > $REC/deploy-values.sh && cat $REC/deploy-values.sh
```

3. Each transaction on chain, by nonce:

```sh
for h in $CARD_TX $NFT_TX $REG_TX; do echo "$h nonce $(cast tx $h nonce --rpc-url $RPC1) from $(cast tx $h from --rpc-url $RPC1) to $(cast tx $h to --rpc-url $RPC1) created $(cast receipt $h contractAddress --async --rpc-url $RPC1) block $(cast receipt $h blockNumber --async --rpc-url $RPC1) status $(cast receipt $h status --async --rpc-url $RPC1)"; done
for n in $NONCE $((NONCE + 1)) $((NONCE + 2)); do echo "nonce $n: $(cast compute-address $DEPLOYER_ADDR --nonce $n)"; done
for h in $CARD_TX $NFT_TX $REG_TX; do cast receipt $h status --async --rpc-url $RPC2; done
```

You must see the nonces N, N + 1 and N + 2 in that order, each sent from the deployer, with nothing after
`to`, `created` showing the address the second command prints for that nonce, and `status true`. Then
`true` three times from the second provider. This also catches a wrong hash before the long wait of
item 6.

4. On the explorer, by hand. Open `https://optimistic.etherscan.io/tx/` followed by each of the three hashes.
   Each must show Success, the deployer as sender, and the creation of the contract at its address.

5. No code at the three addresses on the four other chains:

```sh
for r in $RPC_ETHEREUM $RPC_BASE $RPC_OP_SEPOLIA $RPC_BASE_SEPOLIA; do echo "chain $(cast chain-id --rpc-url $r)"; for a in $CARD $NFT $REG; do echo "$a $(cast code $a --rpc-url $r)"; done; done
```

You must see `chain 1`, `chain 8453`, `chain 11155420` and `chain 84532`, and after each address `0x` and
nothing more.

6. G-20:

```sh
python3 -u gates/deployed.py --commit $COMMIT --card $CARD --nft $NFT --registrar $REG --card-tx $CARD_TX --nft-tx $NFT_TX --registrar-tx $REG_TX --deployer $DEPLOYER_ADDR --nonce $NONCE --rpc $RPC1 --rpc $RPC2 --wait 3600 2>&1 | tee $REC/g20.txt
grep -c "^PASS" $REC/g20.txt; grep -c "^FAIL" $REC/g20.txt
```

It rebuilds for about 8 minutes, checks the three transactions, then prints `waiting` lines until OP Mainnet
has finalized the deploy blocks, about 20 minutes after S2. Last it reads, from each provider, how many pages
`PageNFT` held for the registrar at the block that created the registrar. You must see `G-20 PASS` as the last
line, then `92` and `0`. Its `forge clean` leaves forge's record of S2 in `cache/Deploy.s.sol`, which holds
the RPC addresses (see item 4 of "Before deploy day").

The two lines `PageNFT holds no name for the registrar` fail when a page reached the registrar's address before
its code existed, such as a trial or a subpage minted to it. Only an S2 that stopped or stalled between
`PageNFT` and the registrar leaves time for that. They also count a page sent to the registrar with a plain
`transferFrom` later in the block that created the registrar, and the deployment is abandoned either way.

If the hour of waiting ran out before the deploy blocks were final, the run fails on its block and code
checks; run item 6 again later. If every `FAIL` line is a `PageNFT holds no name for the registrar` line that
shows an error of its provider, such as `missing trie node`, in place of a number, that provider keeps no state
that old: see "A provider does not answer", then run item 6 again. Any other failure in items 1 to 6
abandons the deployment: see "Abandon and redeploy".

7. Use up the deployer's nonces on Ethereum. An address made by a plain CREATE follows from the deployer and its
   nonce alone, so on Ethereum the nonces N, N + 1 and N + 2 of the deployer would put code at the three
   addresses of S2, and the S2 transactions have shown the deployer's public key, from which a quantum computer
   may one day work out its private key. Code at the `PageNFT` address on Ethereum could one day send a deposit
   to OP Mainnet as `PageNFT` itself, and with it take the ETH `PageNFT` holds, every page's deposit, without
   running any of its code. Code at the `SubpageRegistrar` address could likewise take the registrar's
   unclaimed ETH proceeds, spend the ERC20 allowances buyers gave it and mint free subpages under the pages
   that picked it as their minter, and code at either address gets any page sent or approved to it. Today OP
   Mainnet gives a contract that sends from Ethereum another address, but it keeps the address of a sender that
   started its own transaction, which EIP-8141, a draft change to Ethereum, would let a contract do. A plain
   transaction uses up its nonce for good, so once the deployer's nonce on Ethereum reaches N + 3 no key can put
   code at the three addresses there.

   Send the deployer 0.005 ETH on Ethereum from another account of yours. Three plain transactions use 63,000
   gas, under 0.001 ETH at a gas price of 15 gwei. Then:

```sh
cast chain-id --rpc-url $RPC_ETHEREUM
cast code $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM
cast balance --ether $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM
echo "OP Mainnet nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC1), Ethereum nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM), expected $((NONCE + 3)) and 0"
for a in $CARD $NFT $REG; do echo "$a $(cast code $a --rpc-url $RPC_ETHEREUM)"; done
```

   You must see `1`, `0x`, the ETH you sent, the two nonces equal to the two expected numbers, and `0x` after
   each of the three addresses. When you run this block again after the next one has started, the balance is
   less than the ETH you sent and the Ethereum nonce may be anything from 0 to N + 3; go on as long as you see
   `1` and `0x` after the deployer and each of the three addresses. If the deployer or any of the three
   addresses shows code on Ethereum, publish nothing and abandon the deployment: do steps 1 and 3 of "Abandon
   and redeploy" with this reason, then start again from item 2 of "Before deploy day" with a new Ledger
   account, and write its address, its path and N = 0 in a new signed part and in `values.sh`, since the key
   that put the code there is not under your control. Then, with Blind
   signing off in the Ethereum app of the Ledger, send 0 ETH from the deployer to itself at each nonce up to
   N + 2:

```sh
n=$(cast nonce $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM); while [ $n -lt $((NONCE + 3)) ]; do r=$(cast send $DEPLOYER_ADDR --value 0 --nonce $n --rpc-url $RPC_ETHEREUM --json --ledger --mnemonic-derivation-path "$HD_PATH") || { echo "stopped at nonce $n: $r"; break; }; echo "$r" | jq -c "{nonce: $n, transactionHash, status, to, contractAddress}"; n=$((n + 1)); done; echo "Ethereum nonce now $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM)"
```

   The Ledger asks you to approve N + 3 transactions, one after another, three for a fresh deployer. Each sends
   0 ETH on Ethereum with no data, so the Ledger shows it in full: check that the amount is 0, that the
   recipient and `From` are the deployer address, and that no `Network` line is shown, since the Ethereum app
   shows one for every chain but Ethereum. If it shows one, reject, stop, and check `RPC_ETHEREUM`: pasting
   the block again would only sign for the same wrong chain. Otherwise sign. After each you must see a line
   with its nonce, `"status":"0x1"`, the deployer address in lower case after `"to"` and
   `"contractAddress":null`, and at the end `Ethereum nonce now` followed by N + 3. If the block stops instead,
   it prints `stopped at nonce` and the error, for example `Failed to estimate gas` or `insufficient funds` when
   the ETH ran out, or a rejection on the Ledger. The deployment is not affected: send the deployer a little
   more ETH on Ethereum if it ran out, and paste the same block again. It starts at the deployer's current
   nonce on Ethereum, sends only the transactions still missing, and sends nothing once that nonce is N + 3. If
   it stops with `transaction was not confirmed within the timeout`, that transaction is still pending, and
   `Ethereum nonce now` still shows its nonce: do not paste the block again while
   `https://etherscan.io/address/` followed by the deployer address shows a pending transaction of the
   deployer, since a paste while it is pending signs the same nonce again. Once that page shows it mined, or
   shows no pending transaction while the Ethereum nonce has not moved for 30 minutes, which means it was
   dropped, paste the block again. If `RPC_ETHEREUM` does not answer, the block prints its error, for example
   `error sending request` or `Connection refused`. When it does not answer from the start, there is no
   `stopped at nonce` line: the block also prints a line ending `[: -lt: unary operator expected` and nothing
   after `Ethereum nonce now`, and sends nothing. Either way, see "A provider does not answer", which covers it
   too. Last, the check:

```sh
echo "Ethereum nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM), OP Mainnet nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC1)"
for a in $CARD $NFT $REG; do echo "$a $(cast code $a --rpc-url $RPC_ETHEREUM)"; done
```

   You must see both nonces at N + 3 and `0x` after each of the three addresses. Then, by hand, open
   `https://etherscan.io/address/` followed by the deployer address: it must show N + 3 transactions sent, each
   a transfer of 0 ETH to the deployer itself, and no contract creation. S4 item 1 records them.

### S4. Record, verify, check, publish

In the clone, same shell.

1. The deployment record. The deploy block of `PageNFT` is the start block for indexers, and the block at
   which solvency monitoring reads any ETH sent to its address before it existed.

```sh
s4() { echo "# Deployment record, $(date -u +%Y-%m-%d)"; echo; echo "OP Mainnet, chain $(cast chain-id --rpc-url $RPC1)."; echo; echo "| Item | Value |"; echo "| --- | --- |"; echo "| Commit | \`$(git rev-parse HEAD)\` |"; echo "| \`forge --version\` | $(forge --version | sed "s/^/\`/; s/\$/\`/" | paste -sd, - | sed "s/,/, /g") |"; for c in PageCard PageNFT SubpageRegistrar; do for f in bytecode deployedBytecode; do echo "| keccak256 of \`$c\` \`$f.object\` | \`$(jq -r .$f.object out/$c.sol/$c.json | cast keccak)\` |"; done; done; echo "| G-20 | \`$(grep -E "^G-20" $REC/g20.txt)\`, $(grep -c "^PASS" $REC/g20.txt) checks, log \`g20.txt\` |"; echo "| Deployer | \`$DEPLOYER_ADDR\`, expected nonce $NONCE |"; echo "| Deployer on Ethereum | nonce $(cast nonce $DEPLOYER_ADDR --rpc-url $RPC_ETHEREUM), code at the three addresses: $(for a in $CARD $NFT $REG; do printf "\`%s\` " $(cast code $a --rpc-url $RPC_ETHEREUM); done)|"; echo "| \`PageCard\` | \`$CARD\`, transaction \`$CARD_TX\`, block $(cast receipt $CARD_TX blockNumber --async --rpc-url $RPC1), nonce $(cast tx $CARD_TX nonce --rpc-url $RPC1) |"; echo "| \`PageNFT\` | \`$NFT\`, transaction \`$NFT_TX\`, block $(cast receipt $NFT_TX blockNumber --async --rpc-url $RPC1), nonce $(cast tx $NFT_TX nonce --rpc-url $RPC1) |"; echo "| \`SubpageRegistrar\` | \`$REG\`, transaction \`$REG_TX\`, block $(cast receipt $REG_TX blockNumber --async --rpc-url $RPC1), nonce $(cast tx $REG_TX nonce --rpc-url $RPC1) |"; echo "| \`PageNFT\` deploy block | $NFT_BLOCK, the start block for indexers; ETH at the address at that block: $(cast balance $NFT --block $NFT_BLOCK --rpc-url $RPC1) wei |"; echo "| \`ROOT()\` | \`$(cast call $NFT "ROOT()(bytes32)" --rpc-url $RPC1)\` |"; echo "| \`card()\` | \`$(cast call $NFT "card()(address)" --rpc-url $RPC1)\` |"; }
NFT_BLOCK=$(cast receipt $NFT_TX blockNumber --async --rpc-url $RPC1) && echo "PageNFT deploy block $NFT_BLOCK"
cast balance $NFT --block $NFT_BLOCK --rpc-url $RPC1
s4 > $REC/deployment-record.md && cat $REC/deployment-record.md
```

You must see the deploy block, the ETH at the address in that block (normally 0), and the record. Check that
it names the signed-off commit, `G-20 PASS` with 92 checks, the deployer on Ethereum at nonce N + 3 with `0x`
three times, the three addresses of S3 each with its block and nonce, the deploy block, `ROOT()` and `card()`. If the paste leaves a `>` prompt, or a line says `syntax error`
or `command not found`, press Ctrl+C and paste the block again at the empty prompt: it only reads, and writes the
record again.

2. The wiring, read on chain:

```sh
[ "$(cast call $NFT "ROOT()(bytes32)" --rpc-url $RPC1)" = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6 ] && [ "$(cast call $NFT "card()(address)" --rpc-url $RPC1)" = "$(cast to-check-sum-address $CARD)" ] && [ "$(cast call $REG "registry()(address)" --rpc-url $RPC1)" = "$(cast to-check-sum-address $NFT)" ] && echo "ROOT, card and registry as expected"
```

You must see `ROOT, card and registry as expected`.

3. Verify the source on Etherscan:

```sh
forge verify-contract $CARD src/PageCard.sol:PageCard --chain 10 --verifier etherscan --etherscan-api-key $EXPLORER_KEY --watch
forge verify-contract $NFT src/PageNFT.sol:PageNFT --chain 10 --verifier etherscan --etherscan-api-key $EXPLORER_KEY --constructor-args $(cast abi-encode "constructor(address)" $CARD) --watch
forge verify-contract $REG src/SubpageRegistrar.sol:SubpageRegistrar --chain 10 --verifier etherscan --etherscan-api-key $EXPLORER_KEY --constructor-args $(cast abi-encode "constructor(address)" $NFT) --watch
```

Each must end by saying the contract is verified. Forge 1.8.7 also submits each contract to Sourcify on its
own and prints the job it started there; that is expected, and it publishes the same source. Then
`https://optimistic.etherscan.io/address/` followed
by each address must show the verified source. If a verification fails, the contracts are not affected: wait
and run the same command again. Publish nothing before all three are verified.

4. The address check of item 6 of "Before deploy day", before the website, the gateway configuration or the
   documentation goes live with the addresses. For each of the three, it makes these comparisons, with the
   values found in that configuration in place of the placeholders:

```sh
[ "$(cast to-check-sum-address <PageCard address as configured>)" = "$(cast to-check-sum-address $CARD)" ] && echo "PageCard address as expected"
[ "$(cast to-check-sum-address <PageNFT address as configured>)" = "$(cast to-check-sum-address $NFT)" ] && echo "PageNFT address as expected"
[ "$(cast to-check-sum-address <SubpageRegistrar address as configured>)" = "$(cast to-check-sum-address $REG)" ] && echo "SubpageRegistrar address as expected"
[ "$(cast call <PageNFT address as configured> "ROOT()(bytes32)" --rpc-url <website RPC>)" = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6 ] && [ "$(cast call <PageNFT address as configured> "card()(address)" --rpc-url <website RPC>)" = "$(cast to-check-sum-address $CARD)" ] && echo "ROOT and card as expected through the website RPC"
```

It must print the four `as expected` lines for the website, the gateway and the documentation. Both sides go
through `cast to-check-sum-address`, because `cast` prints addresses in checksum case while forge's record
keeps them in lower case. If the check is missing or a line is missing, publish nothing.

5. Only now publish the addresses and announce.

## When something goes wrong

### S2 stops half way

Forge sends one transaction at a time and does not check the total cost first. If it stops after sending one
or two, for example because the deployer ran out of ETH or a transaction was rejected on the Ledger:

1. `cast nonce $DEPLOYER_ADDR --rpc-url $RPC1` shows how many went out: N + 1 or N + 2. If it shows N,
   nothing was sent: top up the deployer if it ran out of ETH, and repeat S2.
2. If it ran out of ETH, send it a little more on OP Mainnet.
3. Check that Blind signing is on in the Ethereum app of the Ledger. In the same folder and shell, run the S2
   command again with `--resume` at the end:

```sh
DEPLOYER=$DEPLOYER_ADDR EXPECTED_NONCE=$NONCE forge script script/Deploy.s.sol --rpc-url $RPC1 --ledger --mnemonic-derivation-paths "$HD_PATH" --sender $DEPLOYER_ADDR --broadcast --slow --resume; echo "exit $?"
```

It sends only the missing transactions, at the next nonces, and does not run the script's checks again. The
Ledger asks you to approve each of them: check each on the Ledger as in S2 item 2. You must see
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.` and `exit 0`, and then N + 3 from `cast nonce`. Then turn Blind
signing off in the Ethereum app. Go on with S3, which decides. If `PageNFT` went out before the stop, a page
could reach the registrar's address while it had no code; if one did, G-20 fails on its lines
`PageNFT holds no name for the registrar` and the deployment is abandoned. If you do not resume, turn Blind
signing off and abandon the deployment instead.

### A provider does not answer

When a step sends you here, replace that provider. Put the provider in reserve in its place in `values.sh`,
run again the three lines of "Open the deploy shell" that load and print the values, and check that both
addresses answer `10`:

```sh
cast chain-id --rpc-url $RPC1; cast chain-id --rpc-url $RPC2
```

Then run again what the step that sent you here names. Replacing a provider sends nothing and pays nothing.

For `RPC_ETHEREUM` in S3 item 7, put another Ethereum RPC address in its place in `values.sh`, load the
values again, and check that `cast chain-id --rpc-url $RPC_ETHEREUM` prints `1`. A transaction sent before the
provider stopped may still be pending: wait as item 7 says for a pending transaction, then paste the first
block of item 7 again and, once it shows what item 7 says, the second.

If a provider still cannot read the block that created the registrar once the provider in reserve is in place,
there is none left to replace it, and that abandons the deployment: see "Abandon and redeploy".

### Abandon and redeploy

When a step above says that the deployment is abandoned:

1. Publish nothing and announce nothing. The abandoned addresses are never used.
2. `cast nonce $DEPLOYER_ADDR --rpc-url $RPC1` gives the new expected nonce.
3. Write it in the redeploy table of the signed part first, with the date and the reason, and sign it.
4. Leave the deploy shell with `exit`. Keep the old folder apart, then start a new one with the new nonce.
   For a second abandoned deployment, use `-2` in place of `-1`, and so on.

```sh
mv ~/etherpage-deploy ~/etherpage-deploy-abandoned-1
mkdir -p ~/etherpage-deploy && cp ~/etherpage-deploy-abandoned-1/values.sh ~/etherpage-deploy/
```

5. Change `NONCE` in `~/etherpage-deploy/values.sh`, check that the deployer still has enough ETH, and start
   again from "Open the deploy shell". The commit stays the same.

### The terminal closed

Open a new terminal and do "Open the deploy shell" again without the clone, then go back into the clone:

```sh
cd ~/etherpage-deploy/repo
```

After S3 item 2, also load the addresses with `. $REC/deploy-values.sh`. If the terminal closed during S2, see
"S2 stops half way" first. If it closed during S3 item 7, wait as item 7 says until etherscan.io shows no
pending transaction of the deployer, then paste the first block of item 7 again and, once it shows what item 7
says, the second: it starts at the deployer's current nonce on Ethereum.

## After the launch

- Keep `~/etherpage-deploy/record`, and `broadcast` in the clone, with the deployment record. Never publish the
  clone's `cache` folder: like `values.sh`, it holds the RPC addresses with any API key in them.
- After S4 the deployer is an ordinary wallet of yours, to use as you like. OpenSea credits a contract with no
  owner to the account that deployed it, so this is the account that claims and manages the collection page
  at opensea.io. One rule stays, on every chain: never deploy a contract from it and never accept an upgrade of
  it to a smart account, since either could put other code at the three Etherpage addresses on another chain.
  On Ethereum, whose deposits reach OP Mainnet, S3 item 7 has made that impossible for good; elsewhere such code
  could only pass itself off as the contracts.
