#!/usr/bin/env python3
# The sign-off gates of the three contracts. Every gate prints PASS or FAIL for each of its checks,
# and a run of the gates exits non zero unless every gate ran and every check passed. A gate that stops
# on an error, such as a failed forge call, prints a FAIL for itself and the gates after it still run.
# Run from a clean checkout of the commit to sign off, in a shell with no FOUNDRY_ or DAPP_ variable set,
# because the gates build in out and cache.
# G-20 compares the deployed code and runs on deploy day with gates/deployed.py.
# Source checks read either the code with comments removed or the raw file. A check that reads the raw
# file also matches its pattern in comments, whether or not its name says comments included.
# G-13 reads the proof results recorded in gates/proof-results.json, which --record-proofs writes from
# the logs of tools/proofs/run_one.sh.
# Usage: python3 gates/gates.py [--list] [--only G-1,G-2] [--skip G-12,G-13] [--no-deep]
#        python3 gates/gates.py --record-proofs LOGDIR [LOGDIR ...]
import argparse, glob, hashlib, itertools, json, os, re, shutil, subprocess, sys, tempfile, time

# G-43 reads Part 1 of the review record (the source sha256 values, the build hashes, byte counts, sizes,
# immutable ranges and forge --version), partly with the code of deployed.py in this folder. No bytecode
# cache is written, so git status stays clean after a run
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deployed

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
gates_dir = os.path.join(root, 'gates')
fails = []

# the fixed fuzz seed of the gas snapshot, so that a fresh snapshot equals .gas-snapshot byte for byte (see g14 for
# the one count left out)
SNAPSHOT_SEED = '0x2a'
SNAPSHOT_CMD = ['forge', 'snapshot', '--fuzz-seed', SNAPSHOT_SEED]

# the fixed fuzz seed of the deep campaigns, so that every deep run of the gates starts from the same seed (forge
# 1.8.7 still does not repeat an invariant campaign call for call, so the call counts can differ a little per run)
DEEP_SEED = '0x07f889f917e7d3951ee16c8b11ca1c251ffced78cdec90c12fbf85549894484b'
DEEP_CMD = ['forge', 'test', '--fuzz-seed', DEEP_SEED]
# every handler action of a deep invariant campaign must go through at least this many times; a call that reverted
# or was discarded does not count
DEEP_MIN_CALLS = 100

# the git tree of each library folder; solady and soledge ship in the bytecode, forge-std runs every test and the deploy script
LIB_TREES = {'solady': '5f5c62dc0f41c8e53d73d5e6462bc9ed3cf1103c', 'soledge': 'ef8e1038ed7bed3b25978d2d236e67c5a104ae99',
             'forge-std': 'fdebd8d87fdd3939cb7e1d1b1b5f3d528d7e9aba'}
LIB_REMAPPINGS = [f'{lib}/=lib/{lib}/src/' for lib in LIB_TREES]
CONTRACTS = ('PageNFT', 'PageCard', 'SubpageRegistrar')


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + str(detail)) if detail and not ok else ''}")
    if not ok:
        fails.append(name)
    return ok


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def functions(src):
    # name to a list of (header, body) for every function with a body
    out = {}
    for m in re.finditer(r'\bfunction\s+(\w+)\s*\(', src):
        name = m.group(1)
        i = src.find('{', m.end())
        semi = src.find(';', m.end())
        if i == -1 or (semi != -1 and semi < i):
            continue
        depth, j = 0, i
        while True:
            if src[j] == '{':
                depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.setdefault(name, []).append((src[m.start():i], src[i + 1:j]))
    return out


def one(fn, name, first_param=None):
    # the body of the only function of that name, or of the overload whose first parameter has that type
    fs = fn.get(name, [])
    if first_param:
        fs = [f for f in fs if re.match(r'function\s+\w+\s*\(\s*' + first_param + r'\b', f[0])]
    if len(fs) != 1:
        raise KeyError(f"{name}({first_param or ''}) found {len(fs)} times")
    return fs[0][1]


def last_statement(body):
    stmts = [x.strip() for x in body.strip().rstrip('}').split(';') if x.strip()]
    return stmts[-1] if stmts else ''


def flat(s):
    return re.sub(r'\s+', ' ', s).strip()


STRING = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def statements(body):
    # the statements of a body itself, each flattened. An if with its else, a loop, a try with its catch and a block
    # are one statement each, so a statement inside one of them is never on the list
    out, cur, depth, i = [], '', 0, 0
    while i < len(body):
        m = STRING.match(body, i) if body[i] in '"\'' else None
        if m:
            cur += m.group(0)
            i = m.end()
            continue
        ch = body[i]
        cur += ch
        i += 1
        if ch in '({[':
            depth += 1
        elif ch in ')}]':
            depth -= 1
            if ch == '}' and depth == 0 and not re.match(r'\s*(else|while|catch)\b', body[i:]):
                out.append(flat(cur))
                cur = ''
        elif ch == ';' and depth == 0:
            out.append(flat(cur))
            cur = ''
    if cur.strip():
        out.append(flat(cur))
    return out


def unconditional(body, stmt, exits=()):
    # stmt is a statement of the body itself, and no statement before it can return, apart from those in exits.
    # Returns what is wrong, or None
    st = statements(body)
    if stmt not in st:
        return 'not a statement of the body itself: under an if, else or loop, or written differently'
    early = [s for s in st[:st.index(stmt)] if re.search(r'\b(return|assembly)\b', s) and s not in exits]
    return f'a return comes before it: {early}' if early else None


def nospace(s):
    return re.sub(r'\s+', '', s)


def count_in(fn, pattern):
    c = {n: sum(len(re.findall(pattern, b)) for _, b in fs) for n, fs in fn.items()}
    return {n: k for n, k in c.items() if k}


def run(cmd, env_extra=None, timeout=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    p = subprocess.run(cmd, cwd=root, capture_output=True, text=True, env=env, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def inspect(contract, field):
    rc, out = run(['forge', 'inspect', f'src/{contract}.sol:{contract}', field, '--json'])
    if rc != 0:
        # an artefact built without the storage layout makes forge inspect fail, so it gets one forced rebuild
        rc, out = run(['forge', 'inspect', f'src/{contract}.sol:{contract}', field, '--json', '--force'])
    if rc != 0:
        # raised, not exited, so that the gate records a FAIL and the next gates still run
        raise RuntimeError(f"forge inspect {contract} {field} failed:\n{out}")
    return json.loads(out[out.index('{'):out.rindex('}') + 1])


def expected(fname):
    return json.load(open(os.path.join(gates_dir, fname)))


def norm_layout(lay):
    # drops the AST ids, which change with any edit elsewhere in the compile job, and keeps every
    # label, slot, offset, type and struct member
    strip = lambda t: re.sub(r'\)\d+(_storage|_memory)', r')\1', t)
    st = [{'label': e['label'], 'slot': e['slot'], 'offset': e['offset'], 'type': strip(e['type'])} for e in lay['storage']]
    ty = {}
    for k, v in (lay.get('types') or {}).items():
        d = {'encoding': v['encoding'], 'label': strip(v['label']), 'numberOfBytes': v['numberOfBytes']}
        for f in ('key', 'value', 'base'):
            if f in v:
                d[f] = strip(v[f])
        if 'members' in v:
            d['members'] = [{'label': m['label'], 'slot': m['slot'], 'offset': m['offset'], 'type': strip(m['type'])}
                            for m in v['members']]
        ty[strip(k)] = d
    return {'storage': st, 'types': dict(sorted(ty.items()))}


def declarations(src):
    # every error and event declared in the file, with its parameter list and indexed markers
    out = []
    for m in re.finditer(r'\b(error|event)\s+(\w+)\s*\(([^)]*)\)\s*;', src):
        params = ', '.join(flat(p) for p in m.group(3).split(',') if p.strip())
        out.append(f"{m.group(1)} {m.group(2)}({params})")
    return sorted(out)


raw = {n: open(os.path.join(root, 'src', n + '.sol')).read() for n in CONTRACTS}
nft, card, reg = (strip_comments(raw[n]) for n in ('PageNFT', 'PageCard', 'SubpageRegistrar'))
fn = functions(nft)
fr = functions(reg)
fc = functions(card)
rawfn = functions(raw['PageNFT'])
state = {}


def files_under(*dirs):
    for d in dirs:
        for dp, _, names in os.walk(os.path.join(root, d)):
            for n in names:
                yield os.path.join(dp, n)


def grep_files(pattern, dirs, flags=0):
    hits = []
    for f in files_under(*dirs):
        try:
            text = open(f, errors='ignore').read()
        except OSError:
            continue
        for i, line in enumerate(text.split('\n'), 1):
            if re.search(pattern, line, flags):
                hits.append(f"{os.path.relpath(f, root)}:{i}")
    return hits


# ---------------------------------------------------------------- gates

def g01():
    hits = grep_files(r'forceSafeTransferETH|forceApprove', ['src'])
    check("no forceSafeTransferETH or forceApprove in src", not hits, hits)


def g02():
    check("PageNFT: safeTransferETH appears exactly twice", nft.count('safeTransferETH') == 2, nft.count('safeTransferETH'))
    check("PageNFT: one inside withdraw", one(fn, 'withdraw').count('safeTransferETH') == 1)
    check("PageNFT: one inside _refundExcess, paying msg.sender",
          'safeTransferETH(msg.sender' in nospace(one(fn, '_refundExcess')))
    check("PageNFT: _refundExcess is declared once and called twice", nft.count('_refundExcess(') == 3)
    check("PageNFT: the last statement of _registerTopLevel is _refundExcess(total)",
          nospace(last_statement(one(fn, '_registerTopLevel'))) == '_refundExcess(total)')
    check("PageNFT: the last statement of renew is _refundExcess(fee)",
          nospace(last_statement(one(fn, 'renew'))) == '_refundExcess(fee)')
    check("PageNFT: there is no revealFor", 'revealFor' not in raw['PageNFT'])
    check("PageNFT: exactly one reveal and one revealTrial", len(fn['reveal']) == 1 and len(fn['revealTrial']) == 1)
    for f in ('reveal', 'revealTrial'):
        check(f"PageNFT: {f} is the single statement return _registerTopLevel(label, owner, referrerId, secret)",
              nospace(one(fn, f)) == 'return_registerTopLevel(label,owner,referrerId,secret);')
    check("SubpageRegistrar: safeTransferETH appears exactly twice", reg.count('safeTransferETH') == 2)
    check("SubpageRegistrar: one is the last statement of _payProceeds",
          'safeTransferETH(to,amount)' in nospace(last_statement(one(fr, '_payProceeds'))))
    check("SubpageRegistrar: one is in the last statement of _sell, paying msg.sender",
          'safeTransferETH(msg.sender' in nospace(last_statement(one(fr, '_sell'))))
    check("SubpageRegistrar: _payProceeds is declared once and called twice", reg.count('_payProceeds(') == 3)
    check("SubpageRegistrar: claimProceeds is return _payProceeds(msg.sender, to)",
          nospace(one(fr, 'claimProceeds')) == 'return_payProceeds(msg.sender,to);')
    check("SubpageRegistrar: claimProceedsFor is return _payProceeds(account, account)",
          nospace(one(fr, 'claimProceedsFor')) == 'return_payProceeds(account,account);')
    check("SubpageRegistrar: registerSubpageFor is the single statement return _sell(...)",
          nospace(one(fr, 'registerSubpageFor')).startswith('return_sell(') and one(fr, 'registerSubpageFor').count(';') == 1)
    check("SubpageRegistrar: revealSubpageFor is the single statement return _sell(...)",
          nospace(one(fr, 'revealSubpageFor')).startswith('return_sell(') and one(fr, 'revealSubpageFor').count(';') == 1)
    check("PageCard: no safeTransferETH", 'safeTransferETH' not in card)


def g03():
    hits = grep_files(r'^\s*(receive|fallback)\s*\(', ['src'])
    check("no receive or fallback in src", not hits, hits)


def g04():
    dead = (r'REFERRAL_BPS|referralEarned|ReferralPaid|_payReferral|_handleReferral|ETHER_NODE|subdomain|Subdomain|'
            r'SUBDOMAIN|_getDepth|WithDepth|TooDeep|withdrawFor|_withdrawTo|NothingOwed|OverpaymentCredited|isAsciiLabel')
    hits = grep_files(dead, ['src', 'test', 'script', 'proofs'])
    check("no dead vocabulary in src, test, script and proofs", not hits, hits[:10])
    hits = grep_files(r'\.ether\b|revealFor', ['src', 'script'])
    check("no .ether suffix and no revealFor in src and script", not hits, hits)
    check("PageNFT: no _credit(msg.sender", not re.search(r'_credit\(msg\.sender', raw['PageNFT']))
    check("SubpageRegistrar: no proceedsOf[msg.sender] +=", not re.search(r'proceedsOf\[msg\.sender\] *\+=', raw['SubpageRegistrar']))
    check("PageNFT and SubpageRegistrar: no UTF-8 text",
          not re.search(r'utf[-_ ]?8', raw['PageNFT'] + raw['SubpageRegistrar'], re.I))
    check("PageNFT, PageCard and SubpageRegistrar: no ENS text",
          not re.search(r'\bens\b|ensip', raw['PageNFT'] + raw['PageCard'] + raw['SubpageRegistrar'], re.I))
    hits = grep_files(r'\bENS\b|ENSIP', ['test', 'script', 'proofs'])
    check("no ENS text in test, script and proofs", not hits, hits[:10])
    hits = grep_files(r'\b(ERC|EIP)[ -][0-9]', ['src', 'test', 'script', 'proofs'])
    check("ERC and EIP numbers written joined, like ERC721, in src, test, script and proofs", not hits, hits[:10])
    check("SubpageRegistrar: no escrow, flash or receiver hook text",
          not re.search(r'escrow|flash|onERC721Received|IERC721Receiver|_custody', raw['SubpageRegistrar'], re.I))


def g05():
    w = count_in(fn, r'owed\[[^\]]*\]\s*(\+=|-=|=(?!=))|delete\s+owed\[')
    check("owed is written only in _credit (+=) and withdraw (= 0)", w == {'_credit': 1, 'withdraw': 1}, w)
    check("_credit adds and withdraw zeroes", 'owed[to] += amount;' in one(fn, '_credit')
          and 'owed[account] = 0;' in one(fn, 'withdraw'))


def g06():
    for c in CONTRACTS:
        want = [l for l in open(os.path.join(gates_dir, f'{c}.declarations.txt')).read().split('\n') if l.strip()]
        have = declarations(strip_comments(raw[c]))
        check(f"{c}.sol declares exactly the errors and events of gates/{c}.declarations.txt ({len(want)})",
              have == sorted(want), f"missing {sorted(set(want) - set(have))} extra {sorted(set(have) - set(want))}")


def g07():
    rc, out = run(['forge', 'test', '--match-test', 'test_check_root_constant'])
    m = re.search(r'(\d+) tests passed, (\d+) failed', out)
    check("forge test --match-test test_check_root_constant passes", rc == 0 and m and int(m.group(1)) >= 1
          and m.group(2) == '0', out[-800:])


def g08():
    bad = [f"{c}: {l.strip()}" for c in CONTRACTS for l in raw[c].split('\n') if 'pragma solidity' in l
           and l.strip() != 'pragma solidity 0.8.38;']
    check("every pragma in src is pragma solidity 0.8.38;", not bad, bad)


def g09():
    for v in ('FOUNDRY_PROFILE',):
        check(f"{v} is not set", v not in os.environ)
    profiles = re.findall(r'^\[profile\.(\w+)[\].]', open(os.path.join(root, 'foundry.toml')).read(), re.M)
    names = sorted(set(profiles))
    check("foundry.toml has exactly the profiles default, deep and proofs", names == ['deep', 'default', 'proofs'], names)
    cfg = {}
    for p in names:
        rc, out = run(['forge', 'config', '--json'], {'FOUNDRY_PROFILE': p})
        if not check(f"forge config for profile {p}", rc == 0, out[-400:]):
            return
        cfg[p] = json.loads(out[out.index('{'):out.rindex('}') + 1])
    keys = ('solc', 'optimizer', 'optimizer_runs', 'via_ir', 'evm_version', 'bytecode_hash', 'cbor_metadata', 'src', 'libs',
            'remappings')
    sets = {p: tuple(json.dumps(cfg[p].get(k), sort_keys=True) for k in keys) for p in names}
    check("default builds the deploy settings into out and cache",
          cfg['default']['cache_path'] == 'cache' and cfg['default']['out'] == 'out' and cfg['default']['optimizer'] is True
          and cfg['default']['optimizer_runs'] == 200 and cfg['default']['via_ir'] is True
          and cfg['default']['evm_version'] == 'prague' and str(cfg['default'].get('solc')) == '0.8.38',
          {k: cfg['default'].get(k) for k in ('cache_path', 'out', 'optimizer', 'optimizer_runs', 'via_ir', 'evm_version', 'solc')})
    check("deep shares out and cache with default and has the same compiler settings",
          sets['deep'] == sets['default'] and cfg['deep']['cache_path'] == 'cache' and cfg['deep']['out'] == 'out')
    check("default and deep run each test as one transaction (isolate off, as the tests and the deploy script expect)",
          cfg['default'].get('isolate') is False and cfg['deep'].get('isolate') is False,
          {p: cfg[p].get('isolate') for p in ('default', 'deep')})
    check("proofs builds with the optimizer off into its own out-proofs and cache-proofs",
          cfg['proofs']['optimizer'] is False and cfg['proofs']['cache_path'] == 'cache-proofs'
          and cfg['proofs']['out'] == 'out-proofs')
    check("proofs builds with dynamic test linking off, so a proof's `new` of a source contract stays a plain create "
          "that Halmos can run (Halmos 0.3.3 has no deployCode cheat code)",
          cfg['proofs'].get('dynamic_test_linking') is False, cfg['proofs'].get('dynamic_test_linking', 'absent'))
    for a in names:
        for b in names:
            if a < b and sets[a] != sets[b]:
                check(f"profiles {a} and {b} build differently, so their out and cache paths differ",
                      cfg[a]['cache_path'] != cfg[b]['cache_path'] and cfg[a]['out'] != cfg[b]['out'])
    rc1, out1 = run(['forge', 'clean'])
    rc2, out2 = run(['forge', 'build', '--sizes'])
    state['sizes'] = (rc2, out2)
    if check("forge clean && forge build --sizes with no profile set", rc1 == 0 and rc2 == 0, (out1 + out2)[-800:]):
        state['build'] = read_build()


def g10():
    if 'sizes' not in state:
        rc, out = run(['forge', 'build', '--sizes'])
        state['sizes'] = (rc, out)
    rc, out = state['sizes']
    check("forge build --sizes exits zero", rc == 0)
    # S1 of DEPLOY.md tells the operator to stop unless the build shows its size rows, so they must be this build's
    doc = open(os.path.join(root, 'DEPLOY.md')).read()
    for c in CONTRACTS:
        m = re.search(r'^\|\s*' + c + r'\s*\|\s*([\d,]+)\s*\|\s*([\d,]+)\s*\|', out, re.M)
        if not check(f"{c} has a size row", m is not None):
            continue
        rt, ic = int(m.group(1).replace(',', '')), int(m.group(2).replace(',', ''))
        check(f"{c}: {rt} bytes of runtime under 24576 and {ic} bytes of initcode under 49152", rt < 24576 and ic < 49152)
        rows = re.findall(r'^\| ' + c + r' \| ([\d,]+) \| ([\d,]+) \|$', doc, re.M)
        check(f"{c}: the size row in S1 of DEPLOY.md is {rt:,} | {ic:,}", rows == [(f'{rt:,}', f'{ic:,}')], rows)


def g11():
    for c in CONTRACTS:
        rc, out = run(['forge', 'verify-contract', '--show-standard-json-input', '0x' + '00' * 19 + '01',
                       f'src/{c}.sol:{c}'])
        if not check(f"{c}: forge verify-contract --show-standard-json-input", rc == 0, out[-400:]):
            continue
        j = json.loads(out[out.index('{'):out.rindex('}') + 1])
        s = j.get('settings', {})
        md = s.get('metadata', {})
        check(f"{c}: optimizer on with 200 runs, viaIR, prague",
              s.get('optimizer') == {'enabled': True, 'runs': 200} and s.get('viaIR') is True and s.get('evmVersion') == 'prague',
              {k: s.get(k) for k in ('optimizer', 'viaIR', 'evmVersion')})
        check(f"{c}: metadata hash ipfs and the CBOR tail kept",
              md.get('bytecodeHash', 'ipfs') == 'ipfs' and md.get('appendCBOR', True) is True, md)
    a = json.load(open(os.path.join(root, 'out', 'PageNFT.sol', 'PageNFT.json')))
    meta = a.get('metadata') or json.loads(a['rawMetadata'])
    check("the build used solc 0.8.38", meta['compiler']['version'].startswith('0.8.38+'), meta['compiler']['version'])


def g12(deep=True):
    rc, out = run(['forge', 'test'])
    m = re.search(r'Ran (\d+) test suites.*?(\d+) tests passed, (\d+) failed, (\d+) skipped', out, re.S)
    check("forge test is all green", rc == 0 and m and m.group(3) == '0' and m.group(4) == '0',
          m.group(0) if m else out[-800:])
    if m:
        print(f"      {m.group(2)} tests passed in {m.group(1)} suites")
    os.makedirs(os.path.join(root, 'logs'), exist_ok=True)
    open(os.path.join(root, 'logs', 'gate-G-12-test.txt'), 'w').write(out)
    if not deep:
        check("FOUNDRY_PROFILE=deep forge test was run", False, "skipped with --no-deep")
        return
    cmd = 'FOUNDRY_PROFILE=deep ' + ' '.join(DEEP_CMD)
    print(f"      deep run: {cmd}")
    print(f"      deep fuzz seed: {DEEP_SEED}")
    rc, out = run(DEEP_CMD, {'FOUNDRY_PROFILE': 'deep'})
    open(os.path.join(root, 'logs', 'gate-G-12-deep.txt'), 'w').write(f"# {cmd}\n# fuzz seed {DEEP_SEED}\n\n{out}")
    m = re.search(r'Ran (\d+) test suites.*?(\d+) tests passed, (\d+) failed, (\d+) skipped', out, re.S)
    check(f"FOUNDRY_PROFILE=deep forge test with fuzz seed {DEEP_SEED} is all green, per selector counts in "
          "logs/gate-G-12-deep.txt", rc == 0 and m and m.group(3) == '0' and m.group(4) == '0', m.group(0) if m else out[-800:])
    check_deep_calls(out)


def invariant_calls(out):
    # each invariant test of a forge test log, as Suite.test, with the rows of its table of calls per handler
    # selector: (contract, selector, calls that went through). The table counts every call in Calls, and a call that
    # reverted also in Reverts, or one a failed vm.assume discarded also in Discards, never in both, so the calls
    # that went through are Calls less Reverts and Discards. Forge 1.5 runs each invariant as its own campaign and
    # prints "[PASS] invariant_x(runs: ...)" and its table; forge 1.8 runs the invariants of a contract as one campaign,
    # prints "[PASS] invariant_x" for each and one table after them, which then holds the calls of each of them.
    tests, cur, suite = {}, [], ''
    for line in out.split('\n'):
        m = re.match(r'Ran \d+ tests? for \S+:(\w+)', line)
        if m:
            suite, cur = m.group(1), []
            continue
        if line.startswith('[PASS') or line.startswith('[FAIL'):
            m = re.match(r'\[PASS\] (invariant_\w+)(\(|\s*$)', line)
            name = f"{suite}.{m.group(1)}" if m else None
            # a test with its own campaign starts a new one; a bare name joins the shared campaign of its contract
            if not m or m.group(2) == '(':
                cur = []
            if name:
                tests[name] = []
                cur.append(name)
            continue
        m = re.match(r'\|\s*(\w+)\s*\|\s*(\w+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$', line)
        if m and cur:
            for name in cur:
                tests[name].append((m.group(1), m.group(2), int(m.group(3)) - int(m.group(4)) - int(m.group(5))))
        elif line.startswith('Suite result'):
            cur = []
    return tests


def invariant_functions():
    # every invariant test of the suite, as Contract.function, read from the test sources: forge runs each public
    # or external function of a test contract whose name starts with invariant or statefulFuzz as a campaign
    found = []
    for f in sorted(files_under('test')):
        if not f.endswith('.sol'):
            continue
        src = strip_comments(open(f, errors='ignore').read())
        heads = [(m.start(), m.group(1), m.group(2)) for m in
                 re.finditer(r'^\s*(abstract\s+contract|contract|library|interface)\s+(\w+)', src, re.M)]
        for m in re.finditer(r'\bfunction\s+((?:invariant|statefulFuzz)\w*)\s*\([^)]*\)([^{;]*)\{', src):
            owner = [h for h in heads if h[0] < m.start()]
            if owner and owner[-1][1] == 'contract' and re.search(r'\b(public|external)\b', m.group(2)):
                found.append(f"{owner[-1][2]}.{m.group(1)}")
    return found


def check_deep_calls(out):
    tests = invariant_calls(out)
    bare = sorted(t for t, rows in tests.items() if not rows)
    check("every invariant campaign of the deep run printed its calls per handler action", tests and not bare,
          bare[:10] if tests else "no invariant test in the log")
    # a campaign the reading skips would escape the minimum below, so the log must hold one for each function
    want = invariant_functions()
    check(f"the deep log holds as many invariant campaigns as the suite has invariant functions, {len(want)}",
          len(tests) == len(want), f"{len(tests)} campaigns read; functions with none "
          f"{sorted(set(want) - set(tests))[:10]}, campaigns of no function {sorted(set(tests) - set(want))[:10]}")
    rows = [(n, t, f"{c}.{s}") for t, rs in tests.items() for c, s, n in rs]
    if rows:
        low = min(rows)
        print(f"      {len(tests)} invariant campaigns of {len(want)} invariant functions, {len(rows)} handler actions, "
              f"the fewest calls that went through {low[0]}, {low[2]} in {low[1]}")
    few = sorted(r for r in rows if r[0] < DEEP_MIN_CALLS)
    check(f"every handler action of the deep invariant campaigns went through at least {DEEP_MIN_CALLS} times, "
          "reverted and discarded calls not counted", rows and not few, few[:10])


PROOF_TIERS = ('tier1.txt', 'tier2.txt', 'tier3.txt', 'tier4.txt')
PROOF_RESULTS = os.path.join(gates_dir, 'proof-results.json')
RERUN = ["FOUNDRY_PROFILE=proofs forge build",
         "tools/proofs/run_one.sh <tag> <Contract> <function> <seconds> [loop bound]   # one line of a tier file",
         "tools/proofs/run_queue.sh tools/proofs/tier1.txt 4                          # a whole tier, four at a time",
         "python3 gates/gates.py --record-proofs logs/halmos [more log folders]        # rewrite gates/proof-results.json"]


def proof_lines(name):
    # the lines of a list file in tools/proofs, as dicts
    out = []
    for line in open(os.path.join(root, 'tools', 'proofs', name)):
        p = line.split()
        if p and not p[0].startswith('#'):
            out.append({'tag': p[0], 'contract': p[1], 'function': p[2], 'limit': int(p[3]),
                        'loop': int(p[4]) if len(p) > 4 else 4, 'list': name})
    return out


def project_imports(rel, base=None):
    # rel and every project file it imports, directly or not, as paths relative to the root; remapped
    # library imports are left out, as G-28 pins the library trees
    base = base or root
    seen, todo = set(), [os.path.normpath(rel)]
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for m in re.finditer(r'^\s*import\s[^;]*?"(\.{1,2}/[^"]+)"\s*;', open(os.path.join(base, f)).read(), re.M):
            todo.append(os.path.normpath(os.path.join(os.path.dirname(f), m.group(1))))
    return seen


def proof_files():
    # the files a proof result depends on: the three sources, every file in proofs and its folders, and every project
    # file they import
    files = {f'src/{n}.sol' for n in CONTRACTS}
    for dp, dirs, names in os.walk(os.path.join(root, 'proofs')):
        dirs.sort()
        for f in sorted(names):
            files |= project_imports(os.path.relpath(os.path.join(dp, f), root))
    return sorted(files)


def proof_contracts():
    # every Test contract of the .t.sol files in proofs and its folders, with its file and its proof functions, inherited
    # ones included
    decl = {}
    for rel in proof_files():
        if not rel.endswith('.sol'):
            continue
        s = strip_comments(open(os.path.join(root, rel)).read())
        heads = list(re.finditer(r'\b(?:abstract\s+)?(?:contract|interface|library)\s+(\w+)(?:\s+is\s+([^{]+))?\s*\{', s))
        for i, m in enumerate(heads):
            body = s[m.end():heads[i + 1].start() if i + 1 < len(heads) else len(s)]
            bases = [b.strip().split('(')[0] for b in (m.group(2) or '').split(',') if b.strip()]
            fns = set(re.findall(r'function\s+((?:test_)?check_\w+)\s*\(', body))
            decl[m.group(1)] = (rel, bases, fns)

    def all_fns(c, depth=0):
        if c not in decl or depth > 20:
            return set()
        rel, bases, fns = decl[c]
        return fns.union(*[all_fns(b, depth + 1) for b in bases])

    return {c: (rel, all_fns(c)) for c, (rel, _, _) in decl.items()
            if c.endswith('Test') and rel.startswith('proofs/') and rel.endswith('.t.sol')}


def sha256(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


def read_raw(f):
    # one log of tools/proofs/run_one.sh
    s = re.sub(r'\x1b\[[0-9;]*m', '', open(f, errors='replace').read())
    m = re.search(r'start (\S+ \S+) (\w+) (\w+) alarm (\d+)s', s.split('\n', 1)[0])
    if not m:
        return None
    fn = m.group(3)
    r = re.search(r'\[(PASS|FAIL|TIMEOUT|ERROR)\] ' + fn + r'\(.*?\(paths: (\d+), time: ([0-9.]+)s', s)
    w = re.search(r'exit (\d+) wall (\d+)s', s)
    result = r.group(1) if r else ('ALARM-TIMEOUT' if w and w.group(1) == '142' else 'NO-RESULT' if w else 'RUNNING')
    return {'contract': m.group(2), 'function': fn, 'start': m.group(1),
            'started': time.mktime(time.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')), 'alarm': int(m.group(4)),
            'result': result, 'paths': int(r.group(2)) if r else None, 'halmos_seconds': float(r.group(3)) if r else None,
            'exit': int(w.group(1)) if w else None, 'wall_seconds': int(w.group(2)) if w else None,
            'loop_bound_hit': 'loop unrolling bound' in s, 'counterexample': 'Counterexample' in s,
            'warning': bool(re.search(r'^\s*WARNING', s, re.M)), 'log_sha256': sha256(f)}


def record_proofs(log_dirs):
    # writes gates/proof-results.json from the logs of run_one.sh. Each log folder is <copy>/logs/halmos
    # of a copy of this folder. A run counts only when every file its proof depends on is in that copy
    # with the same sha256 as here and was last changed before the run started. The latest run that
    # counts is recorded for each proof of the tier files.
    rc, out = run(['halmos', '--version'])
    version = out.strip().split()[-1] if rc == 0 else 'unknown'
    contracts = proof_contracts()
    current = {f: sha256(os.path.join(root, f)) for f in proof_files()}
    deps = {c: sorted(project_imports(rel)) for c, (rel, _) in contracts.items()}
    runs, ignored = {}, []
    for d in log_dirs:
        d = os.path.abspath(d)
        copy = os.path.dirname(os.path.dirname(d))
        if os.path.relpath(d, copy) != os.path.join('logs', 'halmos'):
            sys.exit(f"{d} is not a <copy>/logs/halmos folder")
        label = 'repo' if copy == root else '/'.join(copy.split(os.sep)[-2:])
        for f in sorted(glob.glob(os.path.join(d, '*.raw'))):
            r = read_raw(f)
            if not r:
                continue
            r['log'] = f"{label}/logs/halmos/{os.path.basename(f)}"
            why = None
            if r['contract'] not in deps:
                why = 'no such proof contract here'
            else:
                for dep in deps[r['contract']]:
                    p = os.path.join(copy, dep)
                    if not os.path.exists(p) or sha256(p) != current[dep]:
                        why = f'{dep} differs from this folder'
                        break
                    if os.path.getmtime(p) > r['started']:
                        why = f'{dep} changed after the run started'
                        break
            if why:
                ignored.append(f"{r['log']}: {why}")
                continue
            runs.setdefault((r['contract'], r['function']), []).append(r)
    proofs = []
    for line in [l for t in PROOF_TIERS for l in proof_lines(t)]:
        rs = sorted(runs.get((line['contract'], line['function']), []), key=lambda r: r['started'])
        e = dict(line)
        if rs:
            last = rs[-1]
            e.update({k: last[k] for k in ('result', 'paths', 'halmos_seconds', 'wall_seconds', 'start', 'alarm',
                                            'loop_bound_hit', 'counterexample', 'warning', 'log', 'log_sha256')})
            e['earlier_runs'] = [f"{r['result']} {r['log']}" for r in rs[:-1]]
        else:
            e['result'] = 'NO-RESULT'
        e['halmos'] = version
        proofs.append(e)
    doc = {'about': 'Halmos results of every proof of tools/proofs/tier1.txt to tier4.txt, and the sha256 of every '
                    'file they depend on. Written by python3 gates/gates.py --record-proofs; read by gate G-13. '
                    'The Halmos version is the one installed when the file was written, as the logs do not print it.',
           'rerun': RERUN, 'files': current, 'proofs': proofs}
    with open(PROOF_RESULTS, 'w') as fh:
        json.dump(doc, fh, indent=1)
        fh.write('\n')
    counts = {}
    for e in proofs:
        counts[e['result']] = counts.get(e['result'], 0) + 1
    print(f"wrote {os.path.relpath(PROOF_RESULTS, root)}: {len(proofs)} proofs, "
          + ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    for x in ignored:
        print(f"  ignored {x}")
    return 0 if counts.get('PASS', 0) == len(proofs) else 1


def g13():
    # the proofs run with tools/proofs; this gate reads the results recorded in gates/proof-results.json
    print("      to re-run a proof and record it:")
    for line in RERUN:
        print(f"        {line}")
    tiers = [l for t in PROOF_TIERS for l in proof_lines(t)]
    listed = tiers + proof_lines('umbrella.txt')
    keys = [(l['contract'], l['function']) for l in listed]
    twice = sorted({f"{c}.{f}" for c, f in keys if keys.count((c, f)) > 1})
    check("no proof is listed twice in the tier files and umbrella.txt", not twice, twice[:10])
    defined = {(c, f) for c, (_, fns) in proof_contracts().items() for f in fns}
    unlisted = sorted(f"{c}.{f}" for c, f in defined - set(keys))
    check("every proof function in proofs is listed in a tier file or umbrella.txt", not unlisted, unlisted[:10])
    gone = sorted(f"{c}.{f}" for c, f in set(keys) - defined)
    check("every listed proof exists in proofs", not gone, gone[:10])
    if not check(f"{os.path.relpath(PROOF_RESULTS, root)} exists", os.path.exists(PROOF_RESULTS)):
        return
    doc = json.load(open(PROOF_RESULTS))
    rec = {(e['contract'], e['function']): e for e in doc['proofs']}
    missing, bad = [], []
    for l in tiers:
        e = rec.get((l['contract'], l['function']))
        if not e:
            missing.append(l)
        elif (e['result'] != 'PASS' or e.get('loop_bound_hit') or e.get('counterexample') or e.get('warning')
              or (e['tag'], e['limit'], e['loop']) != (l['tag'], l['limit'], l['loop'])):
            bad.append(l)
    extra = sorted(f"{c}.{f}" for c, f in set(rec) - {(l['contract'], l['function']) for l in tiers})

    def why(l):
        e = rec[(l['contract'], l['function'])]
        flags = [k for k in ('loop_bound_hit', 'counterexample', 'warning') if e.get(k)]
        if (e['tag'], e['limit'], e['loop']) != (l['tag'], l['limit'], l['loop']):
            flags.append(f"recorded for {e['tag']} {e['limit']}s loop {e['loop']}")
        return ' '.join([l['function'], e['result']] + flags)

    check("every proof of the tier files has a result recorded", not missing,
          f"{len(missing)} without one, first {[l['function'] for l in missing[:5]]}")
    check("every recorded result is PASS with no counterexample, warning or loop bound hit, for the listed limit and loop bound",
          not bad, [why(l) for l in bad[:10]])
    check("every recorded proof is in a tier file", not extra, extra[:10])
    flaky = sorted(f"{e['function']} {r}" for e in doc['proofs'] for r in e.get('earlier_runs', []) if not r.startswith('PASS '))
    check("no earlier run on the same files gave another result", not flaky, flaky[:10])
    files = proof_files()
    changed = sorted(f for f, h in doc['files'].items()
                     if not os.path.exists(os.path.join(root, f)) or sha256(os.path.join(root, f)) != h)
    unrecorded = sorted(set(files) - set(doc['files']))
    check("every recorded file hash equals the current file", not changed, changed[:10])
    check("every source, proof and imported harness file has a recorded hash", not unrecorded, unrecorded[:10])
    for l in (missing + bad)[:10]:
        print(f"      re-run: tools/proofs/run_one.sh {l['tag']} {l['contract']} {l['function']} {l['limit']} {l['loop']}")
    if changed or unrecorded:
        print("      a changed file needs every proof that depends on it run again, then --record-proofs")


def g14():
    snap = os.path.join(root, '.gas-snapshot')
    if not check(".gas-snapshot exists", os.path.exists(snap)):
        return
    os.makedirs(os.path.join(root, 'logs'), exist_ok=True)
    fresh = os.path.join(root, 'logs', 'gate-G-14-snapshot.txt')
    if os.path.exists(fresh):
        os.remove(fresh)
    # fuzz figures repeat only from a clean build, and .gas-snapshot is written from one
    rc0, out0 = run(['forge', 'clean'])
    cmd = SNAPSHOT_CMD + ['--snap', os.path.relpath(fresh, root)]
    rc, out = run(cmd)
    open(os.path.join(root, 'logs', 'gate-G-14-run.txt'), 'w').write(out0 + out)
    if not check(f"forge clean, then {' '.join(cmd)}, passes and writes a fresh snapshot",
                 rc0 == 0 and rc == 0 and os.path.exists(fresh), (out0 + out)[-1200:]):
        return
    # forge 1.8.7 does not repeat an invariant campaign call for call under a fixed seed. Only a campaign with
    # fail-on-revert off shows it, as its revert count, so that one count is left out for those campaigns alone
    loose = set()
    for f, fn, setting in INLINE_CONFIG:
        if setting == 'default.invariant.fail-on-revert = false':
            text = open(os.path.join(root, f), errors='ignore').read()
            at = re.search(rf'\bfunction\s+{fn}\s*\(', text)
            owner = re.findall(r'^\s*(?:abstract\s+)?contract\s+(\w+)', text[:at.start()] if at else '', re.M)
            loose.add(f"{owner[-1] if owner else '?'}:{fn}()")
    line = re.compile(r'^(\w+:\w+\(\)) (\(runs: \d+, calls: \d+, reverts: )\d+\)$')

    def norm(text):
        out = []
        for l in text.split('\n'):
            m = line.match(l)
            out.append(f"{m.group(1)} {m.group(2)}N)" if m and m.group(1) in loose else l)
        return out

    have, want = norm(open(fresh).read()), norm(open(snap).read())
    new = [l for l in have if l not in want]
    gone = [l for l in want if l not in have]
    check(f"the fresh snapshot equals .gas-snapshot byte for byte: every gas, run count, mean, median and invariant "
          f"line, and no line for a test that is gone; only the revert count of the {len(loose)} invariant campaigns "
          f"with fail-on-revert off is left out", have == want,
          f"{len(new)} lines differ or are new, {len(gone)} differ or are gone; first new {new[:3]} first gone {gone[:3]}")
    check("those campaigns are the two of RegistrarInvariantTest, and each has a line in .gas-snapshot",
          loose == {'RegistrarInvariantTest:invariant_namesStay()', 'RegistrarInvariantTest:invariant_noUnownedEth()'}
          and all(any(l.startswith(c + ' ') for l in want) for c in loose), sorted(loose))


def g15():
    paths = ['test/invariant/PageNFTInvariants.t.sol', 'test/simulation/ReferralConservation.t.sol', 'test/dinosat',
             'test/halmos/ReferralSymbolic.t.sol', 'test/unit/system/Escrow.t.sol']
    present = [p for p in paths if os.path.exists(os.path.join(root, p))]
    check("the files of the deleted artefacts are absent", not present, present)
    hits = grep_files(r'invariant_feeSolvency|invariant_referrerWellFormed|ReferralConservationTest|ReferralFlowSymbolicTest|'
                      r'ShareMathLemmasTest|ReferralSymbolicTest|SubdomainSymbolicTest|RegistrarEscrowSymbolicTest|EscrowTest',
                      ['test', 'proofs', 'script'])
    check("no deleted invariant, proof or test name in test, proofs and script", not hits, hits)


def g17():
    w = count_in(rawfn, r'bytes\(records\[[^\]]*\]\.label\)\.length')
    total = len(re.findall(r'bytes\(records\[[^\]]*\]\.label\)\.length', raw['PageNFT']))
    check("bytes(records[...].label).length appears only in _recordExists", w == {'_recordExists': 1} and total == 1, w)


def g18():
    for c in CONTRACTS:
        have = inspect(c, 'methodIdentifiers')
        want = expected(f'{c}.methodIdentifiers.json')
        check(f"{c}: the method identifiers equal gates/{c}.methodIdentifiers.json ({len(want)})", have == want,
              f"missing {sorted(set(want) - set(have))} extra {sorted(set(have) - set(want))}")
        check(f"{c}: selectors are unique", len(set(have.values())) == len(have))
        for kind in ('events', 'errors'):
            h = inspect(c, kind)
            w = expected(f'{c}.{kind}.json')
            check(f"{c}: the ABI {kind} equal gates/{c}.{kind}.json ({len(w)})", h == w,
                  f"missing {sorted(set(w) - set(h))} extra {sorted(set(h) - set(w))}")
    ids = expected('PageNFT.methodIdentifiers.json')
    for sig in ('withdraw()', 'withdrawFor(address)', 'recordVersions(bytes32)', 'isAsciiLabel(string)',
                'revealFor(string,address,uint256,bytes32)', 'reveal(string,uint256,bytes32)'):
        check(f"PageNFT has no {sig}", sig not in ids)
    for sig in ('withdraw(address)', 'parentOf(uint256)', 'epochOf(uint256)', 'resolveAs(uint256,address)',
                'setAddrForCoin(uint256,uint256,bytes)', 'clearRecords(uint256)', 'setSubpageMinter(uint256,address)',
                'subpageMinterOf(uint256)', 'reveal(string,address,uint256,bytes32)',
                'revealTrial(string,address,uint256,bytes32)', 'multicall(bytes[])', 'status(uint256)',
                'trialPaymentOf(uint256)', 'keepProfile(uint256)', 'profileWriter(uint256)'):
        check(f"PageNFT has {sig}", sig in ids)
    rids = expected('SubpageRegistrar.methodIdentifiers.json')
    check("SubpageRegistrar has no onERC721Received, escrowParent, unescrowParent or clearStaleEscrow",
          not [s for s in rids if s.split('(')[0] in ('onERC721Received', 'escrowParent', 'unescrowParent', 'clearStaleEscrow')])


def g19():
    check("SubpageRegistrar never calls records(", not re.search(r'(^|[^A-Za-z0-9_])records\(', reg, re.M))
    names = []
    for m in re.finditer(r'\binterface\s+\w+[^{]*\{(.*?)\}', reg, re.S):
        names += re.findall(r'function\s+(\w+)\s*\(', m.group(1))
    want = ['epochOf', 'isAvailable', 'normalize', 'ownerOf', 'parentOf', 'registerSubpageFor', 'subpageMinterOf']
    check("the interfaces the registrar declares hold exactly ownerOf, registerSubpageFor, isAvailable, normalize, "
          "parentOf, epochOf and subpageMinterOf", sorted(names) == want, sorted(names))


def g21():
    for c in CONTRACTS:
        have = norm_layout(inspect(c, 'storageLayout'))
        want = expected(f'{c}.storage-layout.json')
        check(f"{c}: the storage layout equals gates/{c}.storage-layout.json", have == want,
              json.dumps(have['storage'])[:600])
    lay = expected('PageNFT.storage-layout.json')
    slots = [(e['label'], int(e['slot'])) for e in lay['storage']]
    want = ['records', 'recordVersion', 'commitments', 'primaryPage', 'referrerOf', 'depositOf', 'owed', '_resolvedAddress',
            '_contenthash', '_coinAddr', '_text', '_addrSaver', '_subpageMinter', '_primaryHolder', 'trialPaymentOf', '_profile',
            'holderSince', 'addressesUpdatedAt', '_data']
    check("the committed PageNFT layout is slots 0 to 18 in declaration order", slots == list(zip(want, range(19))), slots)
    types = lay['types']

    def members(label):
        e = [x for x in lay['storage'] if x['label'] == label][0]
        return [(m['label'], m['slot'], m['offset']) for m in types[types[e['type']]['value']]['members']]
    chain = [v for v in types.values() if v['label'] == 'struct PageNFT.ChainAddress']
    check("ChainAddress is saver then value, a word each",
          len(chain) == 1 and [(m['label'], m['slot'], m['offset']) for m in chain[0]['members']] == [('saver', '0', 0), ('value', '1', 0)])
    record = [v for v in types.values() if v['label'] == 'struct PageNFT.DataRecord']
    check("DataRecord is saver then value, a word each",
          len(record) == 1 and [(m['label'], m['slot'], m['offset']) for m in record[0]['members']] == [('saver', '0', 0), ('value', '1', 0)])
    check("SubpageMinter is minter and epoch in one word, then setter",
          members('_subpageMinter') == [('minter', '0', 0), ('epoch', '0', 20), ('setter', '1', 0)])
    check("TrialPayment is payer then a 96 bit amount in one word",
          members('trialPaymentOf') == [('payer', '0', 0), ('amount', '0', 20)])
    check("Profile is writer then a 96 bit version in one word", members('_profile') == [('writer', '0', 0), ('version', '0', 20)])
    check("PageRecord is label, parent, then expiresAt, epoch and parentEpoch in one word",
          members('records') == [('label', '0', 0), ('parent', '1', 0), ('expiresAt', '2', 0), ('epoch', '2', 8),
                                 ('parentEpoch', '2', 16)])
    rl = expected('SubpageRegistrar.storage-layout.json')
    check("the committed SubpageRegistrar layout is config, proceedsOf and subCommitments in slots 0 to 2",
          [(e['label'], int(e['slot'])) for e in rl['storage']] == [('config', 0), ('proceedsOf', 1), ('subCommitments', 2)])
    check("the committed PageCard layout is empty", expected('PageCard.storage-layout.json')['storage'] == [])


def g22():
    check("BatchMetadataUpdate appears once in PageNFT.sol, comments included", raw['PageNFT'].count('BatchMetadataUpdate') == 1)
    check("and that once is its declaration",
          re.search(r'^\s*event BatchMetadataUpdate\(uint256 _fromTokenId, uint256 _toTokenId\);', raw['PageNFT'], re.M) is not None)


def g23():
    pat = r"\"[^\"]*(ETH|ether|deposit|Deposit)[^\"]*\"|'[^']*(ETH|ether|deposit|Deposit)[^']*'"
    hits = [i for i, l in enumerate(raw['PageCard'].split('\n'), 1) if re.search(pat, l)]
    check("no ETH, ether or deposit inside a string literal in PageCard.sol", not hits, hits)


def g24():
    guarded = sorted(n for n, fs in fn.items() for h, _ in fs if 'nonReentrant' in h)
    want = sorted(['reveal', 'revealTrial', 'renew', 'registerSubpage', 'registerSubpageFor', 'release', 'withdraw'])
    check("PageNFT: nonReentrant is on exactly reveal, revealTrial, renew, registerSubpage, registerSubpageFor, release "
          "and withdraw", guarded == want, guarded)
    for n in ('setAddr', 'setAddrForCoin', 'setText', 'setContenthash', 'keepProfile', 'clearRecords', 'setSubpageMinter',
              'setPrimaryPage', 'commit', 'approve', 'transferFrom', 'safeTransferFrom', 'multicall'):
        check(f"PageNFT: {n} carries no guard", all('nonReentrant' not in h for h, _ in fn.get(n, [])))
    payable = sorted(n for n, fs in fn.items() for h, _ in fs if re.search(r'\bpayable\b', h))
    check("PageNFT: the payable functions declared in PageNFT.sol are exactly reveal, revealTrial, renew, approve and "
          "transferFrom", payable == sorted(['reveal', 'revealTrial', 'renew', 'approve', 'transferFrom']), payable)
    for n in ('approve', 'transferFrom'):
        check(f"PageNFT: {n} refuses ETH first", flat(one(fn, n)).startswith('if (msg.value != 0) revert UnexpectedValue();'))
    rg = sorted(n for n, fs in fr.items() for h, _ in fs if 'nonReentrant' in h)
    check("SubpageRegistrar: nonReentrant is on exactly configure, disable, revealSubpageFor, registerSubpageFor, "
          "claimProceeds and claimProceedsFor",
          rg == sorted(['configure', 'disable', 'revealSubpageFor', 'registerSubpageFor', 'claimProceeds', 'claimProceedsFor']), rg)


def g25():
    for v in ('_resolvedAddress', '_addrSaver'):
        w = count_in(fn, re.escape(v) + r'\[')
        check(f"{v}[ occurs only in _pointee and _saveAddr", set(w) == {'_pointee', '_saveAddr'}, w)
    sites = {}
    for name, fs in fn.items():
        for h, b in fs:
            k = len(re.findall(r'_coinAddr\[', b))
            if k:
                key = 'addr(uint256,uint256)' if name == 'addr' and re.match(r'function\s+addr\s*\(\s*uint256\s+\w+\s*,\s*uint256', h) else name
                sites[key] = sites.get(key, 0) + k
    check("_coinAddr[ occurs only in setAddrForCoin, addr(uint256,uint256) and _evmAnswer",
          set(sites) == {'setAddrForCoin', 'addr(uint256,uint256)', '_evmAnswer'}, sites)
    check("_pointee answers the saved address only while its saver holds the name",
          '(a != address(0) && _addrSaver[tokenId][v] == owner) ? a : owner' in flat(one(fn, '_pointee')))


EMITS = {
    'MetadataUpdate': {'_afterTokenTransfer': 1, '_registerTopLevel': 1, 'renew': 1, 'release': 1, '_saveAddr': 1, 'clearRecords': 1},
    'VersionChanged': {'_registerTopLevel': 1, '_registerSubpage': 1, 'clearRecords': 1},
    'AddrChanged': {'_emitCoin': 1},
    'AddressChanged': {'_emitCoin': 1, 'setAddrForCoin': 1},
    'TextChanged': {'setText': 1},
    'DataChanged': {'setData': 1},
    'ContenthashChanged': {'setContenthash': 1},
    'SubpageMinterSet': {'setSubpageMinter': 1},
    'PrimaryPageSet': {'setPrimaryPage': 2, '_registerTopLevel': 1, '_registerSubpage': 1, '_afterTokenTransfer': 1},
    'PageRegistered': {'_registerTopLevel': 1},
    'SubpageRegistered': {'_registerSubpage': 1},
    'PageRenewed': {'renew': 1},
    'Committed': {'commit': 1},
    'ReferrerSet': {'_registerTopLevel': 1},
    'DepositAdded': {'_registerTopLevel': 1, 'renew': 1},
    'DepositBoughtOut': {'_registerTopLevel': 1},
    'DepositReleased': {'_releaseDeposit': 1},
    'ReferrerPremiumCredited': {'_registerTopLevel': 1},
    'OwnerPremiumCredited': {'_registerTopLevel': 1},
    'Withdrawn': {'withdraw': 1},
    'TrialStarted': {'_registerTopLevel': 1},
    'TrialRefunded': {'_refundTrial': 1},
    'ProfileWriterChanged': {'keepProfile': 1, '_writeSlot': 1},
    'BatchMetadataUpdate': {},
}
REG_EMITS = {'ParentConfigured': {'configure': 1, 'disable': 1}, 'Committed': {'commitSubpage': 1},
             'SubpageSold': {'_sell': 1}, 'ProceedsClaimed': {'_payProceeds': 1}}


def g26():
    rawreg = functions(raw['SubpageRegistrar'])
    for src, table, f, label in ((raw['PageNFT'], EMITS, rawfn, 'PageNFT'), (raw['SubpageRegistrar'], REG_EMITS, rawreg, 'SubpageRegistrar')):
        for ev, want in table.items():
            have = count_in(f, r'emit\s+' + ev + r'\(')
            total = len(re.findall(r'\b' + ev + r'\(', src)) - 1
            check(f"{label}: emit {ev}( only at {want or 'no site'}, and no comment names it", have == want and total == sum(want.values()),
                  f"sites {have}, uses outside the declaration {total}")
        emitted = set(re.findall(r'emit\s+(\w+)\(', src))
        check(f"{label}: every emitted event is in the table", emitted <= set(table), sorted(emitted - set(table)))
    for n in ('_registerTopLevel', '_registerSubpage', 'clearRecords'):
        check(f"{n}: VersionChanged follows the recordVersion increment directly",
              'uint256 newVersion = ++recordVersion[tokenId]; emit VersionChanged(bytes32(tokenId), uint64(newVersion));'
              in flat(one(fn, n)))
    check("setText emits TextChanged(bytes32(tokenId), key, key, value)",
          'emit TextChanged(bytes32(tokenId), key, key, value);' in flat(one(fn, 'setText')))
    check("setData emits DataChanged(bytes32(tokenId), key, key, value)",
          'emit DataChanged(bytes32(tokenId), key, key, value);' in flat(one(fn, 'setData')))
    check("_emitCoin pairs AddrChanged with the announcement of coin type 60, carrying the same address",
          flat(one(fn, '_emitCoin')) == 'emit AddressChanged(bytes32(tokenId), coinType, _encode(a)); '
          'if (coinType == COIN_TYPE_ETH) emit AddrChanged(bytes32(tokenId), a);')


def g27():
    t = count_in(rawfn, r'\b_tryNormalize\(')
    check("_tryNormalize( occurs only in its declaration and in _validateAndNormalize, quote and isAvailable, comments included",
          t == {'_validateAndNormalize': 1, 'quote': 1, 'isAvailable': 1}
          and len(re.findall(r'\b_tryNormalize\(', raw['PageNFT'])) == 4, t)
    v = count_in(rawfn, r'\b_validateAndNormalize\(')
    check("_validateAndNormalize( occurs only in its declaration and in normalize, makeCommitment, _registerTopLevel and "
          "_registerSubpage, comments included",
          v == {'normalize': 1, 'makeCommitment': 1, '_registerTopLevel': 1, '_registerSubpage': 1}
          and len(re.findall(r'\b_validateAndNormalize\(', raw['PageNFT'])) == 5, v)
    check("SubpageRegistrar declares neither validator", not re.search(r'function\s+(_tryNormalize|_validateAndNormalize)\b', raw['SubpageRegistrar']))
    check("SubpageRegistrar reads no byte of a label", not re.search(r'bytes\(label\)\[', raw['SubpageRegistrar']))


def g28():
    present = sorted(n for n in os.listdir(os.path.join(root, 'lib')) if n != '.DS_Store')
    check("lib holds exactly the pinned libraries " + ', '.join(sorted(LIB_TREES)), present == sorted(LIB_TREES), present)
    rc, out = run(['forge', 'config', '--json'])
    maps = json.loads(out[out.index('{'):out.rindex('}') + 1]).get('remappings') if rc == 0 else out[-400:]
    check("the remappings send each library name to its folder in lib and nothing else",
          sorted(maps or []) == sorted(LIB_REMAPPINGS), maps)
    rc, top = run(['git', 'rev-parse', '--show-toplevel'])
    top = top.strip()
    rcp, prefix = run(['git', 'rev-parse', '--show-prefix'])
    if not check("the gates run inside a git checkout", rc == 0 and rcp == 0, top):
        return
    prefix = prefix.strip().rstrip('/')
    tmp = tempfile.mkdtemp(prefix='gates-g28-', dir=root)
    try:
        objects = os.path.join(tmp, 'objects')
        os.makedirs(objects)
        rc, gitdir = run(['git', 'rev-parse', '--absolute-git-dir'])
        for lib, want in LIB_TREES.items():
            path = f"{prefix}/lib/{lib}" if prefix else f"lib/{lib}"
            env = {'GIT_INDEX_FILE': os.path.join(tmp, f'index-{lib}'), 'GIT_OBJECT_DIRECTORY': objects,
                   'GIT_ALTERNATE_OBJECT_DIRECTORIES': os.path.join(gitdir.strip(), 'objects')}
            rc1, o1 = run(['git', '-C', top, 'add', '-f', path], env)
            rc2, o2 = run(['git', '-C', top, 'write-tree', f'--prefix={path}/'], env)
            check(f"the tree of lib/{lib} in the working tree is {want}", rc1 == 0 and rc2 == 0 and o2.strip() == want, (o1 + o2).strip())
            rc3, o3 = run(['git', 'rev-parse', f'HEAD:{path}'])
            if rc3 == 0:
                check(f"git rev-parse HEAD:{path} is {want}", o3.strip() == want, o3.strip())
            else:
                check(f"HEAD:{path} is committed", False, "not in HEAD, so only the working tree was checked")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def coverage_misses(lcov):
    # the lines, branches and functions of the three contracts that lcov counts as never run
    miss, cur = [], None
    for line in open(lcov):
        line = line.strip()
        if line.startswith('SF:'):
            f = line[3:]
            cur = f[4:] if f.startswith('src/') and f[4:-4] in CONTRACTS else None
        elif cur is None:
            continue
        elif line.startswith('DA:'):
            n, h = line[3:].split(',')[:2]
            if h == '0':
                miss.append(f"{cur} line {n}")
        elif line.startswith('BRDA:'):
            n, _, arm, h = line[5:].split(',')[:4]
            if h in ('0', '-'):
                miss.append(f"{cur} branch {n} arm {arm}")
        elif line.startswith('FNDA:'):
            h, name = line[5:].split(',', 1)
            if h == '0':
                miss.append(f"{cur} function {name}")
    return miss


def g29():
    os.makedirs(os.path.join(root, 'logs'), exist_ok=True)
    eq = open(os.path.join(gates_dir, 'equivalent-mutants.md')).read()
    check("gates/equivalent-mutants.md is complete, with no PENDING entry", 'PENDING' not in eq)
    # the record speaks for the sources only if its mutation run ran on them, so its row of source hashes names the
    # sha256 of each contract as it is now, and no other hash of it
    row = re.search(r'^\| Commit and source sha256 \|(.*)\|$', eq, re.M)
    stale = []
    for c in CONTRACTS:
        have = sha256(os.path.join(root, 'src', f'{c}.sol'))
        named = re.findall(r'\b' + c + r' ([0-9a-f]{64})\b', row.group(1)) if row else []
        if named != [have]:
            stale.append(f"src/{c}.sol has sha256 {have}, but the record names {', '.join(named) or 'no hash'} for it")
    check("the mutation run of gates/equivalent-mutants.md ran on these sources: its Commit and source sha256 row names the "
          "sha256 of each of the three contracts", row is not None and not stale,
          "the record has no Commit and source sha256 row" if row is None else
          stale + ["so its mutation run did not cover this code: run the campaign on these sources and write the record "
                   "from that run"])
    sec = eq[eq.index('\n## Coverage'):] if '\n## Coverage' in eq else ''
    nxt = re.search(r'\n## ', sec[1:])
    sec = sec[:nxt.start() + 1] if nxt else sec
    block = re.search(r'```text\n# G-29 misses\n(.*?)```', sec, re.S)
    if not check("the Coverage section of gates/equivalent-mutants.md holds the G-29 misses list", block is not None):
        return
    listed = [l.strip() for l in block.group(1).split('\n') if l.strip()]
    bad = [l for l in listed if not re.fullmatch(r'(\w+\.sol) (line \d+|branch \d+ arm \d+|function \w+)', l)]
    check("every entry of the misses list is a line, a branch arm or a function of a file", not bad, bad)
    # each listed line or branch has a row in a table of the section that names its file and line
    spans = [(f, int(a), int(b or a)) for f, a, b in re.findall(r'`(\w+\.sol):(\d+)`(?:\s*to\s*`(\d+)`)?', sec)]
    unexplained = []
    for l in listed:
        m = re.fullmatch(r'(\w+\.sol) (?:line|branch) (\d+).*', l)
        if m and not any(f == m.group(1) and a <= int(m.group(2)) <= b for f, a, b in spans):
            unexplained.append(l)
    check("every entry of the misses list has its row with the reason in the Coverage section", not unexplained, unexplained)
    lcov = os.path.join(root, 'logs', 'gate-G-29-lcov.info')
    if os.path.exists(lcov):
        os.remove(lcov)
    rc, out = run(['forge', 'coverage', '--ir-minimum', '--report', 'summary', '--report', 'lcov',
                   '--report-file', lcov], timeout=None)
    open(os.path.join(root, 'logs', 'gate-G-29-coverage.txt'), 'w').write(out)
    m = re.search(r'Ran (\d+) test suites.*?(\d+) tests passed, (\d+) failed, (\d+) skipped', out, re.S)
    check("forge coverage --ir-minimum runs the whole suite with 0 failing tests",
          rc == 0 and m and m.group(3) == '0' and m.group(4) == '0', m.group(0) if m else out[-800:])
    if m:
        print(f"      {m.group(2)} tests passed in {m.group(1)} suites")
        stated = re.search(r'It runs the whole suite under the default profile, (\d+) tests in (\d+) suites', sec)
        check("the Coverage section states the test and suite counts of this run",
              stated is not None and stated.groups() == (m.group(2), m.group(1)), stated.groups() if stated else None)
    if not check("forge coverage wrote the lcov report", os.path.exists(lcov), out[-600:]):
        return
    seen = {l.split()[0] for l in open(lcov) if l.startswith('SF:src/')}
    check("the lcov report has a record for each of the three contracts",
          all(f"SF:src/{c}.sol" in seen for c in CONTRACTS), sorted(seen))
    misses = coverage_misses(lcov)
    print(f"      {len(misses)} misses reported, {len(listed)} listed")
    new = [x for x in misses if x not in listed or misses.count(x) > listed.count(x)]
    gone = [x for x in listed if x not in misses or listed.count(x) > misses.count(x)]
    check("every line, branch and function forge coverage misses is listed in the Coverage section", not new,
          sorted(set(new)))
    check("every listed miss is still missed, so the list is exact", not gone, sorted(set(gone)))


def g30():
    ia = one(fn, 'isAvailable')
    rt = one(fn, '_registerTopLevel')
    check("_graceEnd is the expiry, plus the grace period only when the name holds a deposit",
          flat(one(fn, '_graceEnd')) == 'uint256 e = records[tokenId].expiresAt; return depositOf[tokenId] == 0 ? e : e + GRACE_PERIOD;')
    check("isAvailable: return block.timestamp > _graceEnd(id); exactly once", flat(ia).count('return block.timestamp > _graceEnd(id);') == 1)
    check("_registerTopLevel: block.timestamp <= _graceEnd(tokenId) exactly once, as the AlreadyRegistered test",
          flat(rt).count('block.timestamp <= _graceEnd(tokenId)') == 1
          and 'if (existed && block.timestamp <= _graceEnd(tokenId)) revert AlreadyRegistered();' in flat(rt))
    check("neither isAvailable nor _registerTopLevel names GRACE_PERIOD", 'GRACE_PERIOD' not in ia and 'GRACE_PERIOD' not in rt)
    check("_auctionEnd is the expiry plus the grace and premium periods",
          flat(one(fn, '_auctionEnd')) == 'return uint256(records[tokenId].expiresAt) + GRACE_PERIOD + PREMIUM_DECAY_PERIOD;')
    check("PREMIUM_DECAY_PERIOD is used only in getPremium and _auctionEnd, comments included",
          count_in(rawfn, r'\bPREMIUM_DECAY_PERIOD\b') == {'getPremium': 3, '_auctionEnd': 1}
          and len(re.findall(r'\bPREMIUM_DECAY_PERIOD\b', raw['PageNFT'])) == 5)
    check("_auctionEnd( is used in quote, _registerTopLevel, release and isReleasable, once each",
          count_in(fn, r'\b_auctionEnd\(') == {'quote': 1, '_registerTopLevel': 1, 'release': 1, 'isReleasable': 1})
    check("quote carries the deposit only during the auction",
          'bool inAuction = block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD && block.timestamp <= _auctionEnd(id); '
          'carried = (_recordExists(id) && inAuction) ? depositOf[id] : 0;' in flat(one(fn, 'quote')))
    check("isReleasable answers false up to the end of the auction",
          'if (block.timestamp <= _auctionEnd(tokenId)) return false; return depositOf[tokenId] != 0;' in flat(one(fn, 'isReleasable')))
    check("isExpired, inGracePeriod and renew use _graceEnd",
          'return block.timestamp > _graceEnd(tokenId);' in flat(one(fn, 'isExpired'))
          and 'block.timestamp <= _graceEnd(tokenId)' in flat(one(fn, 'inGracePeriod'))
          and 'if (block.timestamp > _graceEnd(tokenId)) revert Expired();' in flat(one(fn, 'renew')))
    rawia = one(rawfn, 'isAvailable')
    lines = [l.strip() for l in rawia.split('\n') if 'DEAD' in l or '_ownerOf(' in l]
    check("DEAD and _ownerOf( appear in isAvailable only in the subpage statement",
          lines == ['return records[id].parentEpoch != p.epoch || _ownerOf(id) == DEAD;'], lines)
    sub = flat(ia)[flat(ia).index('} else {'):]
    check("that statement is in the subpage branch", 'return records[id].parentEpoch != p.epoch || _ownerOf(id) == DEAD;' in sub)
    check("_registerTopLevel does not contain DEAD", 'DEAD' not in one(rawfn, '_registerTopLevel'))


def g31():
    hits = grep_files(r'address\s*\(\s*this\s*\)\s*\.\s*balance|\bselfbalance\s*\(\s*\)|\bbalance\s*\(\s*address\s*\(\s*\)\s*\)', ['src'])
    check("no contract reads its own balance: no address(this).balance, selfbalance() or balance(address()) in src, "
          "comments included", not hits, hits)
    # reading any account's balance would also read the own one when that account is this contract
    hits = [f"{c}.sol" for c in CONTRACTS if re.search(r'\.\s*balance\b|\bbalance\s*\(', strip_comments(raw[c]))]
    check("no contract reads any ETH balance: no .balance and no assembly balance( in the code of the three sources",
          not hits, hits)


def g32():
    check("_deleted( occurs exactly four times in PageNFT.sol, comments included", raw['PageNFT'].count('_deleted(') == 4)
    check("_deleted is return holder == DEAD;, for every page", flat(one(fn, '_deleted')) == 'return holder == DEAD;')
    check("_isActive calls it right after the existence test, as if (_deleted(_ownerOf(tokenId))) return false;",
          flat(one(fn, '_isActive')).count('_deleted(') == 1 and flat(one(fn, '_isActive')).startswith(
              'if (!_recordExists(tokenId)) return false; if (_deleted(_ownerOf(tokenId))) return false;'))
    check("_afterTokenTransfer calls it on the receiving side as to != address(0) && !_deleted(to)",
          flat(one(fn, '_afterTokenTransfer')).count('_deleted(') == 1 and 'if (to != address(0) && !_deleted(to))' in flat(one(fn, '_afterTokenTransfer')))
    check("_cardState calls it for every page, after the stale subpage test",
          flat(one(fn, '_cardState')).count('_deleted(') == 1
          and 'if (r.parentEpoch != p.epoch) return (PageCard.Status.Invalid, 0, parentLabel);' in flat(one(fn, '_cardState'))
          and 'if (_deleted(_ownerOf(tokenId))) return (PageCard.Status.Invalid, 0, parentLabel);' in flat(one(fn, '_cardState')))
    # where it is: right after the subpage branch closes, at the top level of the body, so it holds for a top level page
    # too, and before the expiry is set
    cs = flat(one(fn, '_cardState'))
    i = cs.find('graceEnd = E + GRACE_PERIOD; } if (_deleted(_ownerOf(tokenId))) return (PageCard.Status.Invalid, 0, parentLabel); '
                'expiry = E;')
    j = i + len('graceEnd = E + GRACE_PERIOD; } ')
    check("_cardState: the dead address test follows the end of the subpage branch, outside every block, and comes before "
          "expiry = E;", i != -1 and cs[:j].count('{') == cs[:j].count('}')
          and 0 <= cs.find('if (r.parentEpoch != p.epoch) return (PageCard.Status.Invalid, 0, parentLabel);') < j)
    for n in ('_isActive', '_afterTokenTransfer', '_cardState'):
        check(f"DEAD does not appear in {n}", 'DEAD' not in one(rawfn, n))
    bt = one(fn, '_beforeTokenTransfer')
    check("DEAD appears in _beforeTokenTransfer only in the trial rule for top level names",
          bt.count('DEAD') == 1 and 'if (records[tokenId].parent == 0 && depositOf[tokenId] == 0 && to != DEAD) revert Unpaid();' in flat(bt))
    check("_beforeTokenTransfer: no move to this contract, and a move between accounts needs an active name",
          flat(bt).startswith('if (to == address(this)) revert InvalidRecipient(); if (from != address(0) && to != address(0)) '
                              '{ if (!_isActive(tokenId)) revert Expired();'))


def g33():
    check("_mintTo is declared once", len(fn.get('_mintTo', [])) == 1)
    check("_mintTo mints without asking when the recipient is the caller or a key wallet, and asks every other contract",
          flat(one(fn, '_mintTo')) == 'if (to == msg.sender || _isKeyWallet(to)) _mint(to, tokenId); else _safeMint(to, tokenId);')
    check("_mintTo is called once in _registerTopLevel and once in _registerSubpage, and nowhere else",
          count_in(fn, r'\b_mintTo\(') == {'_registerTopLevel': 1, '_registerSubpage': 1} and len(re.findall(r'\b_mintTo\(', nft)) == 3)
    check("_mint( and _safeMint( are called only in _mintTo",
          count_in(fn, r'\b_mint\(') == {'_mintTo': 1} and count_in(fn, r'\b_safeMint\(') == {'_mintTo': 1}
          and len(re.findall(r'\b_mint\(', nft)) == 1 and len(re.findall(r'\b_safeMint\(', nft)) == 1)
    check("_isKeyWallet is used in _mintTo only, to skip the receiver check", count_in(fn, r'\b_isKeyWallet\(') == {'_mintTo': 1})
    check("no address answer reads code: addr and _evmAnswer use no _isKeyWallet, extcodesize, extcodehash, extcodecopy or .code",
          len(fn.get('addr', [])) >= 2 and not any(re.search(r'_isKeyWallet|extcode|\.code\b', body)
                                                   for _, body in fn.get('addr', []) + fn.get('_evmAnswer', [])))
    kw = one(fn, '_isKeyWallet')
    check("the key wallet test is no code or the 23 byte delegation starting with 0xef0100",
          'yes := iszero(size)' in kw and 'eq(size, 23)' in kw and 'eq(shr(232, mload(0x00)), 0xef0100)' in kw)
    rt = flat(one(fn, '_registerTopLevel'))
    check("in _registerTopLevel the mint follows the record and the money, then the events and the refund",
          rt.index('records[tokenId] = PageRecord') < rt.index('_mintTo(to, tokenId)') < rt.index('emit PageRegistered')
          < rt.index('_refundExcess(total)'))
    rs = flat(one(fn, '_registerSubpage'))
    check("in _registerSubpage the mint follows the record", rs.index('records[tokenId] = PageRecord') < rs.index('_mintTo(to, tokenId)'))


def g34():
    w = count_in(fn, r'trialPaymentOf\[[^\]]*\]\s*=(?!=)')
    check("trialPaymentOf is assigned only in _registerTopLevel, once", w == {'_registerTopLevel': 1}, w)
    check("trialPaymentOf is deleted only in _refundTrial, once", count_in(fn, r'delete\s+trialPaymentOf\[') == {'_refundTrial': 1})
    check("no member of trialPaymentOf is written", not re.search(r'trialPaymentOf\[[^\]]*\]\.\w+\s*(=(?!=)|\+=|-=)', nft))
    check("_refundTrial is called in renew, release and _registerTopLevel, once each",
          count_in(fn, r'_refundTrial\(') == {'renew': 1, 'release': 1, '_registerTopLevel': 1})
    check("_refundTrial reads, returns on zero, deletes before crediting, credits the payer and logs it",
          flat(one(fn, '_refundTrial')) == 'TrialPayment memory t = trialPaymentOf[tokenId]; if (t.amount == 0) return; '
          'delete trialPaymentOf[tokenId]; address to = _credit(t.payer, t.amount); emit TrialRefunded(tokenId, to, t.amount);')
    rt = flat(one(fn, '_registerTopLevel'))
    check("a trial is told apart by its selector", 'bool trial = msg.sig == this.revealTrial.selector;' in rt)
    check("a trial costs the fee divided by TRIAL_DIVISOR", 'if (trial) fee /= TRIAL_DIVISOR;' in rt)
    check("a trial never takes over a deposit", 'if (trial && carried != 0) revert TrialNotAllowed();' in rt)
    check("a paid commitment hashes the four values",
          flat(one(fn, '_commitmentHash')) == 'return keccak256(abi.encode(normalized, owner, referrerId, secret));')
    check("a trial commits to the same values with a trial flag, never to a value made from the paid commitment",
          'bytes32 c = _commitmentHash(normalized, to, referrerId, secret); '
          'if (trial) c = keccak256(abi.encode(normalized, to, referrerId, secret, true)); uint256 committedAt = commitments[c];' in rt
          and '~' not in rt)
    check("the trial pause check follows AlreadyRegistered",
          rt.index('revert AlreadyRegistered()') < rt.index('if (trial && existed && block.timestamp <= uint256(records[tokenId].expiresAt) + TRIAL_PAUSE) revert TrialNotAllowed();'))
    check("in _registerTopLevel the refund runs after the premium credits and before the new price is held",
          rt.index('emit OwnerPremiumCredited') < rt.index('_refundTrial(tokenId)') < rt.index('trialPaymentOf[tokenId] ='))
    check("a trial holds its price for the caller and a paid year adds the fee to the deposit",
          'if (trial) { trialPaymentOf[tokenId] = TrialPayment(msg.sender, uint96(fee)); emit TrialStarted(tokenId, msg.sender, fee); } '
          'else { depositOf[tokenId] += fee; emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId]); }' in rt)
    rn = flat(one(fn, 'renew'))
    check("renew refunds the trial before adding the fee to the deposit", rn.index('_refundTrial(tokenId)') < rn.index('depositOf[tokenId] += fee'))
    rl = flat(one(fn, 'release'))
    check("release refunds a held trial only after the trial ended and returns",
          'if (trialPaymentOf[tokenId].amount != 0) { if (block.timestamp <= r.expiresAt) revert NotReleasable(); _refundTrial(tokenId); return; }' in rl)
    d = count_in(fn, r'depositOf\[[^\]]*\]\s*(\+=|-=|=(?!=))|delete\s+depositOf\[')
    rd = flat(one(fn, '_releaseDeposit'))
    check("depositOf is written only in _registerTopLevel (+=), renew (+=) and _releaseDeposit (= 0)",
          d == {'_registerTopLevel': 1, 'renew': 1, '_releaseDeposit': 1} and 'depositOf[tokenId] = 0;' in rd, d)
    check("_releaseDeposit reads the deposit and the payee, empties the deposit before crediting it and logs it",
          rd == 'uint256 amount = depositOf[tokenId]; address p = _payee(tokenId); depositOf[tokenId] = 0; '
          'address to = _credit(p, amount); emit DepositReleased(tokenId, to, amount);')
    check("_releaseDeposit is called in release and _registerTopLevel, once each",
          count_in(fn, r'_releaseDeposit\(') == {'release': 1, '_registerTopLevel': 1})
    check("release releases only after the auction and only a deposit",
          'if (block.timestamp <= _auctionEnd(tokenId)) revert NotReleasable(); '
          'if (depositOf[tokenId] == 0) revert NothingToRelease(); _releaseDeposit(tokenId); emit MetadataUpdate(tokenId);' in rl)
    check("_registerTopLevel releases a deposit left after the auction before it reads the deposit to buy out",
          'if (referrerId == tokenId) revert SelfReferral(); '
          'if (depositOf[tokenId] != 0 && block.timestamp > _auctionEnd(tokenId)) _releaseDeposit(tokenId); '
          'uint256 carried = depositOf[tokenId]; if (trial && carried != 0) revert TrialNotAllowed();' in rt)
    check("a subpage needs a paid parent", 'if (depositOf[parentId] == 0) revert Unpaid();' in flat(one(fn, '_registerSubpage')))


def g35():
    check("_profile is used once each in keepProfile, _writeSlot, _readSlot and profileWriter, plus its declaration",
          count_in(fn, r'_profile\[') == {'keepProfile': 1, '_writeSlot': 1, '_readSlot': 1, 'profileWriter': 1}
          and nft.count('_profile') == 5)
    check("the writer is assigned only in keepProfile and _writeSlot, and only to msg.sender",
          count_in(fn, r'\.writer\s*=(?!=)') == {'keepProfile': 1, '_writeSlot': 1}
          and len(re.findall(r'\.writer\s*=(?!=)\s*msg\.sender\s*;', nft)) == 2)
    check("the version only goes up by one, in _writeSlot, when a writer was set",
          count_in(fn, r'\.version').get('_writeSlot') == 2
          and 'if (p.writer != address(0)) ++p.version;' in flat(one(fn, '_writeSlot'))
          and not re.search(r'\.version\s*(=(?!=)|\+=|--|-=)', nft) and len(re.findall(r'\+\+\s*\w+\.version', nft)) == 1)
    check("ProfileWriterChanged is emitted in keepProfile with fresh false and in _writeSlot with fresh true",
          'emit ProfileWriterChanged(bytes32(tokenId), msg.sender, false);' in one(fn, 'keepProfile')
          and 'emit ProfileWriterChanged(bytes32(tokenId), msg.sender, true);' in one(fn, '_writeSlot'))
    check("_text is written only in setText and read only in text, through the profile slot",
          count_in(fn, r'_text\[') == {'setText': 1, 'text': 1} and '_text[tokenId][_writeSlot(tokenId)][key] = value;' in nft
          and 'ok ? _text[tokenId][slot][key] : ""' in nft)
    check("_contenthash is written only in setContenthash and read only in contenthash, through the profile slot",
          count_in(fn, r'_contenthash\[') == {'setContenthash': 1, 'contenthash': 1}
          and '_contenthash[tokenId][_writeSlot(tokenId)] = hash;' in nft and 'ok ? _contenthash[tokenId][slot] : bytes("")' in nft)
    check("the slot key is recordVersion << 96 | version", flat(one(fn, '_slot')) == 'return recordVersion[tokenId] << 96 | version;')
    check("a profile counts only for an active name whose writer holds it",
          'ok = _isActive(tokenId) && p.writer == _ownerOf(tokenId);' in one(fn, '_readSlot'))
    check("keepProfile: active, holder, not already the writer, then only the writer changes",
          flat(one(fn, 'keepProfile')) == 'if (!_isActive(tokenId)) revert Expired(); if (ownerOf(tokenId) != msg.sender) '
          'revert Unauthorized(); Profile storage p = _profile[tokenId]; if (p.writer == msg.sender) revert AlreadyKept(); '
          'p.writer = msg.sender; emit ProfileWriterChanged(bytes32(tokenId), msg.sender, false);')
    check("setData and data do not touch the profile", all('_profile' not in one(fn, n) and '_writeSlot' not in one(fn, n)
                                                         and '_readSlot' not in one(fn, n) for n in ('setData', 'data')))
    check("a data record counts only while its saver holds the page",
          'return d.saver == _ownerOf(tokenId) ? d.value : bytes("");' in one(fn, 'data')
          and 'd.saver = msg.sender;' in one(fn, 'setData'))
    for n in ('setText', 'setContenthash', 'setAddr', 'setAddrForCoin', 'clearRecords', 'setData'):
        check(f"{n} checks activity and the holder first", flat(one(fn, n)).startswith(
            'if (!_isActive(tokenId)) revert Expired(); if (ownerOf(tokenId) != msg.sender) revert Unauthorized();'))
    for n in ('_beforeTokenTransfer', '_afterTokenTransfer', 'clearRecords', '_registerTopLevel', '_registerSubpage',
              'tokenURI', '_cardState'):
        b = one(fn, n)
        check(f"{n} does not touch the profile", '_profile' not in b and '_writeSlot' not in b and '_readSlot' not in b)


def g36():
    def writes(body):
        return len(re.findall(r'primaryPage\[[^\]]*\]\s*=(?!=)', body)) + len(re.findall(r'delete\s+primaryPage\[', body))
    sites = {c: k for c, k in ((n, sum(writes(b) for _, b in fs)) for n, fs in fn.items()) if k}
    check("primaryPage is written in setPrimaryPage (2), _registerTopLevel, _registerSubpage and _afterTokenTransfer (1 each)",
          sites == {'setPrimaryPage': 2, '_registerTopLevel': 1, '_registerSubpage': 1, '_afterTokenTransfer': 1}, sites)
    after = flat(one(fn, '_afterTokenTransfer'))
    check("_beforeTokenTransfer does not touch primaryPage", 'primaryPage' not in one(fn, '_beforeTokenTransfer'))
    check("_afterTokenTransfer returns first on a self transfer", after.startswith('if (from == to) return;'))
    clear = ('if (from != address(0) && to != address(0)) { if (primaryPage[from] == tokenId) { delete primaryPage[from]; '
             'emit PrimaryPageSet(from, 0); } emit MetadataUpdate(tokenId); }')
    check("the clear ends _afterTokenTransfer: only between two accounts, only the sender, only for the moved id", after.endswith(clear))
    check("the hook reads primaryPage only for from", re.findall(r'primaryPage\[(\w+)\]', after) == ['from', 'from'])
    check("_primaryHolder appears exactly three times", nft.count('_primaryHolder') == 3, nft.count('_primaryHolder'))
    check("it is declared as mapping(address => address) internal _primaryHolder;",
          'mapping(address => address) internal _primaryHolder;' in nft)
    check("it is written once, in setPrimaryPage, and read once, in reverseResolve",
          count_in(fn, r'_primaryHolder') == {'setPrimaryPage': 1, 'reverseResolve': 1}
          and count_in(fn, r'_primaryHolder\[[^\]]*\]\s*=(?!=)') == {'setPrimaryPage': 1})
    sp = flat(one(fn, 'setPrimaryPage'))
    check("setPrimaryPage stores the holder it checked, after the check",
          'address holder = ownerOf(tokenId); if (msg.sender != holder && msg.sender != resolve(tokenId)) revert Unauthorized(); '
          'primaryPage[msg.sender] = tokenId; _primaryHolder[msg.sender] = holder;' in sp)
    check("setPrimaryPage(0) returns before the holder write", sp.index('return;') < sp.index('_primaryHolder'))
    check("reverseResolve compares _ownerOf with the stored holder, after _isActive and before resolve",
          'tokenId == 0 || !_isActive(tokenId) || _ownerOf(tokenId) != _primaryHolder[a] || resolve(tokenId) != a'
          in flat(one(fn, 'reverseResolve')))


# every low level call, create and selfdestruct in each source, in code or in assembly, by the function it is in
# and its text up to the closing parenthesis; a site in no function, such as a constructor, has the name ''
LOW_LEVEL = r'\b(call|callcode|delegatecall|staticcall|create2?|selfdestruct)\s*\('
LOW_LEVEL_SITES = {
    'PageNFT': [('multicall', 'delegatecall(calls[i])')],
    'SubpageRegistrar': [('_gateBalance', 'staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)')],
    'PageCard': [],
}


def enclosing(src, pos):
    # the name of the function whose body holds position pos, or ''
    for m in re.finditer(r'\bfunction\s+(\w+)\s*\(', src):
        i = src.find('{', m.end())
        semi = src.find(';', m.end())
        if i == -1 or (semi != -1 and semi < i) or i > pos:
            continue
        depth, j = 0, i
        while j < len(src):
            if src[j] == '{':
                depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if i < pos < j:
            return m.group(1)
    return ''


def low_level_sites(src):
    out = []
    for m in re.finditer(LOW_LEVEL, src):
        depth, j = 0, m.end() - 1
        while j < len(src):
            depth += {'(': 1, ')': -1}.get(src[j], 0)
            if depth == 0:
                break
            j += 1
        out.append((enclosing(src, m.start()), flat(src[m.start():j + 1])))
    return out


def g37():
    for c in CONTRACTS:
        have = low_level_sites(strip_comments(raw[c]))
        want = ', '.join(f"{text} in {f}" for f, text in LOW_LEVEL_SITES[c]) or 'none'
        check(f"{c}.sol: the low level calls, creates and selfdestructs, in code and in assembly, are exactly: {want}",
              have == LOW_LEVEL_SITES[c], have)
    made = [c for c in CONTRACTS if re.search(r'\bnew\s+(?!bytes\b|string\b)[A-Za-z_]\w*\s*[({]', strip_comments(raw[c]))]
    check("no source creates a contract with new", not made, made)
    check("PageNFT: delegatecall appears exactly once", nft.count('delegatecall') == 1, nft.count('delegatecall'))
    h, b = fn['multicall'][0]
    check("PageNFT: the delegatecall is in multicall and targets address(this)", 'address(this).delegatecall(calls[i])' in b)
    check("PageNFT: multicall is not payable", 'payable' not in h)
    check("PageNFT: multicall passes on the failing call's revert data", 'revert(add(ret, 0x20), mload(ret))' in b)
    check("PageNFT: no .call anywhere", not re.search(r'\.call\s*[\({]', nft))
    check("PageNFT: no staticcall, callcode, selfdestruct or create in code", not re.search(r'staticcall|callcode|selfdestruct|\bcreate2?\s*\(', nft))
    check("PageNFT: no call opcode in assembly", not re.search(r'\b(call|delegatecall|staticcall)\s*\(\s*gas', nft))
    check("SubpageRegistrar: no delegatecall and no .call", 'delegatecall' not in reg and not re.search(r'\.call\s*[\({]', reg))
    check("SubpageRegistrar: its one low level call is the staticcall of _gateBalance",
          reg.count('staticcall') == 1 and 'staticcall(gas(), token' in one(fr, '_gateBalance'))
    check("PageCard: no delegatecall, no call and no storage, every function pure",
          'delegatecall' not in card and not re.search(r'\.call\s*[\({]|staticcall', card) and not re.search(r'\b(sstore|sload)\b', card)
          and all('pure' in h for fs in fc.values() for h, _ in fs))


def g38():
    check("PageCard.Status is Active, Grace, Expired, Invalid, Trial in that order", 'enum Status { Active, Grace, Expired, Invalid, Trial }' in card)
    check("tokenURI names follow the enum", 'string[5] memory statusNames = ["Active","Grace","Expired","Invalid","Trial"];' in nft)
    check("status reverts for a missing record and otherwise returns _cardState's status",
          flat(one(fn, 'status')) == 'if (!_recordExists(tokenId)) revert TokenDoesNotExist(); (s,,) = _cardState(tokenId);')
    check("tokenURI has the same existence check and reads the same _cardState",
          one(fn, 'tokenURI').strip().startswith('if (!_recordExists(tokenId)) revert TokenDoesNotExist();')
          and '= _cardState(tokenId);' in one(fn, 'tokenURI'))
    check("_cardState calls a live top level name with no deposit a trial",
          'st = r.parent == 0 && depositOf[tokenId] == 0 ? PageCard.Status.Trial : PageCard.Status.Active;' in flat(one(fn, '_cardState')))


def g39():
    want = ['MIN_LABEL_LENGTH = 1;', 'MAX_LABEL_LENGTH = 63;', 'MIN_COMMITMENT_AGE = 20;', 'MAX_COMMITMENT_AGE = 86400;',
            'REGISTRATION_PERIOD = 365 days;', 'GRACE_PERIOD = 90 days;', 'MAX_EXPIRY_HORIZON = 3650 days;',
            'PREMIUM_DECAY_PERIOD = 21 days;', 'MAX_PREMIUM = 10 ether;', 'FEE_LEN1 = 0.01 ether;', 'FEE_LEN2 = 0.01 ether;',
            'FEE_LEN3 = 0.001 ether;', 'FEE_LEN4 = 0.001 ether;', 'DEFAULT_FEE = 0.0001 ether;', 'TRIAL_PERIOD = 14 days;',
            'TRIAL_DIVISOR = 10;', 'TRIAL_PAUSE = 14 days;', 'COIN_TYPE_ETH = 60;', 'COIN_TYPE_OP = 0x8000000a;',
            'DEFAULT_EVM = 0x80000000;', 'PREMIUM_REFERRER_BPS = 2500;', 'BPS_DENOMINATOR = 10_000;',
            'address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;',
            'bytes32 public constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;']
    missing = [w for w in want if w not in nft]
    check("PageNFT: every price, period, coin type and address constant has its value", not missing, missing)
    consts = re.findall(r'\bconstant\s+(\w+)\s*=', nft)
    check("PageNFT declares exactly these 24 constants", len(consts) == 24 and len(set(consts)) == 24, consts)
    check("SubpageRegistrar: commitments live 20 seconds to one day",
          'MIN_SUB_COMMITMENT_AGE = 20;' in reg and 'MAX_SUB_COMMITMENT_AGE = 86400;' in reg)


def g40():
    bad = [(r'[\u2014\u2013]', 'em or en dash'), (r' - ', 'a dash separator'), (r'--', 'a double dash'),
           (r'->|=>|\u2192|\u00a7|\u2265|\u2264', 'an arrow or symbol'), (r'\bR-\d', 'a spec rule number'),
           (r'[Dd]ecision|\b2[0-9]\.[0-9]{1,2}\b', 'a decision number'),
           (r'\b(glue|verbatim|assembled|prototype|round|judge|attacker|builder)\b', 'a history word')]
    for name in CONTRACTS:
        comments = re.findall(r'//[^\n]*|/\*.*?\*/', raw[name], flags=re.S)
        for pattern, what in bad:
            hits = [c.strip() for c in comments if re.search(pattern, c) and not c.startswith('// SPDX')]
            check(f"{name}.sol: no {what} in comments", not hits, hits[:3])
        check(f"{name}.sol: no em or en dash anywhere", '\u2014' not in raw[name] and '\u2013' not in raw[name])


def g41():
    rc, out = run([sys.executable, os.path.join(root, 'tools', 'make_harness.py'), '--check'])
    check("the generated harnesses PageNFTSafe, PageNFTPlain, PageNFTKeyOnly and PageNFTManualRelease match src", rc == 0, out)


# the campaign settings of foundry.toml as forge config resolves them; G-42 fails on any other value, larger or
# smaller
CAMPAIGNS = {
    'default': {'fuzz.runs': 256, 'fuzz.fail_on_revert': True, 'fuzz.seed': None, 'fuzz.timeout': None,
                'invariant.runs': 64, 'invariant.depth': 64, 'invariant.fail_on_revert': True,
                'invariant.call_override': False, 'invariant.timeout': None, 'invariant.show_metrics': True},
    'deep': {'fuzz.runs': 1000, 'fuzz.fail_on_revert': True, 'fuzz.seed': None, 'fuzz.timeout': None,
             'invariant.runs': 512, 'invariant.depth': 256, 'invariant.fail_on_revert': True,
             'invariant.call_override': False, 'invariant.timeout': None, 'invariant.show_metrics': True},
}
# the only settings in which deep differs from default
CAMPAIGN_SIZES = ('fuzz.runs', 'invariant.runs', 'invariant.depth')
# settings that leave tests out of a run
TEST_FILTERS = {'test': 'test', 'match_test': None, 'match_contract': None, 'match_path': None, 'no_match_test': None,
                'no_match_contract': None, 'no_match_path': None, 'no_match_coverage': None, 'skip': []}
# every forge-config line of the tests, with the function it sets and the setting
INLINE_CONFIG = [
    ('test/attack/MinterAuthWalk.t.sol', 'testFuzz_walk', 'default.fuzz.runs = 1000'),
    ('test/attack/MinterAuthWalk.t.sol', 'testFuzz_walk', 'deep.fuzz.runs = 1000'),
    ('test/attack/RegistrarModelWalk.t.sol', 'testFuzz_saleIffHolderChoseBoth', 'default.fuzz.runs = 1500'),
    ('test/attack/RegistrarModelWalk.t.sol', 'testFuzz_saleIffHolderChoseBoth', 'deep.fuzz.runs = 1500'),
    ('test/differential/ClearPrimaryDifferential.t.sol', 'testFuzz_focus', 'default.fuzz.runs = 200'),
    ('test/differential/ClearPrimaryDifferential.t.sol', 'testFuzz_focus', 'deep.fuzz.runs = 200'),
    ('test/differential/ClearPrimaryDifferential.t.sol', 'testFuzz_walk', 'default.fuzz.runs = 100'),
    ('test/differential/ClearPrimaryDifferential.t.sol', 'testFuzz_walk', 'deep.fuzz.runs = 100'),
    ('test/differential/DeletedDifferential.t.sol', 'testFuzz_focus', 'default.fuzz.runs = 200'),
    ('test/differential/DeletedDifferential.t.sol', 'testFuzz_focus', 'deep.fuzz.runs = 200'),
    ('test/differential/DeletedDifferential.t.sol', 'testFuzz_walk', 'default.fuzz.runs = 100'),
    ('test/differential/DeletedDifferential.t.sol', 'testFuzz_walk', 'deep.fuzz.runs = 100'),
    ('test/differential/MulticallDifferential.t.sol', 'testFuzz_focus', 'default.fuzz.runs = 200'),
    ('test/differential/MulticallDifferential.t.sol', 'testFuzz_focus', 'deep.fuzz.runs = 200'),
    ('test/differential/MulticallDifferential.t.sol', 'testFuzz_walk', 'default.fuzz.runs = 100'),
    ('test/differential/MulticallDifferential.t.sol', 'testFuzz_walk', 'deep.fuzz.runs = 100'),
    ('test/invariant/LedgerRulesWalk.t.sol', 'testFuzz_ledgerAndLogRulesHoldAtEveryStep', 'default.fuzz.runs = 128'),
    ('test/invariant/LedgerRulesWalk.t.sol', 'testFuzz_ledgerAndLogRulesHoldAtEveryStep', 'deep.fuzz.runs = 512'),
    ('test/invariant/RegistrarInvariant.t.sol', 'invariant_namesStay', 'default.invariant.fail-on-revert = false'),
    ('test/invariant/RegistrarInvariant.t.sol', 'invariant_namesStay', 'deep.invariant.fail-on-revert = false'),
    ('test/invariant/RegistrarInvariant.t.sol', 'invariant_noUnownedEth', 'default.invariant.fail-on-revert = false'),
    ('test/invariant/RegistrarInvariant.t.sol', 'invariant_noUnownedEth', 'deep.invariant.fail-on-revert = false'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_anyBytes', 'default.fuzz.runs = 5000'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_anyBytes', 'deep.fuzz.runs = 5000'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_mixedBytesAroundTheCut', 'default.fuzz.runs = 5000'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_mixedBytesAroundTheCut', 'deep.fuzz.runs = 5000'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_xmlTextGivesAWellFormedCard', 'default.fuzz.runs = 5000'),
    ('test/unit/cards/CardAnyText.t.sol', 'testFuzz_xmlTextGivesAWellFormedCard', 'deep.fuzz.runs = 5000'),
    ('test/unit/cards/CardBoundFuzz.t.sol', 'testFuzz_plainLabelCardBound', 'default.fuzz.runs = 5000'),
    ('test/unit/cards/CardBoundFuzz.t.sol', 'testFuzz_plainLabelCardBound', 'deep.fuzz.runs = 5000'),
]


def resolved(cfg, key):
    section, name = key.split('.')
    return cfg.get(section, {}).get(name, 'absent')


def inline_config():
    # every line of test, proofs and script that holds forge-config, with the next function or contract it precedes
    out = []
    for f in sorted(files_under('test', 'proofs', 'script')):
        if not f.endswith('.sol'):
            continue
        text = open(f, errors='ignore').read()
        for m in re.finditer(r'forge-config[^\n]*', text, re.I):
            setting = flat(re.sub(r'^forge-config\s*:?', '', m.group(0), flags=re.I).strip(' */'))
            nxt = re.compile(r'\b(?:function|contract)\s+(\w+)').search(text, m.end())
            out.append((os.path.relpath(f, root), nxt.group(1) if nxt else '', setting))
    return sorted(out)


def g42():
    cfg = {}
    for p in ('default', 'deep'):
        rc, out = run(['forge', 'config', '--json'], {'FOUNDRY_PROFILE': p})
        if not check(f"forge config for profile {p}", rc == 0, out[-400:]):
            return
        cfg[p] = json.loads(out[out.index('{'):out.rindex('}') + 1])
    for p, want in CAMPAIGNS.items():
        bad = {k: resolved(cfg[p], k) for k, v in want.items() if resolved(cfg[p], k) != v}
        check(f"{p}: fuzz runs {want['fuzz.runs']}, invariant runs {want['invariant.runs']} of depth "
              f"{want['invariant.depth']}, fail_on_revert on, call_override off, no fixed seed, no timeout, metrics shown",
              not bad, bad)
    other = sorted(f"{s}.{k}" for s in ('fuzz', 'invariant') for k in set(cfg['default'][s]) | set(cfg['deep'][s])
                   if f"{s}.{k}" not in CAMPAIGN_SIZES and cfg['default'][s].get(k, 'absent') != cfg['deep'][s].get(k, 'absent'))
    check("deep differs from default only in the fuzz runs, the invariant runs and the depth", not other, other)
    for p in ('default', 'deep'):
        bad = {k: cfg[p].get(k, 'absent') for k, v in TEST_FILTERS.items() if cfg[p].get(k, 'absent') != v}
        check(f"{p} reads its tests from test and sets no test filter", not bad, bad)
    have = inline_config()
    want = sorted(INLINE_CONFIG)
    check(f"the forge-config lines of test, proofs and script are exactly the {len(want)} recorded ones", have == want,
          f"missing {sorted(set(want) - set(have))} extra {sorted(set(have) - set(want))}")


def read_build():
    # the version forge prints, the two bytecode objects of each contract in out, the source map of its runtime
    # code and its immutable ranges, read right after a build
    rc, ver, _ = deployed.run(['forge', '--version'])
    objects, maps, refs = {}, {}, {}
    for c in CONTRACTS:
        a = json.load(open(os.path.join(root, 'out', f'{c}.sol', f'{c}.json')))
        for field in ('bytecode', 'deployedBytecode'):
            objects[(c, field)] = a[field]['object']
        maps[c] = a['deployedBytecode'].get('sourceMap', '')
        refs[c] = [r for ranges in a['deployedBytecode'].get('immutableReferences', {}).values() for r in ranges]
    return {'version': (rc, ver), 'objects': objects, 'maps': maps, 'refs': refs}


def part_section(part, heading):
    # one ### section of Part 1, up to the next heading
    m = re.search(r'^### ' + re.escape(heading) + r'\n.*?(?=^#{2,3} |\Z)', part, re.M | re.S)
    return m.group(0) if m else ''


def spoken_list(nums):
    # 508, 1,619 and 2,301, as the immutables table of Part 1 writes its ranges
    s = [f'{n:,}' for n in nums]
    return 'none' if not s else s[0] if len(s) == 1 else ', '.join(s[:-1]) + ' and ' + s[-1]


def g43():
    # the build of G-9, which the suites run on, or a clean build of its own when G-9 did not build
    if 'build' not in state:
        rc1, out1 = run(['forge', 'clean'])
        rc2, out2 = run(['forge', 'build', '--sizes'])
        if not check("forge clean && forge build --sizes with no profile set, as G-9 did not build", rc1 == 0 and rc2 == 0,
                     (out1 + out2)[-800:]):
            return
        state['build'] = read_build()
    part = deployed.build_part()
    # the record describes these sources only if its sha256 rows are theirs, as G-29 checks for the mutation record
    for c in CONTRACTS:
        have = sha256(os.path.join(root, 'src', f'{c}.sol'))
        rows = re.findall(r'^\| `src/' + c + r'\.sol` \| sha256 `([0-9a-f]{64})` \|$', part, re.M)
        check(f"src/{c}.sol: its sha256 row in Part 1 is {have}", rows == [have], rows or 'no row')
    want = deployed.record_hashes(part)
    check("Part 1 of gates/review-record.md holds six build hashes", len(want) == 6, sorted(want))
    row = re.search(r'^\| `forge --version` \| (.*) \|$', part, re.M)
    pinned = re.findall(r'`([^`]+)`', row.group(1)) if row else []
    rc, ver = state['build']['version']
    lines = [l.strip() for l in ver.split('\n') if l.strip()]
    differ = [f"{have or 'nothing'} where Part 1 has {pin or 'nothing'}"
              for have, pin in itertools.zip_longest(lines, pinned) if have != pin]
    check("forge --version of the build is the four lines of Part 1, line for line",
          rc == 0 and len(pinned) == 4 and not differ, differ or f"exit {rc}, Part 1 has {len(pinned)} lines")
    for c in CONTRACTS:
        for field in ('bytecode', 'deployedBytecode'):
            h = deployed.keccak(state['build']['objects'][(c, field)])
            check(f"{c}: keccak256 of {field}.object of the build equals Part 1", h == want.get((c, field)),
                  f"built {h or 'no hash'}, Part 1 {want.get((c, field)) or 'no value'}")
    # the byte counts, sizes and immutable ranges of Part 1 are signed with the hashes, so they must be this build's too
    size = {k: (len(v) - 2) // 2 for k, v in state['build']['objects'].items()}
    hashes, sizes, imm = (part_section(part, h) for h in ('Build hashes', 'Sizes', 'Immutables and constructor arguments'))
    for c in CONTRACTS:
        for field in ('bytecode', 'deployedBytecode'):
            rows = re.findall(r'^\| `' + c + r'` \| `' + field + r'\.object` \| ([\d,]+) \| `0x[0-9a-f]{64}` \|$', hashes, re.M)
            check(f"{c}: the byte count of {field}.object in Part 1 is {size[(c, field)]:,}", rows == [f'{size[(c, field)]:,}'], rows)
        rt, ic = size[(c, 'deployedBytecode')], size[(c, 'bytecode')]
        want_row = (f'{rt:,}', f'{24576 - rt:,}', f'{ic:,}', f'{49152 - ic:,}')
        rows = re.findall(r'^\| `' + c + r'` \| ([\d,]+) \| ([\d,]+) \| ([\d,]+) \| ([\d,]+) \|$', sizes, re.M)
        check(f"{c}: the Sizes row of Part 1 is {' | '.join(want_row)}", rows == [want_row], rows)
        refs = state['build']['refs'][c]
        ranges = spoken_list(sorted(r['start'] for r in refs))
        rows = re.findall(r'^\| `' + c + r'` \| [^|\n]* \| [^|\n]* \| ([^|\n]*?) \|$', imm, re.M)
        check(f"{c}: the immutable ranges of Part 1 are {ranges}, each 32 bytes",
              rows == [ranges] and all(r['length'] == 32 for r in refs), (rows, [r['length'] for r in refs]))


# G-44: the opcodes of the runtime code of each contract, metadata left out, that no contract may hold or holds a
# fixed number of times. ORIGIN would let a check depend on who signed the transaction instead of the caller.
OPCODE_COUNTS = {
    'PageNFT': {'ORIGIN': 0, 'CALLCODE': 0, 'SELFDESTRUCT': 0, 'CREATE': 0, 'CREATE2': 0, 'DELEGATECALL': 1,
                'CALL': 3, 'STATICCALL': 3},
    'PageCard': {'ORIGIN': 0, 'CALLCODE': 0, 'SELFDESTRUCT': 0, 'CREATE': 0, 'CREATE2': 0, 'DELEGATECALL': 0,
                 'CALL': 0, 'STATICCALL': 0, 'SSTORE': 0, 'SLOAD': 0},
    'SubpageRegistrar': {'ORIGIN': 0, 'CALLCODE': 0, 'SELFDESTRUCT': 0, 'CREATE': 0, 'CREATE2': 0, 'DELEGATECALL': 0,
                         'CALL': 3, 'STATICCALL': 16},
}
# the number of call sites of the optimized IR of each contract. With the CALL and STATICCALL counts above, a new call
# of any target, also one whose address is computed at run time or read from an immutable, fails this gate
IR_CALL_COUNTS = {'PageNFT': 8, 'PageCard': 0, 'SubpageRegistrar': 23}
# the imports each source may have: the other contracts, and the pinned solady and soledge files it already uses
SRC_IMPORT = re.compile(r'(\./(PageNFT|PageCard|SubpageRegistrar)\.sol|solady/[\w/]+\.sol|soledge/[\w/]+\.sol)')
OPCODES = {0x32: 'ORIGIN', 0x54: 'SLOAD', 0x55: 'SSTORE', 0x5a: 'GAS', 0xf0: 'CREATE', 0xf1: 'CALL', 0xf2: 'CALLCODE',
           0xf4: 'DELEGATECALL', 0xf5: 'CREATE2', 0xfa: 'STATICCALL', 0xff: 'SELFDESTRUCT'}
# values that only a signature check holds: the ERC1271 magic values of isValidSignature(bytes32,bytes) and of the
# older isValidSignature(bytes,bytes), and the ERC6492 suffix. The optimizer writes a constant with trailing zero bits
# as its odd part shifted left, as shl(225, 0x0b135d3f) for the selector 0x1626ba7e in the first four bytes of a word,
# so a value counts in any shift: every PUSH, every constant kept after the code and every number of the optimized IR
# is compared by its odd part
SIG_VALUES = {0x1626ba7e: 'the ERC1271 magic value 0x1626ba7e', 0x20c13b0b: 'the older ERC1271 magic value 0x20c13b0b',
              int('64926492' * 8, 16): 'the ERC6492 suffix'}


def odd_part(v):
    while v and v % 2 == 0:
        v //= 2
    return v


SIG_ODD = {odd_part(v): what for v, what in SIG_VALUES.items()}
# the precompiles: 0x01 to 0x11 on Ethereum since Prague, and P256VERIFY at 0x100 on OP Mainnet
PRECOMPILES = set(range(0x01, 0x12)) | {0x100}
# every call of the optimized IR whose target is a number, per contract: only the identity precompile 0x04, which
# copies the data argument in the receiver check of the ERC721 library
LITERAL_CALLS = {'PageNFT': {('staticcall', 4): 2}, 'PageCard': {}, 'SubpageRegistrar': {}}


def runtime_body(contract):
    # the runtime code of the build of G-9, or of a clean build of its own when G-9 did not build, with the CBOR
    # metadata at its end left out. Later gates build in out with other settings, so out is read only right after
    # that build
    if 'build' not in state:
        rc1, out1 = run(['forge', 'clean'])
        rc2, out2 = run(['forge', 'build', '--sizes'])
        if rc1 != 0 or rc2 != 0:
            raise RuntimeError(f"forge clean && forge build --sizes failed:\n{(out1 + out2)[-800:]}")
        state['sizes'] = (rc2, out2)
        state['build'] = read_build()
    h = state['build']['objects'][(contract, 'deployedBytecode')]
    code = bytes.fromhex(h[2:] if h.startswith('0x') else h)
    n = int.from_bytes(code[-2:], 'big')
    return code[:-(n + 2)], state['build']['maps'][contract]


def opcodes(code, count):
    # the first count instructions of code as (offset, opcode, immediate), with the immediate of a PUSH as a number,
    # and the offset where they end. The source map has one entry per instruction, and the bytes after them are the
    # constants the compiler keeps as data, which are never run
    out, i = [], 0
    while i < len(code) and len(out) < count:
        op = code[i]
        if 0x60 <= op <= 0x7f:
            k = op - 0x5f
            out.append((i, op, int.from_bytes(code[i + 1:i + 1 + k], 'big')))
            i += 1 + k
        else:
            out.append((i, op, None))
            i += 1
    return out, i


def ir_calls(contract):
    # (kind, target) of every call in the deployed object of the optimized IR, with comments and strings left out
    rc, out = run(['forge', 'inspect', f'src/{contract}.sol:{contract}', 'irOptimized'])
    if rc != 0:
        # an artefact built without the IR makes forge inspect fail, so it gets one forced rebuild, as in inspect
        rc, out = run(['forge', 'inspect', f'src/{contract}.sol:{contract}', 'irOptimized', '--force'])
    if rc != 0:
        raise RuntimeError(f"forge inspect {contract} irOptimized failed:\n{out[-600:]}")
    s = re.sub(r'/\*.*?\*/', ' ', out, flags=re.S)
    s = re.sub(r'///[^\n]*', ' ', s)
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
    objs = [m.start() for m in re.finditer(r'\bobject\s+""', s)]
    dep = s[objs[1]:] if len(objs) > 1 else ''
    calls = []
    for m in re.finditer(r'(?<![\w$.])(call|staticcall|delegatecall|callcode)\(', dep):
        depth, j, args, start = 1, m.end(), [], m.end()
        while j < len(dep) and depth:
            ch = dep[j]
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch == ',' and depth == 1:
                args.append(dep[start:j].strip())
                start = j + 1
            j += 1
        args.append(dep[start:j - 1].strip())
        calls.append((m.group(1), args[1] if len(args) > 1 else ''))
    return dep, calls


def g44():
    for c in CONTRACTS:
        raw_c = strip_comments(raw[c])
        words = sorted(set(re.findall(r'ecrecover|isValidSignature|isValidERC1271|SignatureChecker|ECDSA|P256|EIP712|ERC1271|'
                                      r'ERC6492|WebAuthn|tx\.origin|\bpermit\b|\bnonces?\b', raw_c, re.I)))
        check(f"{c}.sol: no ecrecover, isValidSignature, signature library, EIP712, permit, nonce or tx.origin in the code",
              not words, words)
    present = sorted(f for f in os.listdir(os.path.join(root, 'src')) if not f.startswith('.'))
    check("src holds exactly the three contracts, so the checks above read every source file",
          present == sorted(f'{c}.sol' for c in CONTRACTS), present)
    for c in CONTRACTS:
        imports = [i.strip() for i in re.findall(r'^[ \t]*import\b[^;]*;', strip_comments(raw[c]), re.M)]
        paths = [re.search(r'"([^"]+)"', i) for i in imports]
        bad = [i for i, p in zip(imports, paths) if not (p and re.fullmatch(r'import\s*\{[\w\s,]+\}\s*from\s*"[^"]+"\s*;', i)
                                                         and SRC_IMPORT.fullmatch(p.group(1)))]
        check(f"{c}.sol imports by name only the other contracts and solady and soledge files", not bad, bad)
    for c in CONTRACTS:
        body, smap = runtime_body(c)
        ins, end = opcodes(body, len(smap.split(';')) if smap else 0)
        data = body[end:]
        check(f"{c}: the source map covers the runtime code up to an INVALID, followed only by 32 byte constants",
              len(ins) > 0 and data[:1] == b'\xfe' and (len(data) - 1) % 32 == 0, f"{len(ins)} instructions, "
              f"{len(data)} bytes after them")
        counts = {}
        for _, op, _ in ins:
            if op in OPCODES:
                counts[OPCODES[op]] = counts.get(OPCODES[op], 0) + 1
        want = OPCODE_COUNTS[c]
        have = {k: counts.get(k, 0) for k in want}
        check(f"{c}: the runtime code holds {', '.join(f'{k} {v} times' for k, v in want.items())}", have == want, have)
        words = [int.from_bytes(data[1 + 32 * k:33 + 32 * k], 'big') for k in range((len(data) - 1) // 32)]
        held = sorted({f"{SIG_ODD[odd_part(v)]} in a PUSH" for _, op, v in ins if v is not None and odd_part(v) in SIG_ODD}
                      | {f"{SIG_ODD[odd_part(w)]} in a constant after the code" for w in words if odd_part(w) in SIG_ODD})
        check(f"{c}: no PUSH and no constant of the runtime code is an ERC1271 magic value or the ERC6492 suffix, in any "
              "shift", not held, held)
        # a call whose target is pushed right before GAS, as the compiler writes a call to a fixed address
        fixed = sorted({f"{OPCODES[op]} to {hex(ins[k - 2][2])} at {off}" for k, (off, op, _) in enumerate(ins)
                        if op in (0xf1, 0xf2, 0xf4, 0xfa) and k >= 2 and ins[k - 1][1] == 0x5a
                        and ins[k - 2][2] is not None and ins[k - 2][2] in PRECOMPILES - {4}})
        check(f"{c}: no call in the runtime code goes to a fixed precompile other than the identity, 0x04", not fixed, fixed)
        dep, calls = ir_calls(c)
        literal = {}
        for kind, target in calls:
            if re.fullmatch(r'0x[0-9a-fA-F]+|\d+', target):
                key = (kind, int(target, 0))
                literal[key] = literal.get(key, 0) + 1
        check(f"{c}: the calls of the optimized IR to a number are exactly {LITERAL_CALLS[c] or 'none'}, so no call goes "
              "to ecrecover, P256VERIFY or another precompile but the identity", literal == LITERAL_CALLS[c], literal)
        check(f"{c}: the optimized IR has exactly {IR_CALL_COUNTS[c]} call sites, so no call was added",
              len(calls) == IR_CALL_COUNTS[c], len(calls))
        check(f"{c}: the optimized IR uses no origin()", not re.search(r'(?<![\w$.])origin\(\)', dep))
        lits = {int(x, 0) for x in re.findall(r'(?<![\w$.])(0x[0-9a-fA-F]+|\d+)(?![\w$.])', dep)}
        found = sorted({SIG_ODD[odd_part(v)] for v in lits if odd_part(v) in SIG_ODD})
        check(f"{c}: no number of the optimized IR is an ERC1271 magic value or the ERC6492 suffix, in any shift",
              not found, found)
        print(f"      {c}: {len(ins)} instructions in {end} bytes, {(len(data) - 1) // 32} constants after them, "
              f"{len(calls)} calls in the optimized IR, " + ', '.join(f"{k} {v}" for k, v in sorted(counts.items())))


# G-45 reads every use of the caller in PageNFT.sol, SubpageRegistrar.sol and PageCard.sol, comments removed and string
# literals emptied. The caller is msg.sender in any spelling, a local declared as an exact copy of it (casts allowed) or
# a parameter of a function of the same file that some call there passes an exact copy of, followed through every call
# to a fixed point. A comparison with the caller is any ==, !=, <, >, <= or >= outside assembly with the caller in one
# of its two operands, written 'function: left op right' with no spaces. Each is listed here with why the zero caller
# cannot get past it, so any new or changed comparison, and any new use of msg.sender, fails until it is reviewed.
CALLER_COMPARISONS = {
    'PageNFT': [
        # the three guards
        'approve: msg.sender==address(0)', 'transferFrom: msg.sender==address(0)',
        '_registerSubpage: msg.sender==address(0)',
        # ownerOf of the library reverts for a name never minted and never answers zero, and PageNFT does not override it
        'clearRecords: ownerOf(tokenId)!=msg.sender', 'keepProfile: ownerOf(tokenId)!=msg.sender',
        'setAddr: ownerOf(tokenId)!=msg.sender', 'setAddrForCoin: ownerOf(tokenId)!=msg.sender',
        'setContenthash: ownerOf(tokenId)!=msg.sender', 'setData: ownerOf(tokenId)!=msg.sender',
        'setText: ownerOf(tokenId)!=msg.sender',
        'setPrimaryPage: msg.sender!=holder',
        # reached only after the ownerOf check of the same call, so the caller is the holder and an unwritten writer or
        # saver, which reads as zero, never matches it: _writeSlot from setText and setContenthash, _evmAnswer with the
        # caller as owner from _saveAddr, setAddrForCoin and clearRecords
        'keepProfile: p.writer==msg.sender', '_writeSlot: p.writer!=msg.sender',
        '_evmAnswer: c.saver==owner', '_evmAnswer: c.saver==owner',
        # resolve answers zero only for a name that is not active, and setPrimaryPage checks _isActive first
        'setPrimaryPage: msg.sender!=resolve(tokenId)',
        # _ownerOf of a record that exists, checked just before, which is never zero: a record exists only with its token
        '_registerSubpage: owner!=msg.sender', 'setSubpageMinter: _ownerOf(parentId)!=msg.sender',
        # _minterFor answers zero when no minter counts, which is why the guard before it refuses the zero caller
        '_registerSubpage: _minterFor(parentId,owner)!=msg.sender',
        # the only comparison the zero caller passes: an unwritten pick has the zero address as its setter, so it may
        # write an empty pick there, and no minter counts before or after (test_zeroCallerClearsOnlyAnUnwrittenMinterRecord
        # of test/attack/ZeroCallerOrder.t.sol)
        'setSubpageMinter: _subpageMinter[parentId].setter!=msg.sender',
        # picks _mint or _safeMint, and _mint refuses the zero receiver
        '_mintTo: to==msg.sender',
        # only picks how an address is written, empty for zero, for the events of clearRecords
        '_encode: a==address(0)',
    ],
    'SubpageRegistrar': [
        # ownerOf of PageNFT reverts for a name never minted and never answers zero
        'configure: registry.ownerOf(parentId)!=msg.sender', 'disable: registry.ownerOf(parentId)!=msg.sender',
        # refuses this contract as the receiver; a zero receiver is refused by the mint of PageNFT
        '_sell: to==address(this)',
        # the gate token balance of the buyer, who pays the price like any other buyer
        '_sell: _gateBalance(c.gateToken,msg.sender)<uint256(c.minGateBalance)',
    ],
    'PageCard': [],
}
# the comparisons above that test the caller against zero: one side is the caller and the other is zero in a literal
# spelling, or the comparison is an order, which for an address or a number made from one is only a test of zero
CALLER_ZERO_TESTS = {
    'PageNFT': ['_encode: a==address(0)', '_registerSubpage: msg.sender==address(0)', 'approve: msg.sender==address(0)',
                'transferFrom: msg.sender==address(0)'],
    'SubpageRegistrar': [], 'PageCard': [],
}
# every use of msg.sender, as 'function: statement' with the statement running from the ; { or } before it to the one
# after it, so a local copy, a call that passes the caller on and a stored caller all show
CALLER_USES = {
    'PageNFT': [
        '_mintTo: if (to == msg.sender || _isKeyWallet(to)) _mint(to, tokenId)',
        '_refundExcess: if (msg.value > required) SafeTransferLib.safeTransferETH(msg.sender, msg.value - required)',
        '_registerSubpage: bool byMinter = owner != msg.sender',
        '_registerSubpage: if (byMinter && (msg.sender == address(0) || _minterFor(parentId, owner) != msg.sender)) '
        'revert NotParentOwner()',
        '_registerSubpage: if (byMinter && (msg.sender == address(0) || _minterFor(parentId, owner) != msg.sender)) '
        'revert NotParentOwner()',
        '_registerTopLevel: emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId])',
        '_registerTopLevel: emit TrialStarted(tokenId, msg.sender, fee)',
        '_registerTopLevel: trialPaymentOf[tokenId] = TrialPayment(msg.sender, uint96(fee))',
        '_saveAddr: _addrSaver[tokenId][v] = msg.sender',
        '_saveAddr: _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender))',
        '_saveAddr: address main = a == address(0) ? msg.sender : a',
        '_writeSlot: emit ProfileWriterChanged(bytes32(tokenId), msg.sender, true)',
        '_writeSlot: if (p.writer != msg.sender)',
        '_writeSlot: p.writer = msg.sender',
        'approve: if (msg.sender == address(0)) revert NotOwnerNorApproved()',
        'clearRecords: _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender))',
        'clearRecords: _emitCoin(tokenId, COIN_TYPE_OP, msg.sender)',
        'clearRecords: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'commit: emit Committed(commitment, msg.sender)',
        'keepProfile: emit ProfileWriterChanged(bytes32(tokenId), msg.sender, false)',
        'keepProfile: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'keepProfile: if (p.writer == msg.sender) revert AlreadyKept()',
        'keepProfile: p.writer = msg.sender',
        'registerSubpage: return _registerSubpage(label, parentId, msg.sender)',
        'renew: emit DepositAdded(tokenId, msg.sender, fee, depositOf[tokenId])',
        'setAddr: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'setAddrForCoin: _emitCoin(tokenId, COIN_TYPE_ETH, _evmAnswer(tokenId, COIN_TYPE_ETH, msg.sender))',
        'setAddrForCoin: c.saver = msg.sender',
        'setAddrForCoin: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'setContenthash: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'setData: d.saver = msg.sender',
        'setData: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'setPrimaryPage: _primaryHolder[msg.sender] = holder',
        'setPrimaryPage: delete primaryPage[msg.sender]',
        'setPrimaryPage: emit PrimaryPageSet(msg.sender, 0)',
        'setPrimaryPage: emit PrimaryPageSet(msg.sender, tokenId)',
        'setPrimaryPage: if (msg.sender != holder && msg.sender != resolve(tokenId)) revert Unauthorized()',
        'setPrimaryPage: if (msg.sender != holder && msg.sender != resolve(tokenId)) revert Unauthorized()',
        'setPrimaryPage: primaryPage[msg.sender] = tokenId',
        'setSubpageMinter: _subpageMinter[parentId] = SubpageMinter(minter, epoch, msg.sender)',
        'setSubpageMinter: emit SubpageMinterSet(parentId, msg.sender, minter, epoch)',
        'setSubpageMinter: if (_ownerOf(parentId) != msg.sender)',
        'setSubpageMinter: if (minter != address(0) || _subpageMinter[parentId].setter != msg.sender) revert Unauthorized()',
        'setText: if (ownerOf(tokenId) != msg.sender) revert Unauthorized()',
        'transferFrom: if (msg.sender == address(0)) revert NotOwnerNorApproved()',
        'withdraw: emit Withdrawn(account, msg.sender, amount)',
    ],
    'SubpageRegistrar': [
        '_sell: else SafeTransferLib.safeTransferFrom(c.feeToken, msg.sender, c.payout, price)',
        '_sell: emit SubpageSold(parentId, subId, msg.sender, to, c.payout, c.feeToken, price, label)',
        '_sell: if (c.gateToken != address(0) && _gateBalance(c.gateToken, msg.sender) < uint256(c.minGateBalance)) '
        'revert GateFailed()',
        '_sell: if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund)',
        'claimProceeds: return _payProceeds(msg.sender, to)',
        'commitSubpage: emit Committed(commitment, msg.sender)',
        'configure: controller: msg.sender, enabled: enabled, commitReveal: commitReveal, feeToken: feeToken, '
        'price: uint96(price), gateToken: gateToken, minGateBalance: uint96(minGateBalance), payout: payout, '
        'parentEpoch: epoch',
        'configure: emit ParentConfigured(parentId, msg.sender, payout, feeToken, price, gateToken, minGateBalance, '
        'enabled, commitReveal, epoch)',
        'configure: if (registry.ownerOf(parentId) != msg.sender) revert NotAuthorized()',
        'configure: if (payout == address(0)) payout = msg.sender',
        'disable: if (registry.ownerOf(parentId) != msg.sender) revert NotAuthorized()',
        'registerSubpage: return registerSubpageFor(parentId, label, msg.sender, maxPrice, expectedFeeToken)',
        'revealSubpage: return revealSubpageFor(parentId, label, msg.sender, secret, maxPrice, expectedFeeToken)',
    ],
    'PageCard': [],
}
# every call, in the same file, of a function that reads msg.sender in its body or through a function it calls, as
# 'caller -> callee', so that no new path reaches a check of the caller made in a helper such as _writeSlot or _mintTo
CALLER_READER_CALLS = {
    'PageNFT': ['_registerSubpage -> _mintTo', '_registerTopLevel -> _mintTo', '_registerTopLevel -> _refundExcess',
                'registerSubpage -> _registerSubpage', 'registerSubpageFor -> _registerSubpage', 'renew -> _refundExcess',
                'reveal -> _registerTopLevel', 'revealTrial -> _registerTopLevel', 'setAddr -> _saveAddr',
                'setAddrForCoin -> _saveAddr', 'setContenthash -> _writeSlot', 'setText -> _writeSlot'],
    'SubpageRegistrar': ['registerSubpage -> registerSubpageFor', 'registerSubpageFor -> _sell',
                         'revealSubpage -> revealSubpageFor', 'revealSubpageFor -> _sell'],
    'PageCard': [],
}
# what each file imports and declares, so that no other file adds code that G-45 does not read
CALLER_FILES = {
    'PageNFT': (['solady/utils/Base64.sol', 'solady/tokens/ERC721.sol', 'solady/utils/LibString.sol',
                 'solady/utils/SafeTransferLib.sol', './PageCard.sol', 'soledge/utils/ReentrancyGuard.sol'],
                ['contract PageNFT is ERC721, ReentrancyGuard']),
    'SubpageRegistrar': (['solady/utils/SafeTransferLib.sol', 'soledge/utils/ReentrancyGuard.sol'],
                         ['interface IERC721Like', 'interface IPageNFT is IERC721Like',
                          'contract SubpageRegistrar is ReentrancyGuard']),
    'PageCard': (['solady/utils/LibString.sol'], ['contract PageCard']),
}
# the functions of the ERC721 library PageNFT overrides: ownerOf and the approval reads stay those of the library
NFT_OVERRIDES = ['_afterTokenTransfer', '_beforeTokenTransfer', 'approve', 'name', 'supportsInterface', 'symbol',
                 'tokenURI', 'transferFrom']

_SENDER = re.compile(r'\bmsg\s*\.\s*sender\b')
_CMP = re.compile(r'(?<![=!<>])(==|!=|<=|>=|<|>)(?![=<>])')
_CASTS = r'(?:address|payable|uint\d*|int\d*|bytes\d*)'


def code_text(s):
    # comments removed and every string literal emptied in one pass, so that // or a quote inside a string stays out
    # of the code, and (msg) written as msg with the same length, so that positions stay
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j == -1 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2)
            out.append(' ')
            i = n if j == -1 else j + 2
        elif s[i] in '"\'':
            q, j = s[i], i + 1
            while j < n and s[j] != q:
                j += 2 if s[j] == '\\' else 1
            out.append(q + q)
            i = j + 1
        else:
            out.append(s[i])
            i += 1
    s, prev = ''.join(out), None
    while s != prev:
        prev, s = s, re.sub(r'\(\s*msg\s*\)', lambda m: 'msg' + ' ' * (len(m.group(0)) - 3), s)
    return s


def _close(s, i):
    # the index of the brace that closes the one at i
    depth = 0
    for j in range(i, len(s)):
        depth += {'{': 1, '}': -1}.get(s[j], 0)
        if depth == 0:
            return j
    raise ValueError('unbalanced braces')


def asm_spans(s):
    return [(m.start(), _close(s, m.end() - 1)) for m in re.finditer(r'\bassembly\b[^{;]*\{', s)]


def bodies(s):
    # (name, header, open brace, close brace) of every function, modifier, constructor, receive and fallback with a
    # body, outside assembly; a modifier is named 'modifier <name>'
    asm, out = asm_spans(s), []
    for m in re.finditer(r'\b(?:function\s+(\w+)|modifier\s+(\w+)|(constructor|receive|fallback))\s*\(', s):
        if any(a <= m.start() <= b for a, b in asm):
            continue
        i, semi = s.find('{', m.end()), s.find(';', m.end())
        if i == -1 or (semi != -1 and semi < i):
            continue
        out.append((m.group(1) or (m.group(2) and 'modifier ' + m.group(2)) or m.group(3), s[m.start():i], i, _close(s, i)))
    return out


def split_args(t):
    # the arguments of a call or the parameters of a header, split at the commas of depth 0
    out, depth, cur = [], 0, ''
    for c in t:
        depth += {'(': 1, '[': 1, ')': -1, ']': -1}.get(c, 0)
        if c == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += c
    return out + [cur.strip()] if cur.strip() else out


def _paren(s, i):
    # the text between the parenthesis that opens just before i and its match
    depth, j = 1, i
    while j < len(s) and depth:
        depth += {'(': 1, ')': -1}.get(s[j], 0)
        j += 1
    return s[i:j - 1]


def _uncast(t):
    # an expression without spaces and without the casts and parentheses around it
    t, prev = nospace(t), None
    while t != prev:
        prev = t
        m = re.fullmatch(_CASTS + r'\((.*)\)', t) or re.fullmatch(r'\((.*)\)', t)
        if m and _balanced(m.group(1)):
            t = m.group(1)
    return t


def _balanced(t):
    depth = 0
    for c in t:
        depth += {'(': 1, ')': -1}.get(c, 0)
        if depth < 0:
            return False
    return depth == 0


def _operand(s, i, step):
    # the operand of a comparison next to i, read left (step -1) or right (step 1) up to the first token of depth 0
    # that ends an operand of an equality or an order: ; { } , ? : && || an assignment or another comparison
    opens, closes = ('([', ')]') if step == 1 else (')]', '([')
    depth, j = 0, i
    while 0 <= j < len(s):
        c = s[j]
        if c in opens:
            depth += 1
        elif c in closes:
            if depth == 0:
                break
            depth -= 1
        elif depth == 0:
            pair = s[j:j + 2] if step == 1 else s[j - 1:j + 1]
            if c in ';{},?:' or pair in ('&&', '||') or c in '=<>' or (c == '!' and s[j + 1:j + 2] == '='):
                break
        j += step
    t = s[i:j] if step == 1 else s[j + 1:i + 1]
    return re.sub(r'^\s*(return|emit|revert)\b', '', t).strip()


def zero_spelled(t, consts):
    # whether an expression is zero in a literal spelling: 0, 0x0, 0x00, 0_0, 0e1, 0 wei, a cast of one such as
    # address(0x0), address(uint160(0)) or address(bytes20(0)), type(uintN).min, or a constant declared as one
    t, seen = _uncast(t), set()
    while t in consts and t not in seen:
        seen.add(t)
        t = _uncast(consts[t])
    t = re.sub(r'(wei|gwei|ether|seconds|minutes|hours|days|weeks)$', '', t)
    return bool(re.fullmatch(r'type\(uint\d*\)\.min|0[xX][0_]*|[0_]+(\.[0_]*)?([eE]-?\d+)?|\.[0_]+([eE]-?\d+)?', t))


def caller_sites(src):
    # (uses, comparisons, zero tests, assembly blocks, copies) of one source file, as G-45 reads them
    s = code_text(src)
    asm, bs = asm_spans(s), bodies(s)
    consts = {m.group(1): m.group(2) for m in re.finditer(r'\bconstant\s+(\w+)\s*=\s*([^;]+);', s)}

    def inner(pos):
        inside = [(b - a, k) for k, (_, _, a, b) in enumerate(bs) if a < pos < b]
        return max(inside)[1] if inside else None

    def where(pos):
        k = inner(pos)
        return bs[k][0] if k is not None else '<outside>'

    uses = []
    for m in _SENDER.finditer(s):
        a = max(s.rfind(c, 0, m.start()) for c in ';{}') + 1
        b = min([x for x in (s.find(c, m.end()) for c in ';{}') if x != -1] or [len(s)])
        uses.append(f"{where(m.start())}: {flat(s[a:b])}")
    # the copies of the caller in each body, to a fixed point over locals and the parameters calls pass it to
    copies = [set() for _ in bs]
    exact = lambda t, k: _uncast(t) == 'msg.sender' or _uncast(t) in copies[k]
    names = {n for n, _, _, _ in bs}
    changed = True
    while changed:
        changed = False
        for k, (_, _, a, b) in enumerate(bs):
            body = s[a + 1:b]
            for m in re.finditer(r'(?<![.\w])(?:address(?:\s+payable)?|u?int\d*|bytes\d+)\s+(\w+)\s*=(?![=>])([^;]*);', body):
                if exact(m.group(2), k) and m.group(1) not in copies[k]:
                    copies[k].add(m.group(1))
                    changed = True
            for m in re.finditer(r'(?<![.\w])(\w+)\s*\(', body):
                if m.group(1) not in names or re.search(r'\b(emit|revert|function)\s*$', body[:m.start()]):
                    continue
                args = split_args(_paren(body, m.end()))
                for i, arg in enumerate(args):
                    if not exact(arg, k):
                        continue
                    for j, (n, head, _, _) in enumerate(bs):
                        ps = split_args(_paren(head, head.index('(') + 1)) if n == m.group(1) else []
                        if len(ps) == len(args) and len(ps[i].split()) > 1 and ps[i].split()[-1] not in copies[j]:
                            copies[j].add(ps[i].split()[-1])
                            changed = True
    comparisons, zeros = [], []
    for m in _CMP.finditer(s):
        if any(x <= m.start() <= y for x, y in asm):
            continue
        k = inner(m.start())
        mine = copies[k] if k is not None else set()
        left, right = _operand(s, m.start() - 1, -1), _operand(s, m.end(), 1)
        mentions = lambda t: _SENDER.search(t) or any(re.search(r'(?<![.\w])' + re.escape(v) + r'\b', t) for v in mine)
        if not (mentions(left) or mentions(right)):
            continue
        site = f"{where(m.start())}: {nospace(left)}{m.group(1)}{nospace(right)}"
        comparisons.append(site)
        is_caller = lambda t: _uncast(t) == 'msg.sender' or _uncast(t) in mine
        if (is_caller(left) and (zero_spelled(right, consts) or m.group(1) not in ('==', '!='))) or \
                (is_caller(right) and (zero_spelled(left, consts) or m.group(1) not in ('==', '!='))):
            zeros.append(site)
    return sorted(uses), sorted(comparisons), sorted(zeros), [s[x:y + 1] for x, y in asm], \
        {bs[k][0]: sorted(v) for k, v in enumerate(copies) if v}


def caller_reads(src):
    # every call of a function of the file that reads msg.sender, in its body or through a function it calls, as
    # 'caller -> callee', with a modifier named in a header counted as a call
    s = code_text(src)
    bs = bodies(s)
    names = {n for n, _, _, _ in bs}
    mods = {n[len('modifier '):] for n in names if n.startswith('modifier ')}
    calls = []
    for n, head, a, b in bs:
        body = s[a + 1:b]
        calls += [(n, m.group(1)) for m in re.finditer(r'(?<![.\w])(\w+)\s*\(', body)
                  if m.group(1) in names and not re.search(r'\b(emit|revert|function)\s*$', body[:m.start()])]
        i = head.index('(') + 1
        calls += [(n, 'modifier ' + w) for w in re.findall(r'\b(\w+)\b', head[i + len(_paren(head, i)) + 1:]) if w in mods]
    readers, more = set(), {n for n, _, a, b in bs if _SENDER.search(s[a:b])}
    while more:
        readers |= more
        more = {c for c, f in calls if f in readers} - readers
    return sorted(f"{c} -> {f}" for c, f in calls if f in readers)


def g45():
    for n, call in (('approve', 'super.approve(account, id);'), ('transferFrom', 'super.transferFrom(from, to, id);')):
        check(f"PageNFT: {n} refuses ETH, then the zero caller, and only then runs the ERC721 library",
              flat(one(fn, n)) == 'if (msg.value != 0) revert UnexpectedValue(); '
              f'if (msg.sender == address(0)) revert NotOwnerNorApproved(); {call}', flat(one(fn, n)))
    check("PageNFT: _registerSubpage refuses the zero caller as a minter",
          'bool byMinter = owner != msg.sender; if (byMinter && (msg.sender == address(0) || '
          '_minterFor(parentId, owner) != msg.sender)) revert NotParentOwner();' in flat(one(fn, '_registerSubpage')))
    check("PageNFT: msg.sender == address(0) appears exactly in those three places", nft.count('msg.sender == address(0)') == 3,
          nft.count('msg.sender == address(0)'))
    check("PageNFT declares no safeTransferFrom and no setApprovalForAll, so both safe transfers run transferFrom",
          'safeTransferFrom' not in fn and 'setApprovalForAll' not in fn)
    check("PageNFT names no ERC721 helper that takes an acting account, whose check an account of zero skips, not even "
          "as a function pointer",
          not re.search(r'\b_(transfer|approve|safeTransfer|setApprovalForAll)\b', nft)
          and not re.search(r'\b_burn\s*\([^,()]*,', nft), re.findall(r'\b_(?:transfer|approve|safeTransfer|setApprovalForAll)\b', nft))
    check("registerSubpage and registerSubpageFor both run _registerSubpage",
          nospace(one(fn, 'registerSubpage')) == 'return_registerSubpage(label,parentId,msg.sender);'
          and nospace(one(fn, 'registerSubpageFor')) == 'return_registerSubpage(label,parentId,to);')
    # the same rules in every spelling the checks above do not read
    for n, head in (('approve', 'function approve(address account, uint256 id) public payable override(ERC721)'),
                    ('transferFrom', 'function transferFrom(address from, address to, uint256 id) public payable '
                                     'override(ERC721)')):
        heads = [flat(h) for h, _ in fn.get(n, [])]
        check(f"PageNFT: {n} is declared once, as {head}, so no modifier runs before its guard", heads == [head], heads)
    code = re.sub(r'^\s*import[^;]*;', '', nft, flags=re.M)
    supers = sorted(nospace(m) for m in re.findall(r'\bsuper\s*\.\s*\w+\s*\([^;]*\)', code))
    check("PageNFT runs the ERC721 library through super only in supportsInterface, approve and transferFrom",
          supers == sorted(['super.supportsInterface(interfaceId)', 'super.approve(account,id)',
                            'super.transferFrom(from,to,id)']), supers)
    check("PageNFT names no function as ERC721.<name> and names no approval helper of the library, not even as a "
          "function pointer",
          not re.search(r'\bERC721\s*\.\s*\w+', code)
          and not re.search(r'\b(_isApprovedOrOwner|_getApproved|getApproved|isApprovedForAll)\b', code),
          re.findall(r'\bERC721\s*\.\s*\w+|\b(?:_isApprovedOrOwner|_getApproved|getApproved|isApprovedForAll)\b', code))

    def args_at(s, i):
        # the text between the parenthesis that ends at i and its match, and whether it holds a comma of its own
        depth, j, comma = 1, i, False
        while j < len(s) and depth:
            depth += {'(': 1, ')': -1}.get(s[j], 0)
            comma = comma or (s[j] == ',' and depth == 1)
            j += 1
        return s[i:j - 1], comma
    burns = [args_at(code, m.end()) for m in re.finditer(r'\b_burn\s*\(', code)]
    check("every _burn of PageNFT is a call with a single argument, whatever it holds, so no acting account is passed",
          not any(c for _, c in burns) and len(burns) == len(re.findall(r'\b_burn\b', code)), [a for a, c in burns if c])
    # every use of the caller in the three files, against the reviewed lists above
    for c in CONTRACTS:
        s = code_text(raw[c])
        imports = re.findall(r'^\s*import\s*\{[^}]*\}\s*from\s*"([^"]*)"\s*;', raw[c], re.M)
        every = re.findall(r'\bimport\b[^;]*;', s)
        units = [flat(m) for m in re.findall(r'\b((?:abstract\s+)?(?:contract|interface|library)\s+\w+[^{;]*?)\s*\{', s)]
        check(f"{c}.sol imports and declares only what G-45 reads", (imports, units) == CALLER_FILES[c]
              and len(every) == len(imports), (imports, len(every), units))
        msgs = re.findall(r'\bmsg\b(?:\s*\.\s*\w+)?', s)
        asm = [b for b in asm_spans(s) if re.search(r'\b(caller|origin)\s*\(', s[b[0]:b[1]])]
        check(f"{c}.sol reads the caller only as msg.sender: every msg is msg.sender, msg.value, msg.data or msg.sig, "
              f"and no assembly reads caller() or origin()",
              all(re.fullmatch(r'msg\s*\.\s*(sender|value|data|sig)', m) for m in msgs) and not asm,
              [m for m in msgs if not re.fullmatch(r'msg\s*\.\s*(sender|value|data|sig)', m)] + [s[a:b + 1][:80] for a, b in asm])
        uses, cmps, zeros, _, _ = caller_sites(raw[c])
        want = sorted(CALLER_USES[c])
        check(f"{c}.sol: every use of msg.sender is one of the {len(want)} reviewed", uses == want,
              {'new': [u for u in uses if u not in want], 'gone': [u for u in want if u not in uses]})
        want = sorted(CALLER_COMPARISONS[c])
        check(f"{c}.sol: every comparison with the caller or a copy of it is one of the {len(want)} reviewed", cmps == want,
              {'new': [x for x in cmps if x not in want], 'gone': [x for x in want if x not in cmps]})
        want = sorted(CALLER_ZERO_TESTS[c])
        check(f"{c}.sol tests the caller or a copy of it against zero, in any literal spelling or by an order, only in "
              f"{', '.join(want) or 'no place'}", zeros == want, zeros)
        have, want = caller_reads(raw[c]), sorted(CALLER_READER_CALLS[c])
        check(f"{c}.sol: every call of a function that reads the caller is one of the {len(want)} reviewed", have == want,
              {'new': [x for x in have if x not in want], 'gone': [x for x in want if x not in have]})
    # what the reviewed comparisons rely on
    overrides = sorted(n for n, fs in fn.items() for h, _ in fs if re.search(r'\boverride\b', h))
    check("PageNFT overrides only " + ', '.join(NFT_OVERRIDES) + " of the library, so ownerOf reverts for a name never "
          "minted and never answers zero", overrides == NFT_OVERRIDES and not {'ownerOf', '_ownerOf'} & set(fn), overrides)
    for n in ('setSubpageMinter', '_registerSubpage'):
        b = flat(one(fn, n))
        i, j = b.find('if (!_recordExists(parentId)) revert TokenDoesNotExist();'), b.find('_ownerOf(parentId)')
        check(f"PageNFT: {n} checks that the record of the parent exists before it reads _ownerOf(parentId)", 0 <= i < j, (i, j))
    b = flat(one(fn, 'setPrimaryPage'))
    i, j = b.find('if (!_isActive(tokenId)) revert Expired();'), b.find('msg.sender != resolve(tokenId)')
    check("PageNFT: setPrimaryPage checks _isActive before it compares the caller with resolve", 0 <= i < j, (i, j))
    check("PageNFT: resolve answers zero only for a name that is not active, and otherwise _pointee of its holder",
          flat(one(fn, 'resolve')) == 'if (!_isActive(tokenId)) return address(0); return _pointee(tokenId, ownerOf(tokenId));',
          flat(one(fn, 'resolve')))
    check("PageNFT: _burn appears only in _registerTopLevel and _registerSubpage, each followed by a new record and mint, "
          "so a record that exists has a token", count_in(fn, r'\b_burn\s*\(') == {'_registerTopLevel': 1, '_registerSubpage': 1}
          and all(re.search(r'_burn\(tokenId\);.*records\[tokenId\] = PageRecord\(.*_mintTo\(to, tokenId\);', flat(one(fn, n)))
                  for n in ('_registerTopLevel', '_registerSubpage')), count_in(fn, r'\b_burn\s*\('))


def g46():
    # each store has only the writers below, and its name is used nowhere else in the code, not even in assembly
    for v, want, where in (('holderSince', {'_afterTokenTransfer': 1}, '_afterTokenTransfer, once'),
                           ('addressesUpdatedAt', {'_saveAddr': 1, 'setAddrForCoin': 1, 'clearRecords': 1},
                            '_saveAddr, setAddrForCoin and clearRecords, once each'),
                           ('_data', {'setData': 1, 'data': 1}, 'setData and data, once each')):
        w = count_in(fn, r'\b' + v + r'\[')
        check(f"{v}[ occurs only in {where}", w == want, w)
        k = len(re.findall(r'\b' + v + r'\b', nft))
        check(f"{v} is named nowhere else in the code: {len(want) + 1} times with its declaration", k == len(want) + 1, k)
    check("holderSince is set to the time on every mint and every move to another account, right after the self transfer "
          "return of _afterTokenTransfer", flat(one(fn, '_afterTokenTransfer')).startswith(
              'if (from == to) return; if (to != address(0)) holderSince[tokenId] = block.timestamp;'))
    # a write behind a condition keeps the text and the counts above, so each write must be a statement of its
    # writer's own body. Before it, only setAddrForCoin may return, by handing the home chain to _saveAddr
    to_op = 'if (coinType == COIN_TYPE_OP) return _saveAddr(tokenId, address(bytes20(a)));'
    bad = {n: unconditional(one(fn, n), 'addressesUpdatedAt[tokenId] = block.timestamp;', (to_op,))
           for n in ('_saveAddr', 'setAddrForCoin', 'clearRecords')}
    bad = {n: e for n, e in bad.items() if e}
    check("addressesUpdatedAt is set to the time in each of its three writers, by a statement under no if, else or loop, "
          "with no return before it but setAddrForCoin's hand-off of the home chain to _saveAddr", not bad, bad)
    check("_saveAddr is called only in setAddr and setAddrForCoin, so the main address has no other writer of the time",
          count_in(fn, r'\b_saveAddr\(') == {'setAddr': 1, 'setAddrForCoin': 1}, count_in(fn, r'\b_saveAddr\('))
    e = unconditional(one(fn, 'setAddr'), '_saveAddr(tokenId, a);')
    check("setAddr calls _saveAddr by a statement under no if, else or loop, with no return before it, and setAddrForCoin "
          "calls it only to hand off the home chain", e is None and to_op in statements(one(fn, 'setAddrForCoin')), e)
    check("setData checks, then saves the caller and the value in the record of the current version, then emits DataChanged",
          flat(one(fn, 'setData')) == 'if (!_isActive(tokenId)) revert Expired(); if (ownerOf(tokenId) != msg.sender) '
          'revert Unauthorized(); DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key]; d.saver = msg.sender; '
          'd.value = value; emit DataChanged(bytes32(tokenId), key, key, value);', flat(one(fn, 'setData')))
    check("data answers empty for a page that is not active, else the record of the current version while its saver holds "
          "the page", flat(one(fn, 'data')) == 'uint256 tokenId = uint256(node); if (!_isActive(tokenId)) return ""; '
          'DataRecord storage d = _data[tokenId][recordVersion[tokenId]][key]; return d.saver == _ownerOf(tokenId) ? d.value : bytes("");',
          flat(one(fn, 'data')))
    a = [flat(b) for h, b in fn.get('addr', []) if re.match(r'function\s+addr\s*\(\s*bytes32\s+\w+\s*\)', h)]
    check("addr(bytes32) is the coin type 60 answer, zero for a page that is not active, and never the main address",
          a == ['uint256 tokenId = uint256(node); if (!_isActive(tokenId)) return address(0); '
                'return _evmAnswer(tokenId, COIN_TYPE_ETH, ownerOf(tokenId));'], a)


def g47():
    # the letters a card draws: PageCard.sol holds exactly the constants tools/card_glyphs.py makes from
    # tools/card-glyphs.json, the JSON was made from the website's own font files, and the letter numbers the
    # contract uses are the places of those letters in the JSON
    import importlib.util
    spec = importlib.util.spec_from_file_location('card_glyphs', os.path.join(root, 'tools', 'card_glyphs.py'))
    cg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cg)
    data = json.load(open(os.path.join(root, 'tools', 'card-glyphs.json'), encoding='utf-8'))
    bad = cg.sol_differs(data, raw['PageCard'])
    check("PageCard.sol: NAME_PATHS, NAME_INDEX, NAME_KERN, TEXT_PATHS, TEXT_INDEX and TEXT_KERN are the ones "
          "tools/card-glyphs.json gives", not bad, bad)
    for key in ('name', 'text'):
        f = data[key]
        font = os.path.join(root, '..', f['font'])
        have = hashlib.sha256(open(font, 'rb').read()).hexdigest() if os.path.exists(font) else None
        check(f"the {key} letters were made from {f['font']} as it is now", have == f['sha256'], have)
    chars = {k: ''.join(g['char'] for g in data[k]['glyphs']) for k in ('name', 'text')}
    check("the name has a to z, 0 to 9, the hyphen, the dot, the ellipsis and the box, in that order",
          chars['name'] == cg.COMMON + cg.NOTDEF, chars['name'])
    check("the small text adds the space and the capitals of PageCard's CAPITALS, in that order",
          chars['text'] == cg.COMMON + cg.NOTDEF + ' ' + cg.CAPITALS
          and f'bytes private constant CAPITALS = "{cg.CAPITALS}";' in raw['PageCard'], chars['text'])
    want = {'DIGITS': chars['name'].index('0'), 'HYPHEN': chars['name'].index('-'), 'DOT': chars['name'].index('.'),
            'ELLIPSIS_LETTER': chars['name'].index('\u2026'), 'BOX': chars['name'].index(cg.NOTDEF),
            'SPACE': chars['text'].index(' '), 'CAPITALS_FROM': chars['text'].index(cg.CAPITALS[0])}
    for name, n in want.items():
        check(f"PageCard.{name} is {n}, its place in the JSON", f'uint8 private constant {name} = {n};' in raw['PageCard'])
    check("letter numbers 0 to 25 are a to z", chars['name'][:26] == 'abcdefghijklmnopqrstuvwxyz')


# G-48: the size tests that name the widest left pill of a subpage card and the id of the widest code, and where each
# of their numbers is, with its type
SIZE_TESTS = {
    'MetadataSize': 'test/unit/cards/MetadataSize.t.sol',
    'CardBoundFuzz': 'test/unit/cards/CardBoundFuzz.t.sol',
    'WorkedExamples': 'test/unit/core/WorkedExamples.t.sol',
}
SIZE_NUMBERS = {
    'WIDEST_PARENT': ('MetadataSize', r'\bstring constant WIDEST_PARENT = "([^"]*)";', str),
    'WIDEST_CUT': ('MetadataSize', r'\bstring constant WIDEST_CUT = "([^"]*)";', str),
    'SUBPAGE_MAX': ('MetadataSize', r'\buint256 constant SUBPAGE_MAX = (\d+);', int),
    'JSON_MAX': ('MetadataSize', r'\buint256 constant JSON_MAX = (\d+);', int),
    'JSON_MAX full name': ('MetadataSize', r'\buint256 best = _subJson\(63, (\d+), active, SUBPAGE_MAX\);\s*'
                                           r'assertEq\(best, JSON_MAX\);', int),
    'cut card': ('MetadataSize', r'\buint256 cut = _cardOf\(e63, string\.concat\(WIDEST_CUT, _rep\("m", \d+\)\), '
                                 r'active, 0\);\s*assertEq\(cut, (\d+), "the widest card under a parent of 63"\);',
                 int),
    'CardBoundFuzz WIDEST_PARENT': ('CardBoundFuzz', r'\bstring constant WIDEST_PARENT = "([^"]*)";', str),
    'MAX_SUBPAGE_CARD': ('CardBoundFuzz', r'\buint256 constant MAX_SUBPAGE_CARD = (\d+);', int),
    'widest': ('WorkedExamples', r'\bstring memory widest = "([^"]*)";', str),
    'widest card': ('WorkedExamples', r'\bassertEq\(_cardLength\(e63, widest, active, 0\), (\d+),', int),
    'WIDEST_ID': ('MetadataSize', r'\bbytes32 constant WIDEST_ID = (0x[0-9a-fA-F]{64});', lambda v: int(v, 16)),
    'CardBoundFuzz WIDEST_ID': ('CardBoundFuzz', r'\bbytes32 constant WIDEST_ID = (0x[0-9a-fA-F]{64});',
                                lambda v: int(v, 16)),
    'WorkedExamples WIDEST_ID': ('WorkedExamples', r'\bbytes32 constant WIDEST_ID = (0x[0-9a-fA-F]{64});',
                                 lambda v: int(v, 16)),
}


def widest_pills(text, room, most):
    # the search of 'the widest left pill' in test/svgCard.test.ts, over the small text of tools/card-glyphs.json:
    # the dot drawn at pen 0, then runs of up to most label letters, a hyphen never first, grown one letter at a time,
    # keeping for each last letter and width the run that draws the most bytes. It gives the run that draws the most
    # within room units, the most bytes for each number of letters, and the run of fewer than most letters that draws
    # the most with the ellipsis after it, within room. The first is (bytes, letters, width), the last (bytes, letters),
    # and a tie keeps the run found first, in the order of the TypeScript search
    glyphs = text['glyphs']
    chars = [g['char'] for g in glyphs]
    advance = [g['advance'] for g in glyphs]
    kern = {(a, b): v for a, b, v in text['kern']}

    def drawn(l, pen):
        d = glyphs[l]['d']
        return len(f'<path transform="translate({pen})" d="{d}"/>') if d else 0

    dot, ellipsis = chars.index('.'), chars.index('\u2026')
    label = [(ch, chars.index(ch)) for ch in 'abcdefghijklmnopqrstuvwxyz0123456789-']
    layer = {(dot, advance[dot]): (drawn(dot, 0), '')}
    best, cut, per_length = (0, '', 0), (0, ''), {}
    for n in range(1, most + 1):
        grown = {}
        for (last, width), (b, run) in layer.items():
            for ch, l in label:
                if n == 1 and ch == '-':
                    continue
                pen = width + kern.get((last, l), 0)
                if pen + advance[l] > room:
                    continue
                key, more = (l, pen + advance[l]), b + drawn(l, pen)
                if grown.get(key, (-1,))[0] < more:
                    grown[key] = (more, run + ch)
        layer = grown
        for (last, width), (b, run) in layer.items():
            if b > best[0]:
                best = (b, run, width)
            per_length[n] = max(per_length.get(n, 0), b)
            pen = width + kern.get((last, ellipsis), 0)
            with_ellipsis = b + drawn(ellipsis, pen)
            if n < most and pen + advance[ellipsis] <= room and with_ellipsis > cut[0]:
                cut = (with_ellipsis, run)
    return best, cut, per_length


def widest_code(text):
    # the code in the right pill as _codeLetters makes it, 14 hex digits, the ellipsis and 6 more, over the small text
    # of tools/card-glyphs.json, each letter one path at its pen from 0. An exact search over every code, a letter at a
    # time, keeping for each last letter and width the code that draws the most bytes, the digits of each pen included.
    # It gives the code that draws the most and its bytes, the narrowest and the widest code in units, and a function
    # that gives the bytes and the width of any code
    glyphs = text['glyphs']
    chars = [g['char'] for g in glyphs]
    advance = [g['advance'] for g in glyphs]
    kern = {(a, b): v for a, b, v in text['kern']}

    def drawn(l, pen):
        d = glyphs[l]['d']
        return len(f'<path transform="translate({pen})" d="{d}"/>') if d else 0

    def measure(code):
        b = w = 0
        for i, ch in enumerate(code):
            l = chars.index(ch)
            pen = w + (kern.get((chars.index(code[i - 1]), l), 0) if i else 0)
            b, w = b + drawn(l, pen), pen + advance[l]
        return b, w

    digits = [(ch, chars.index(ch)) for ch in '0123456789abcdef']
    layer = {(None, 0): (0, '')}
    for n in range(21):
        grown = {}
        for (last, width), (b, run) in layer.items():
            for ch, l in [('\u2026', chars.index('\u2026'))] if n == 14 else digits:
                pen = width + (kern.get((last, l), 0) if last is not None else 0)
                key, more = (l, pen + advance[l]), b + drawn(l, pen)
                if grown.get(key, (-1,))[0] < more:
                    grown[key] = (more, run + ch)
        layer = grown
    best = max(layer.values(), key=lambda v: v[0])
    widths = [w for _, w in layer]
    return best, min(widths), max(widths), measure


def g48():
    # The left pill of an active subpage holds the dot and the parent, cut like the name over MAX_NAME_BYTES and cut
    # again with the ellipsis while wider than MAX_PILL_TEXT. The size tests take the parent that draws the most there,
    # and the widest pill that ends with the ellipsis, from the search in test/svgCard.test.ts, which the gates do not
    # run, so this gate runs the same search and checks their numbers against it. The right pill holds the code of the
    # id, and the size tests draw their widest cards with WIDEST_ID, so this gate also searches every code
    consts = {}
    for name, c in (('MAX_PILL_TEXT', 'PageCard'), ('MAX_NAME_BYTES', 'PageCard'), ('MAX_LABEL_LENGTH', 'PageNFT')):
        m = re.search(r'\bconstant ' + name + r' = (\d+);', raw[c])
        consts[name] = int(m.group(1)) if m else None
    if not check("PageCard.MAX_PILL_TEXT, PageCard.MAX_NAME_BYTES and PageNFT.MAX_LABEL_LENGTH are read",
                 None not in consts.values(), consts):
        return
    room, most, longest = consts['MAX_PILL_TEXT'], consts['MAX_NAME_BYTES'], consts['MAX_LABEL_LENGTH']
    # the pill the search models: the letters, the cuts, the room and the bytes each letter draws
    pieces = {'_footer': ['_fit(face, bytes.concat(bytes1(DOT), _cut(_letters(bytes(parentLabel), true))))'],
              '_cut': ['if (letters.length <= MAX_NAME_BYTES) return letters;',
                       'for (uint256 i; i < MAX_NAME_BYTES - 1; ++i) out[i] = letters[i];',
                       'out[MAX_NAME_BYTES - 1] = bytes1(ELLIPSIS_LETTER);'],
              '_fit': ['_width(face, out, 0) > MAX_PILL_TEXT', 'for (uint256 i; i < k; ++i) out[i] = letters[i];',
                       'out[k] = bytes1(ELLIPSIS_LETTER);'],
              '_pill': ['uint256 w = (uint256(_width(face, letters, 0)) * 7 + 24) / 25 + 52 + dotWidth;',
                        '_draw(face, letters, letters.length, 0, 0)'],
              '_draw': ['if (i != 0) pen += _kern(face, uint8(letters[i - 1]), l);', 'if (end != start) {',
                        "out, '<path transform=\"translate(', pen.toString(), ')\" d=\"', "
                        "LibString.slice(string(face.paths), start, end), '\"/>'",
                        'pen += int256(advance) + tracking;']}
    bad = {f: [p for p in want if p not in flat(one(fc, f))] for f, want in pieces.items()}
    bad = {f: p for f, p in bad.items() if p}
    check("PageCard draws the left pill of an active subpage as the search counts it: the dot and the parent, cut at "
          "MAX_NAME_BYTES, then with the ellipsis while wider than MAX_PILL_TEXT, each letter one path at its pen "
          "from 0", not bad, bad)
    data = json.load(open(os.path.join(root, 'tools', 'card-glyphs.json'), encoding='utf-8'))
    best, cut, per_length = widest_pills(data['text'], room, most)
    print(f"      the most in {room} units: .{best[1]}, {best[0]} bytes; with the ellipsis: .{cut[1]}\u2026, "
          f"{cut[0]} bytes")
    text = {k: strip_comments(open(os.path.join(root, f), encoding='utf-8').read()) for k, f in SIZE_TESTS.items()}
    got = {}
    for name, (t, pattern, kind) in SIZE_NUMBERS.items():
        m = re.search(pattern, text[t])
        got[name] = kind(m.group(1)) if m else None
    missing = sorted(n for n, v in got.items() if v is None)
    if not check(f"the size tests hold each number this gate reads, in {', '.join(SIZE_TESTS.values())}", not missing,
                 missing):
        return
    parents = {k: got[k] for k in ('WIDEST_PARENT', 'CardBoundFuzz WIDEST_PARENT', 'widest')}
    check(f"WIDEST_PARENT of MetadataSize.t.sol and CardBoundFuzz.t.sol, and widest of WorkedExamples.t.sol, are "
          f"{best[1]}, the parent the search finds", set(parents.values()) == {best[1]}, parents)
    check(f"WIDEST_CUT of MetadataSize.t.sol is {cut[1]}, the widest pill with the ellipsis the search finds",
          got['WIDEST_CUT'] == cut[1], got['WIDEST_CUT'])
    cards = {k: got[k] for k in ('SUBPAGE_MAX', 'MAX_SUBPAGE_CARD', 'widest card')}
    check("the widest subpage card is the same number of bytes in the three tests", len(set(cards.values())) == 1,
          cards)
    # the id reaches the card only through the squares, each drawn once whatever its colour, and the code in the right
    # pill. PageCard draws the code as the search counts it, the pill's x, its width and the x of its text have three
    # digits for every code, so only the paths of the code change with it, and the code of WIDEST_ID draws as many
    # bytes of paths as the most any code draws
    pill_width = lambda units: (units * 7 + 24) // 25 + 52
    code_pieces = {'_footer': ['_pill(face, _codeLetters(id), 910, true, MUTED, "")'],
                   '_codeLetters': ['_letters(bytes(LibString.toHexStringNoPrefix(uint256(id), 32)), true)',
                                    'out = new bytes(21);', 'for (uint256 i; i < 14; ++i) out[i] = hexed[i];',
                                    'out[14] = bytes1(ELLIPSIS_LETTER);',
                                    'for (uint256 i; i < 6; ++i) out[15 + i] = hexed[58 + i];'],
                   '_fingerprint': ['(90 + (i % 8) * 104).toString()', '(90 + (i / 8) * 104).toString()',
                                    'if (nibble % 2 == 0) off = string.concat(off, square);',
                                    'else on = string.concat(on, square);']}
    bad = {f: [p for p in want if p not in flat(one(fc, f))] for f, want in code_pieces.items()}
    bad = {f: p for f, p in bad.items() if p}
    check("PageCard draws each square once whatever its colour, and the code of the id in a pill that ends at x 910, "
          "its first 14 and last 6 hex digits with the ellipsis between, as the search counts it", not bad, bad)
    (code_bytes, code), narrow, wide, measure = widest_code(data['text'])
    print(f"      the code that draws the most: {code}, {code_bytes} bytes of paths; every code is {narrow} to {wide} "
          f"units")
    ids = {k: got[k] for k in ('WIDEST_ID', 'CardBoundFuzz WIDEST_ID', 'WorkedExamples WIDEST_ID')}
    shown = {k: f'{v:064x}'[:14] + '\u2026' + f'{v:064x}'[58:] for k, v in ids.items()}
    check(f"WIDEST_ID of MetadataSize.t.sol, CardBoundFuzz.t.sol and WorkedExamples.t.sol is one id, whose code draws "
          f"{code_bytes} bytes of paths, the most of any code",
          len(set(ids.values())) == 1 and all(measure(c)[0] == code_bytes for c in shown.values()), shown)
    edges = (910 - pill_width(wide), 910 - pill_width(narrow) + 26, pill_width(narrow), pill_width(wide))
    check(f"every code pill is {pill_width(narrow)} to {pill_width(wide)} pixels wide from x {edges[0]} to "
          f"{910 - pill_width(narrow)}, so its x, its width and the x of its text always have three digits",
          all(100 <= v <= 999 for v in edges), edges)
    check(f"the left pill of an active subpage, at most {pill_width(room)} wide from x 90, ends "
          f"{edges[0] - 90 - pill_width(room)} pixels before the widest code pill starts",
          90 + pill_width(room) < edges[0], 90 + pill_width(room))
    # the card of an active subpage of 63 eights depends on its parent only through the letters of the left pill and
    # the digits of the pill's width, which are as many for WIDEST_PARENT as for a pill MAX_PILL_TEXT wide and no
    # fewer than for any other parent. So the rest of the card is the widest subpage card less the bytes of
    # WIDEST_PARENT's pill, and no card under another parent passes that rest plus the bytes of its own pill
    check(f"the left pill of WIDEST_PARENT is {pill_width(best[2])} pixels wide, as many digits as the widest pill, "
          f"{pill_width(room)}", len(str(pill_width(best[2]))) == len(str(pill_width(room))), best[2])
    rest = got['SUBPAGE_MAX'] - best[0]
    check(f"the card under WIDEST_CUT padded to 63, {got['cut card']} bytes in MetadataSize.t.sol, is the same card "
          f"with the other pill: the widest subpage card less {best[0]} bytes and plus {cut[0]}",
          got['cut card'] == rest + cut[0], f"{got['cut card']} != {rest} + {cut[0]}")
    # the JSON of an active subpage of 63 letters, as _subJson counts it, grows by three bytes for each letter of the
    # parent, two for the full name and one for the parent label, and otherwise changes with the parent only through
    # its card in base64
    b64 = lambda n: 4 * ((n + 2) // 3)
    check("MetadataSize.t.sol's _subJson counts two bytes for each character of the full name and one more for each "
          "of the parent's, and JSON_MAX is the JSON of 63 letters under WIDEST_PARENT",
          '+ 2 * fullLength + (fullLength - labelLength - 1) +' in flat(text['MetadataSize'])
          and got['JSON_MAX full name'] == 63 + 1 + len(got['WIDEST_PARENT']), got['JSON_MAX full name'])
    over = {n: 3 * (n - len(best[1])) + b64(rest + b) - b64(got['SUBPAGE_MAX']) for n, b in per_length.items()}
    over = {n: d for n, d in over.items() if d > 0}
    cut_over = 3 * (longest - len(best[1])) + b64(rest + cut[0]) - b64(got['SUBPAGE_MAX'])
    check(f"no parent gives an active subpage of 63 eights with the code of WIDEST_ID more than JSON_MAX, "
          f"{got['JSON_MAX']} bytes: not a parent of any length up to {most} with the most its pill can draw, nor a "
          f"parent whose pill ends with the ellipsis, still {-cut_over} bytes below at {longest} letters",
          not over and cut_over < 0, over or cut_over)


# every compiler warning of the three contracts and the libraries they build from, with forge's default filter off
# (it hides 2424, 2394 and four other kinds). All come from the pinned library trees of G-28, none from src:
# 2424 the `/// @solidity memory-safe-assembly` comment is deprecated, 2394 a notice that transient storage is used,
# 8429 virtual modifiers are deprecated. Solidity 0.8.31 added all three for features 0.9 removes; none changes code
# made by 0.8.38. The libraries stay byte for byte their upstream files, so the warnings stay and are listed here.
KNOWN_WARNINGS = {
    ('2394', 'lib/soledge/src/utils/ReentrancyGuard.sol'): [38],
    ('2424', 'lib/soledge/src/utils/ReentrancyGuard.sol'): 3,
    ('8429', 'lib/soledge/src/utils/ReentrancyGuard.sol'): [31, 48],
    ('2424', 'lib/solady/src/tokens/ERC721.sol'): 23,
    ('2424', 'lib/solady/src/utils/Base64.sol'): 2,
    ('2424', 'lib/solady/src/utils/LibBytes.sol'): 33,
    ('2424', 'lib/solady/src/utils/LibString.sol'): 33,
    ('2424', 'lib/solady/src/utils/SafeTransferLib.sol'): 24,
}


def g49():
    out_dir, cache_dir = 'out-warnings', 'cache-warnings'
    for d in (out_dir, cache_dir):
        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
    cmd = ['forge', 'build', '--force', *[f'src/{c}.sol' for c in CONTRACTS], '--out', out_dir, '--cache-path', cache_dir]
    rc, out = run(cmd, {'FOUNDRY_IGNORED_ERROR_CODES': '[]'})
    os.makedirs(os.path.join(root, 'logs'), exist_ok=True)
    open(os.path.join(root, 'logs', 'gate-G-49-build.txt'), 'w').write(f"# FOUNDRY_IGNORED_ERROR_CODES='[]' {' '.join(cmd)}\n\n{out}")
    for d in (out_dir, cache_dir):
        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
    if not check("the three contracts build alone with every compiler warning shown", rc == 0 and 'Compiler run' in out,
                 out[-800:]):
        return
    text = re.sub(r'\x1b\[[0-9;]*m', '', out)
    heads = re.findall(r'^(Warning|Error|Info|Note)\b', text, re.M)
    placed = re.findall(r'^Warning(?: \((\d+)\))?: [^\n]*\n\s*--> ([^:\n]+):(\d+):\d+:', text, re.M)
    check("every diagnostic is a warning with a file and line (no error, info or note, no warning without a place)",
          len(heads) == len(placed) and set(heads) <= {'Warning'}, f"{len(heads)} headers, {len(placed)} placed")
    ours = sorted({f"{f}:{l} ({c or 'no code'})" for c, f, l in placed if not f.startswith(('lib/solady/', 'lib/soledge/'))})
    check("no compiler warning in src or anywhere outside the pinned solady and soledge trees", not ours, ours[:10])
    have = {}
    for c, f, l in placed:
        have.setdefault((c, f), []).append(int(l))
    bad = []
    for key in sorted(set(have) | set(KNOWN_WARNINGS)):
        want, got = KNOWN_WARNINGS.get(key), sorted(have.get(key, []))
        if want is None or (got != want if isinstance(want, list) else len(got) != want):
            bad.append(f"{key[0]} {key[1]}: expected {want}, found {len(got)} at {got[:8]}")
    total = sum(len(v) if isinstance(v, list) else v for v in KNOWN_WARNINGS.values())
    check(f"the compiler warnings are exactly the {total} known library warnings of KNOWN_WARNINGS", not bad, bad[:10])


GATES = [
    ('G-1', 'No force send', g01), ('G-2', 'Outbound value calls per contract', g02),
    ('G-3', 'No ETH ingress outside the payable entry points', g03), ('G-4', 'No dead vocabulary', g04),
    ('G-5', 'One writer for owed', g05), ('G-6', 'Errors and events declared once, per file', g06),
    ('G-7', 'ROOT consistency', g07), ('G-8', 'Pinned compiler', g08), ('G-9', 'Cache poisoning', g09),
    ('G-10', 'Size', g10), ('G-11', 'Standard JSON', g11), ('G-12', 'Suite green', None), ('G-13', 'Proofs green', None),
    ('G-14', 'Gas snapshot', g14), ('G-15', 'Deleted artefacts', g15), ('G-17', 'One existence predicate', g17),
    ('G-18', 'Public surface', g18), ('G-19', 'Registrar reads the parent through the views', g19),
    ('G-21', 'Storage layout', g21), ('G-22', 'BatchMetadataUpdate is never emitted', g22),
    ('G-23', 'No currency or deposit text on the card', g23), ('G-24', 'Guard set', g24),
    ('G-25', 'One reader of the saved main address', g25), ('G-26', 'Event sites', g26), ('G-27', 'One label validator', g27),
    ('G-28', 'Library trees', g28), ('G-29', 'Mutation run and coverage floor', g29),
    ('G-30', 'One availability expression', g30), ('G-31', 'No function reads its own balance', g31),
    ('G-32', 'One deleted test', g32), ('G-33', 'One mint site', g33), ('G-34', 'One writer for the trial money', g34),
    ('G-35', 'One writer for the profile', g35), ('G-36', 'One writer for display names and their holder', g36),
    ('G-37', 'One delegatecall', g37), ('G-38', 'Status is the metadata status', g38), ('G-39', 'Prices and periods', g39),
    ('G-40', 'Comment hygiene in src', g40), ('G-41', 'Generated harnesses are current', g41),
    ('G-42', 'Campaign sizes', g42), ('G-43', 'Build equals Part 1 of the review record', g43),
    ('G-44', 'No signature check in the code', g44), ('G-45', 'No zero caller', g45),
    ('G-46', 'One writer for holderSince, addressesUpdatedAt and the data records', g46),
    ('G-47', 'The letters on the card are the generated ones', g47),
    ('G-48', 'The widest left pill and code are the ones the size tests name', g48),
    ('G-49', 'Compiler warnings are only the known library ones', g49),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--only', default='')
    ap.add_argument('--skip', default='')
    ap.add_argument('--no-deep', action='store_true')
    ap.add_argument('--record-proofs', nargs='+', metavar='LOGDIR')
    a = ap.parse_args()
    if a.record_proofs:
        return record_proofs(a.record_proofs)
    if a.list:
        for g, title, _ in GATES:
            print(f"{g}  {title}")
        print("G-16  Removed")
        print("G-20  Deployed code is the audited build (gates/deployed.py, on deploy day)")
        return 0
    only = {x.strip() for x in a.only.split(',') if x.strip()}
    skip = {x.strip() for x in a.skip.split(',') if x.strip()}
    env = sorted(k for k in os.environ if k.startswith('FOUNDRY_') or k.startswith('DAPP_'))
    check("no FOUNDRY_ or DAPP_ variable is set", not env, env)
    # a gate counts as run once it returns or records its FAIL, so a run stopped part way, as with Ctrl-C, still prints
    # every gate it did not finish and the summary
    skipped = [g for g, _, _ in GATES]
    try:
        for g, title, f in GATES:
            if (only and g not in only) or g in skip:
                continue
            print(f"== {g} {title}")
            try:
                if g == 'G-12':
                    g12(deep=not a.no_deep)
                elif g == 'G-13':
                    g13()
                else:
                    f()
            except (Exception, SystemExit) as e:
                check(f"{g} ran", False, f"{type(e).__name__}: {e}")
            skipped.remove(g)
    finally:
        print()
        if skipped:
            print(f"NOT RUN: {', '.join(skipped)}")
        print("ALL GATES PASS" if not fails and not skipped else
              f"{len(fails)} FAILED: {fails}" if fails else "ALL GATES RUN PASS, BUT NOT EVERY GATE RAN")
    return 1 if fails or skipped else 0


if __name__ == '__main__':
    sys.exit(main())
