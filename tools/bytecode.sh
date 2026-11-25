#!/bin/zsh
# Builds src with the deploy settings but without the metadata hash, which changes with any comment,
# and prints the size and sha256 of the runtime and creation code of each contract. For two sources
# that differ only in comments, equal values show that the comments left the code unchanged. With a
# folder argument it also writes the hex objects there as <Contract>.deployedBytecode.hex and
# <Contract>.bytecode.hex.
# Usage: tools/bytecode.sh [folder]
cd "${0:A:h}/.."
D=$(mktemp -d "$PWD/nometa-XXXXXX")
trap 'rm -rf "$D"' EXIT
FOUNDRY_CBOR_METADATA=false FOUNDRY_BYTECODE_HASH=none FOUNDRY_OUT=$D/out FOUNDRY_CACHE_PATH=$D/cache \
  forge build --skip test --skip script > $D/build.txt 2>&1 || { cat $D/build.txt; exit 1; }
python3 - "$D/out" "${1:-}" <<'PY'
import hashlib, json, os, sys
out, dst = sys.argv[1], sys.argv[2]
for c in ("PageNFT", "PageCard", "SubpageRegistrar"):
    a = json.load(open(os.path.join(out, c + ".sol", c + ".json")))
    meta = json.loads(a["rawMetadata"]) if "rawMetadata" in a else a.get("metadata", {})
    st = meta.get("settings", {})
    for field in ("deployedBytecode", "bytecode"):
        h = a[field]["object"]
        h = h[2:] if h.startswith("0x") else h
        b = bytes.fromhex(h)
        print(f"{c} {field} {len(b)} bytes sha256 {hashlib.sha256(b).hexdigest()}")
        if dst:
            os.makedirs(dst, exist_ok=True)
            open(os.path.join(dst, f"{c}.{field}.hex"), "w").write(a[field]["object"])
    print(f"{c} settings: optimizer {st.get('optimizer')}, viaIR {st.get('viaIR')}, evm {st.get('evmVersion')}, "
          f"metadata {st.get('metadata')}, compiler {meta.get('compiler', {}).get('version')}")
PY
