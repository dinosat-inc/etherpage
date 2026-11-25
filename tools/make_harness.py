#!/usr/bin/env python3
# Writes the three mint comparison builds and the manual release build in test/differential/harness
# from src/PageNFT.sol. Each mint build differs from the source only in its contract name, the PageCard
# import, the comment and body of _mintTo, and the sentences on who must accept ERC721 tokens in the
# notices of reveal, revealTrial and registerSubpageFor. The manual release build differs only in its
# contract name, the PageCard import, the line of _registerTopLevel that releases a deposit left after
# the auction, the deposit that quote counts after the auction, and the comments of quote, reveal,
# revealTrial, _registerTopLevel and release, so that a deposit stays in its page until release is called.
# With --check it only confirms that the files on disk are current.
# Usage: python3 tools/make_harness.py [--check]
import sys, pathlib

root = pathlib.Path(__file__).resolve().parents[1]
src = (root / "src" / "PageNFT.sol").read_text()
out_dir = root / "test" / "differential" / "harness"

def dev(text):
    return "    /**\n     * @dev " + text + "\n     */\n"


COMMENT = ("    /**\n"
           "     * @dev Skips the ERC721 receiver check when the caller takes the page itself or when the receiver is a key wallet.\n"
           "     * Any other receiver with code must accept ERC721 tokens.\n"
           "     */\n")
HEAD = "    function _mintTo(address to, uint256 tokenId) internal {\n"
BODY = ("        if (to == msg.sender || _isKeyWallet(to)) _mint(to, tokenId);\n"
        "        else _safeMint(to, tokenId);\n")
IMPORT = 'import {PageCard} from "./PageCard.sol";\n'
DECL = "contract PageNFT is ERC721, ReentrancyGuard {\n"

builds = {
    "PageNFTSafe": (dev("Every recipient with code must accept the page, the caller and EIP7702 accounts included."),
                    "        _safeMint(to, tokenId);\n"),
    "PageNFTPlain": (dev("No recipient is ever asked to accept the page."),
                     "        _mint(to, tokenId);\n"),
    "PageNFTKeyOnly": (dev("Key wallets can always move a page, so only contracts must accept it."),
                       "        if (_isKeyWallet(to)) _mint(to, tokenId);\n"
                       "        else _safeMint(to, tokenId);\n"),
}

# the sentences of src that state who must accept ERC721 tokens, in reveal, revealTrial and registerSubpageFor
RULE = (
    "An owner with code must accept ERC721 tokens unless it is the caller or an\n     * EIP7702 account.",
    "An owner with code must accept ERC721 tokens unless it\n     * is the caller or an EIP7702 account.",
    "A receiver with code must accept ERC721 tokens unless it\n     * is the caller or an EIP7702 account.",
)
# what each build says instead, in the same order
rules = {
    "PageNFTSafe": (
        "An owner with code must accept ERC721 tokens, even when it is the caller or an\n     * EIP7702 account.",
        "An owner with code must accept ERC721 tokens,\n     * even when it is the caller or an EIP7702 account.",
        "A receiver with code must accept ERC721 tokens,\n     * even when it is the caller or an EIP7702 account.",
    ),
    "PageNFTPlain": (
        "The owner is never asked to accept ERC721 tokens.",
        "The owner is never asked to accept ERC721 tokens.",
        "The receiver is never asked to\n     * accept ERC721 tokens.",
    ),
    "PageNFTKeyOnly": (
        "An owner with code must accept ERC721 tokens unless it is an EIP7702 account,\n     * even when it is the caller.",
        "An owner with code must accept ERC721 tokens\n     * unless it is an EIP7702 account, even when it is the caller.",
        "A receiver with code must accept ERC721 tokens\n     * unless it is an EIP7702 account, even when it is the caller.",
    ),
}

# the manual release build, as pairs of the text of src and what the build says instead
AUTO = "        if (depositOf[tokenId] != 0 && block.timestamp > _auctionEnd(tokenId)) _releaseDeposit(tokenId);\n"
MANUAL = (
    (AUTO, ""),
    ("        bool inAuction = block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD && block.timestamp <= _auctionEnd(id);\n"
     "        carried = (_recordExists(id) && inAuction) ? depositOf[id] : 0;\n",
     "        carried = (_recordExists(id) && block.timestamp > uint256(records[id].expiresAt) + GRACE_PERIOD) ? depositOf[id] : 0;\n"),
    ("     * @notice What reveal costs now, which is the yearly fee, plus during the premium period the deposit taken over\n"
     "     * from the last registration and the premium. After the premium period the old deposit goes back to its payee\n"
     "     * instead, so the price is the fee alone. All zero for an invalid label. It does not check that the page is free.\n"
     "     * revealTrial costs only a tenth of the fee.\n",
     "     * @notice What reveal costs now, which is the yearly fee plus the deposit taken over from the last registration and\n"
     "     * the premium. All zero for an invalid label. It does not check that the page is free. revealTrial costs only a\n"
     "     * tenth of the fee.\n"),
    ("Refused while a paid page is live,\n"
     "     * in grace or in its premium period, and until 14 days after its last registration ended. After the premium period\n"
     "     * a deposit still in the page first goes back to its payee. An owner with code must accept ERC721 tokens unless it\n"
     "     * is the caller or an EIP7702 account.\n",
     "Refused while the page holds a\n"
     "     * deposit, or until 14 days after its last registration ended. An owner with code must accept ERC721 tokens unless\n"
     "     * it is the caller or an EIP7702 account.\n"),
    ("     * @dev Shared by reveal and revealTrial and told apart by msg.sig, since a constant argument would make the\n"
     "     * compiler copy the whole body. A trial uses a different hash of the same values, so a commitment made for reveal\n"
     "     * can never start a trial. After the premium period a deposit still in the page first goes back to its payee, as\n"
     "     * release would do. During the premium period a paid registration buys out the deposit of the last one and keeps\n"
     "     * it. The last payee gets that deposit and 75 percent of any premium. The other 25 percent goes to the payee of the\n"
     "     * last referrer, or to the dead address when there was no top level referrer, and money still held for an ended\n"
     "     * trial goes back to its payer. The last holder loses the page and stops showing it as its display page, and every\n"
     "     * address, text, website and data record saved before stops counting for good. Trial money stays outside the\n"
     "     * deposit.\n",
     "     * @dev Shared by reveal and revealTrial and told apart by msg.sig, since a constant argument would make the\n"
     "     * compiler copy the whole body. A trial uses a different hash of the same values, so a commitment made for reveal\n"
     "     * can never start a trial. A paid registration buys out the deposit of the last one and keeps it. The last payee\n"
     "     * gets that deposit and 75 percent of any premium. The other 25 percent goes to the payee of the last referrer, or\n"
     "     * to the dead address when there was no top level referrer, and money still held for an ended trial goes back to\n"
     "     * its payer. The last holder loses the page and stops showing it as its display page, and every address, text,\n"
     "     * website and data record saved before stops counting for good. Trial money stays outside the deposit.\n"),
    ("     * @notice After the grace and premium periods of a page, credits its deposit to its payee. A new registration after\n"
     "     * those periods does this by itself. For an unpaid trial that has ended, credits the trial money back to its payer\n"
     "     * instead. Anyone may call it.\n",
     "     * @notice After the grace and premium periods of a page, credits its deposit to its payee. For an unpaid trial that\n"
     "     * has ended, credits the trial money back to its payer instead. Anyone may call it.\n"),
    ("     * @notice Registers the label for owner for one year, paid by the caller, 20 seconds to one day after commit. The\n"
     "     * price is the yearly fee plus any deposit taken over and any premium, as quote shows. After the premium period a\n"
     "     * deposit still in the page first goes back to its payee. The fee goes into the deposit of the page, and anything\n"
     "     * paid above the price is sent back. An owner with code must accept ERC721 tokens unless it is the caller or an\n"
     "     * EIP7702 account.\n",
     "     * @notice Registers the label for owner for one year, paid by the caller, 20 seconds to one day after commit. The\n"
     "     * price is the yearly fee plus any deposit taken over and any premium, as quote shows. The fee goes into the\n"
     "     * deposit of the page, and anything paid above the price is sent back. An owner with code must accept ERC721 tokens\n"
     "     * unless it is the caller or an EIP7702 account.\n"),
)

for needle in (COMMENT + HEAD + BODY, IMPORT, DECL) + RULE + tuple(old for old, _ in MANUAL):
    if src.count(needle) != 1:
        sys.exit("expected exactly one match in src/PageNFT.sol for: " + needle.strip())

check = "--check" in sys.argv
bad = 0
outputs = {}
for name, (comment, body) in builds.items():
    text = (src.replace(IMPORT, 'import {PageCard} from "../../../src/PageCard.sol";\n')
               .replace(DECL, "contract %s is ERC721, ReentrancyGuard {\n" % name)
               .replace(COMMENT + HEAD + BODY, comment + HEAD + body))
    for old, new in zip(RULE, rules[name]):
        text = text.replace(old, new)
    if text.count("function _mintTo") != 1 or BODY in text:
        sys.exit("could not rewrite _mintTo for " + name)
    outputs[name] = text

text = (src.replace(IMPORT, 'import {PageCard} from "../../../src/PageCard.sol";\n')
           .replace(DECL, "contract PageNFTManualRelease is ERC721, ReentrancyGuard {\n"))
for old, new in MANUAL:
    text = text.replace(old, new)
if AUTO in text or text.count("_releaseDeposit(") != 2:
    sys.exit("could not rewrite the manual release build")
outputs["PageNFTManualRelease"] = text

for name, text in outputs.items():
    path = out_dir / (name + ".sol")
    if check:
        if not path.exists() or path.read_text() != text:
            print("stale:", path.relative_to(root))
            bad += 1
        else:
            print("current:", path.relative_to(root))
    else:
        out_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print("wrote", path.relative_to(root))
sys.exit(1 if bad else 0)
