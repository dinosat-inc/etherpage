#!/usr/bin/env python3
# G-20: the deployed code is the signed-off build. Run after the broadcast, in the fresh clone and the
# shell of the deploy, with no FOUNDRY_ or DAPP_ variable set. It checks the checkout, rebuilds, compares
# the six build hashes with the build part of gates/review-record.md, checks that each deploy transaction
# is a plain CREATE by the deployer, at consecutive nonces, whose input is the creation code of the build
# and its constructor argument, then reads the code of the three contracts at the addresses of the deploy
# receipts from two independent RPC sources and compares it byte for byte with the build, the metadata
# tail included, after filling every immutable range with the expected address. Last it checks on each
# source that PageNFT held no name for the registrar at the block that created the registrar.
# Usage: python3 gates/deployed.py --commit <hash> --card <addr> --nft <addr> --registrar <addr>
#        --card-tx <hash> --nft-tx <hash> --registrar-tx <hash> --deployer <addr> --nonce <n>
#        --rpc <url> --rpc <url> [--chain-id 10] [--block finalized] [--wait <seconds>] [--rehearsal]
# --block is the block every source is read at: finalized by default, or a block number, which must be
# final on every source. Either way it must hold the last deploy receipt.
# --wait polls for up to that many seconds until the block to read holds the last deploy receipt and
# is final on every source, so the script can start right after the broadcast.
# --rehearsal skips the commit and clean tree checks, accepts only chain 31337 and reads any block, such
# as latest, for a local anvil run only.
import argparse, json, os, re, subprocess, sys, time

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fails = []
CONTRACTS = ('PageCard', 'PageNFT', 'SubpageRegistrar')


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + str(detail)) if detail and not ok else ''}")
    if not ok:
        fails.append(name)
    return ok


def run(cmd):
    p = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def build_part():
    # the part of the review record committed with the code, from its Part 1 heading to its Part 2 heading
    text = open(os.path.join(root, 'gates', 'review-record.md')).read()
    m = re.search(r'^## Part 1\b.*?(?=^## Part 2\b)', text, re.M | re.S)
    return m.group(0) if m else ''


def record_hashes(part):
    out = {}
    for c, field, h in re.findall(r'^\| `(\w+)` \| `(bytecode|deployedBytecode)\.object` \| [\d,]+ \| `(0x[0-9a-f]{64})` \|$', part, re.M):
        out[(c, field)] = h
    return out


def keccak(hexstr):
    rc, o, e = run(['cast', 'keccak', hexstr])
    return o


def rpc_call(rpc, method, *params):
    # the JSON result of one RPC call, or None
    rc, o, e = run(['cast', 'rpc', method, *params, '--rpc-url', rpc])
    if rc != 0:
        return None
    try:
        return json.loads(o)
    except ValueError:
        return None


def block_number(rpc, block):
    # the number of a block given by tag or by decimal number, or None when the source does not have it
    b = rpc_call(rpc, 'eth_getBlockByNumber', hex(int(block)) if block.isdigit() else block, 'false')
    return int(b['number'], 16) if isinstance(b, dict) and b.get('number') else None


def word(address):
    return address[2:].lower().rjust(64, '0')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--commit', default='')
    ap.add_argument('--card', required=True)
    ap.add_argument('--nft', required=True)
    ap.add_argument('--registrar', required=True)
    ap.add_argument('--card-tx', required=True)
    ap.add_argument('--nft-tx', required=True)
    ap.add_argument('--registrar-tx', required=True)
    ap.add_argument('--deployer', required=True)
    ap.add_argument('--nonce', type=int, required=True)
    ap.add_argument('--rpc', action='append', required=True)
    ap.add_argument('--chain-id', type=int, default=10)
    ap.add_argument('--block', default='finalized')
    ap.add_argument('--wait', type=int, default=0)
    ap.add_argument('--rehearsal', action='store_true')
    a = ap.parse_args()

    env = sorted(k for k in os.environ if k.startswith('FOUNDRY_') or k.startswith('DAPP_'))
    check("no FOUNDRY_ or DAPP_ variable is set", not env, env)
    check("two RPC sources", len(a.rpc) >= 2 and len(set(a.rpc)) == len(a.rpc), a.rpc)
    if a.rehearsal:
        print("REHEARSAL: the commit and clean tree checks are skipped")
        check("a rehearsal runs on chain 31337 only", a.chain_id == 31337)
    else:
        rc, head, _ = run(['git', 'rev-parse', 'HEAD'])
        check("HEAD is the signed-off commit", rc == 0 and a.commit and head == a.commit, head)
        rc, st, _ = run(['git', 'status', '--porcelain'])
        check("the tree is clean", rc == 0 and st == '', st[:400])
        check("the chain is OP Mainnet", a.chain_id == 10)

    part = build_part()
    want = record_hashes(part)
    check("the build part of the review record holds six build hashes", len(want) == 6, sorted(want))
    rc, ver, _ = run(['forge', '--version'])
    lines = [l.strip() for l in ver.split('\n') if l.strip()]
    missing = [l for l in lines if f"`{l}`" not in part]
    check("forge --version is the one in the build part of the review record, line for line",
          rc == 0 and re.search(r'Commit SHA: \w+', ver) and not missing, missing or ver)

    rc1, o1, e1 = run(['forge', 'clean'])
    rc2, o2, e2 = run(['forge', 'build', '--sizes'])
    if not check("forge clean && forge build --sizes", rc1 == 0 and rc2 == 0, (o2 + e2)[-600:]):
        return 1
    art = {}
    for c in CONTRACTS:
        art[c] = json.load(open(os.path.join(root, 'out', f'{c}.sol', f'{c}.json')))
        meta = art[c].get('metadata') or json.loads(art[c]['rawMetadata'])
        s = meta['settings']
        check(f"{c}: solc 0.8.38, optimizer on with 200 runs, viaIR, prague, ipfs",
              meta['compiler']['version'].startswith('0.8.38+') and s['optimizer'] == {'enabled': True, 'runs': 200}
              and s.get('viaIR') is True and s.get('evmVersion') == 'prague'
              and s.get('metadata', {}).get('bytecodeHash', 'ipfs') == 'ipfs' and s.get('metadata', {}).get('appendCBOR', True),
              s)
        for field in ('bytecode', 'deployedBytecode'):
            h = keccak(art[c][field]['object'])
            check(f"{c}: keccak256 of {field}.object equals the review record", h == want.get((c, field)), h)

    for rpc in a.rpc:
        rc, cid, e = run(['cast', 'chain-id', '--rpc-url', rpc])
        check(f"{rpc}: chain id {a.chain_id}", rc == 0 and cid == str(a.chain_id), cid + e)

    # the deploy transactions: PageCard, then PageNFT with the card, then the registrar with PageNFT
    addrs = {'PageCard': a.card, 'PageNFT': a.nft, 'SubpageRegistrar': a.registrar}
    txs = {'PageCard': a.card_tx, 'PageNFT': a.nft_tx, 'SubpageRegistrar': a.registrar_tx}
    args = {'PageCard': ('no constructor argument', ''), 'PageNFT': (f"the card {a.card}", word(a.card)),
            'SubpageRegistrar': (f"PageNFT {a.nft}", word(a.nft))}
    deployer = a.deployer.lower()
    last, made = {}, {}
    for rpc in a.rpc:
        nonces, blocks = [], []
        for i, c in enumerate(CONTRACTS):
            tx = rpc_call(rpc, 'eth_getTransactionByHash', txs[c])
            rcpt = rpc_call(rpc, 'eth_getTransactionReceipt', txs[c])
            where = f"{c} deploy transaction {txs[c]} on {rpc}"
            if not check(f"{where}: found, with a successful receipt",
                         isinstance(tx, dict) and isinstance(rcpt, dict) and rcpt.get('status') == '0x1'
                         and rcpt.get('blockNumber') is not None, rcpt.get('status') if isinstance(rcpt, dict) else rcpt):
                nonces.append(None)
                continue
            n = int(tx['nonce'], 16)
            nonces.append(n)
            blocks.append(int(rcpt['blockNumber'], 16))
            if c == 'SubpageRegistrar':
                made[rpc] = blocks[-1]
            check(f"{where}: a CREATE, with no to", tx.get('to') is None, tx.get('to'))
            check(f"{where}: sent by the deployer {a.deployer}", (tx.get('from') or '').lower() == deployer, tx.get('from'))
            check(f"{where}: signed for chain {a.chain_id}",
                  tx.get('chainId') is not None and int(tx['chainId'], 16) == a.chain_id, tx.get('chainId'))
            check(f"{where}: nonce {a.nonce + i}, the expected nonce plus {i}", n == a.nonce + i, n)
            rc, o, e = run(['cast', 'compute-address', a.deployer, '--nonce', str(n)])
            created = re.search(r'0x[0-9a-fA-F]{40}', o)
            check(f"{where}: created {addrs[c]}, the CREATE address of the deployer at that nonce",
                  (rcpt.get('contractAddress') or '').lower() == addrs[c].lower()
                  and created is not None and created.group(0).lower() == addrs[c].lower(),
                  f"receipt {rcpt.get('contractAddress')}, CREATE address {created.group(0) if created else o + e}")
            data = (tx.get('input') or tx.get('data') or '').lower()
            expect = art[c]['bytecode']['object'].lower() + args[c][1]
            diff = next((k for k in range(min(len(data), len(expect))) if data[k] != expect[k]), None)
            check(f"{where}: its input is the creation code of the build with {args[c][0]}", data == expect,
                  f"lengths {len(data)} and {len(expect)} hex characters, first difference at {diff}")
        check(f"{rpc}: the three deploy transactions have consecutive nonces, PageCard first",
              None not in nonces and nonces == [nonces[0], nonces[0] + 1, nonces[0] + 2], nonces)
        last[rpc] = max(blocks) if len(blocks) == 3 else None

    # the block each source is read at
    def target(rpc):
        n = block_number(rpc, a.block)
        if n is None or last[rpc] is None or n < last[rpc]:
            return n, False
        if not a.rehearsal:
            f = block_number(rpc, 'finalized')
            if f is None or f < n:
                return n, False
        return n, True

    deadline = time.time() + a.wait
    read = {}
    for rpc in a.rpc:
        n, ok = target(rpc)
        while not ok and time.time() < deadline:
            print(f"      waiting: block {a.block} of {rpc} is {n}, the last deploy receipt is in block {last[rpc]}")
            time.sleep(max(1, min(30, deadline - time.time())))
            n, ok = target(rpc)
        read[rpc] = n
        named = '' if a.block.isdigit() else f", the {a.block} block,"
        check(f"{rpc}: block {n}{named} holds the last deploy receipt, block {last[rpc]}",
              n is not None and last[rpc] is not None and n >= last[rpc])
        if not a.rehearsal:
            f = block_number(rpc, 'finalized')
            check(f"{rpc}: block {n} is final, the finalized head is {f}", n is not None and f is not None and n <= f)

    expect_fill = {'PageCard': None, 'PageNFT': a.card, 'SubpageRegistrar': a.nft}
    for c in CONTRACTS:
        code = bytearray.fromhex(art[c]['deployedBytecode']['object'][2:])
        refs = art[c]['deployedBytecode'].get('immutableReferences', {})
        fill = expect_fill[c]
        if fill is None:
            check(f"{c}: no immutable id", len(refs) == 0, refs)
        else:
            check(f"{c}: exactly one immutable id", len(refs) == 1, list(refs))
            w = bytes.fromhex(word(fill))
            for ranges in refs.values():
                for r in ranges:
                    if not check(f"{c}: an immutable range is 32 bytes", r['length'] == 32, r):
                        continue
                    code[r['start']:r['start'] + 32] = w
        for rpc in a.rpc:
            at = str(read[rpc]) if read[rpc] is not None else a.block
            rc, live, e = run(['cast', 'code', addrs[c], '--block', at, '--rpc-url', rpc])
            live_b = bytes.fromhex(live[2:]) if rc == 0 and live.startswith('0x') else b''
            check(f"{c} at {addrs[c]} on {rpc} at block {at}: has code", len(live_b) > 0, e)
            diff = next((i for i in range(min(len(live_b), len(code))) if live_b[i] != code[i]), None)
            check(f"{c} at {addrs[c]} on {rpc} at block {at}: the code equals the build byte for byte, metadata tail included",
                  bytes(code) == live_b, f"lengths {len(live_b)} and {len(code)}, first difference at {diff}")

    # a name minted or sent to the registrar's address before it had code still shows at the block that created it
    for rpc in a.rpc:
        at = made.get(rpc)
        rc, o, e = (run(['cast', 'call', a.nft, 'balanceOf(address)(uint256)', a.registrar, '--block', str(at),
                         '--rpc-url', rpc]) if at is not None else (1, '', 'no receipt of the registrar'))
        check(f"{rpc}: PageNFT holds no name for the registrar at block {at}, the block that created it",
              rc == 0 and o == '0', o + e)

    print()
    print("G-20 PASS" if not fails else f"G-20 FAIL: {len(fails)} checks: {fails}")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
