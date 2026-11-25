// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {LibString} from "solady/utils/LibString.sol";

/**
 * @title PageCard
 * @notice Draws the SVG cards of Etherpage. It holds no state.
 * This software is provided as is, without warranty. Use at your own risk.
 * @dev Letters are drawn as shapes, so a card needs no font and no text reaches the SVG. The shapes come from
 * Geist (Copyright 2024 The Geist Project Authors) and Parkinsans (Copyright 2024 The Parkinsans Project Authors),
 * under the SIL Open Font License, Version 1.1 (SPDX OFL-1.1).
 */
contract PageCard {
    using LibString for uint256;
    using LibString for int256;

    /**
     * @dev The number of each value is part of the interface.
     */
    enum Status { Active, Grace, Expired, Invalid, Trial }

    /**
     * @dev The letters of one typeface on a grid of whole units: 200 to the em for the name and 100 for the small
     * text. paths holds the outline of each letter, one after another, each an SVG path that starts with an absolute
     * move. index holds three bytes for each letter: the end of its outline in paths, big endian, and its advance.
     * kern holds three bytes for each kerned pair, ordered by pair: the first letter, the second and the signed change
     * to the advance of the first.
     */
    struct Face {
        bytes paths;
        bytes index;
        bytes kern;
    }

    /**
     * @dev The colours of the website: white, its two greys, its ink and second text colour, the grey of a dimmed
     * parent and of a dead card's squares, its blue and the two tints of it, and the red and mustard of a status.
     */
    string private constant PAPER = "#ffffff";
    string private constant PANEL = "#f6f6f8";
    string private constant LINE = "#ebebef";
    string private constant INK = "#19171c";
    string private constant MUTED = "#6a6a70";
    string private constant GREY = "#a3a2aa";
    string private constant BLUE = "#7193f2";
    string private constant BLUE_200 = "#dce4fc";
    string private constant BLUE_100 = "#f1f4fe";
    string private constant RED = "#e5484d";
    string private constant MUSTARD = "#ffc94a";

    /**
     * @dev A longer name is cut and ends with an ellipsis.
     */
    uint256 private constant MAX_NAME_BYTES = 18;

    /**
     * @dev The widest text of the left pill, so that the pill ends at x 447 at most, 12 before the widest code pill,
     * which starts at 459.
     */
    int256 private constant MAX_PILL_TEXT = 1089;

    /**
     * @dev The ellipsis character in UTF 8.
     */
    bytes3 private constant ELLIPSIS = 0xe280a6;

    /**
     * @dev The numbers of the letters, in both faces: 0 to 25 are a to z, 26 to 35 are 0 to 9, then the hyphen, the
     * dot, the ellipsis and a hollow box for any other byte. The small text adds the space and its capitals.
     */
    uint8 private constant DIGITS = 26;
    uint8 private constant HYPHEN = 36;
    uint8 private constant DOT = 37;
    uint8 private constant ELLIPSIS_LETTER = 38;
    uint8 private constant BOX = 39;
    uint8 private constant SPACE = 40;
    uint8 private constant CAPITALS_FROM = 41;

    /**
     * @dev The capitals of the small text, in the order of their numbers from 41.
     */
    bytes private constant CAPITALS = "ADEFGIJMNOSTU";

    /**
     * @dev The name is set 0.03 em tighter than its font, as the website sets its headlines.
     */
    int256 private constant NAME_TRACKING = -6;

    /**
     * @dev The name's scale is at most 0.750, letters of 150 pixels, and smaller when the name would be wider than 820
     * pixels.
     */
    uint256 private constant NAME_SCALE = 750;
    uint256 private constant NAME_WIDTH = 820;

    /**
     * @dev The months from March, as the date math counts its year from March.
     */
    string private constant MONTHS = "MarAprMayJunJulAugSepOctNovDecJanFeb";

    /**
     * @dev Parkinsans at weight 800, for the name.
     */
    bytes private constant NAME_PATHS =
        "M51 1c-29 0-46-26-46-57 0-31 17-58 46-58q13 0 22 7 9 7 12 20v-25h40v112h-20q-10 0-15-5-5-5-5-14v-6q-3 13-12 19-9 7-22 7zm14-34c12 0 20-9 20-23 0-19-18-28-30-20-13 7-13 33 0 40q4 3 10 3z" // a
        "M85 1q-13 0-22-7-9-6-13-19v6q0 9-4 14-5 5-15 5h-20v-148h39v61q4-13 13-20 9-7 22-7c29 0 46 27 46 58 0 31-17 57-46 57zm-14-34q6 0 10-3c13-7 12-33 0-41-12-7-31 2-31 21 0 14 9 23 21 23z" // b
        "M62 1c-34 0-57-22-57-57 0-35 22-58 57-58 19 0 43 6 52 36l-38 12q-2-7-5-10-4-4-10-4c-10 0-16 8-16 24 0 15 6 24 16 24q7 0 11-5 3-5 4-11l39 10c-4 19-22 39-53 39z" // c
        "M51 1c-29 0-46-26-46-57 0-31 17-58 46-58q13 0 22 7 9 7 12 20v-61h40v148h-20q-10 0-15-5-5-5-5-14v-6q-3 13-12 19-9 7-22 7zm14-34c12 0 20-9 20-23 0-19-18-28-30-20-13 7-13 33 0 40q4 3 10 3z" // d
        "M67 1c-31 0-62-19-62-56 0-34 26-59 59-59 25 0 51 15 51 38 0 30-40 36-71 36 3 9 22 16 35 11q6-2 10-5 5-3 8-7l24 20c-12 15-33 22-54 22zm-17-65c13 0 28-2 28-12 0-6-7-9-14-9-14 0-21 12-22 21q1 0 4 0 2 0 4 0z" // e
        "M15 0v-80h-12v-32h12v-5c0-33 31-43 56-41v34c-4-1-17-2-17 10v2h18v32h-18v80z" // f
        "M64 55c-27 0-52-12-58-36l34-11q2 6 8 11 6 4 14 4c16 0 24-12 24-28v-20q-4 13-13 19-9 7-21 7c-30 0-47-26-47-57 0-31 17-58 47-58q12 0 21 7 9 7 13 20v-25h39v107c0 30-17 60-61 60zm1-88c12 0 21-9 21-23 0-19-19-28-31-20-12 7-12 33 0 40q4 3 10 3z" // g
        "M11 0v-148h39v60c5-16 19-26 35-26 26 0 42 19 42 48v66h-39v-60q0-10-5-15-5-6-14-6c-12 0-19 10-19 23v58z" // h
        "M10 0v-112h39v112zm20-123q-11 0-18-6-7-6-7-15 0-10 7-16 7-6 18-6 11 0 17 6 7 6 7 16 0 9-7 15-6 6-17 6z" // i
        "M8 55q-9 0-17-3-9-3-16-10l17-26q5 3 9 3 5 0 9-4 3-3 3-10v-117h39v122c0 29-21 45-44 45zm25-178q-11 0-18-6-7-6-7-15 0-10 7-16 7-6 18-6 11 0 18 6 6 6 6 16 0 9-6 15-7 6-18 6z" // j
        "M11 0v-148h39v78c18-4 33-23 37-42h41c-6 24-26 47-47 56 22 6 43 30 48 56h-42c-5-22-19-37-37-40v40z" // k
        "M11-39v-109h39v107q0 5 3 7 3 2 6 2 3 0 5-1l6 31q-9 3-20 3c-19 0-39-10-39-40z" // l
        "M11 0v-112h39v24c8-27 43-32 59-16q9 9 11 25c5-25 21-35 40-35q21 0 32 13 11 13 11 35v66h-39v-61q0-9-5-15-5-5-14-5-8 0-13 6-5 7-5 16v59h-39v-61q0-9-5-15-5-5-14-5c-11 0-19 10-19 22v59z" // m
        "M11 0v-112h39v24c5-16 19-26 35-26 26 0 42 19 42 48v66h-39v-61q0-9-5-15-5-5-14-5c-12 0-19 10-19 22v59z" // n
        "M63 1c-33 0-58-22-58-57 0-36 25-58 59-58 33 0 58 22 58 58 0 35-25 57-59 57zm0-34c10 0 20-7 20-23 0-32-38-32-38 0 0 16 8 23 18 23z" // o
        "M85 1q-13 0-22-7-9-6-13-19v78h-39v-165h39v25q4-13 13-20 9-7 22-7c29 0 46 27 46 58 0 31-17 57-46 57zm-14-34q5 0 10-3c12-7 13-33 0-40-13-8-31 1-31 20 0 14 9 23 21 23z" // p
        "M85 53v-78q-3 13-12 19-9 7-22 7c-29 0-46-26-46-57 0-31 17-58 46-58q13 0 22 7 9 7 12 20v-25h40v165zm-20-86c12 0 20-9 20-23 0-19-18-28-30-20-13 7-13 33 0 40q4 3 10 3z" // q
        "M11 0v-112h39v112zm35-44l4-40q4-14 13-21 9-8 24-8v41c-19-5-37 6-37 28z" // r
        "M57 1c-25 0-45-11-52-30l36-8q1 5 5 8c7 5 21 2 21-5 0-17-60-3-60-43 0-20 17-37 47-37 26 0 42 13 48 31l-34 9q-1-5-5-8c-6-6-20-4-20 4 0 16 61 3 61 46 0 20-19 33-47 33z" // s
        "M64 1q-21 0-32-10-10-11-10-33v-38h-18v-32h77v32h-20v38c0 8 9 12 17 9l6 30q-4 2-9 3-5 1-11 1zm-51-104v-9q4 0 7-3 3-3 3-8v-16h38v10c0 6-4 15-14 17z" // t
        "M87-19v-93h39v112h-20q-9 0-14-5-5-5-5-14zm-34 20c-28 0-43-20-43-48v-65h39v60q0 10 5 15 6 5 14 5c12 0 19-9 19-22l5 6c-2 34-18 49-39 49z" // u
        "M44-112l21 75 21-75h42l-39 112h-49l-38-112z" // v
        "M0-112h39l17 99h-10l23-99h42l22 99h-9l16-99h37l-29 112h-44l-19-86h8l-20 86h-44z" // w
        "M0-112h44l81 112h-44zm69 69l-24 43h-43l46-72zm-11-29l23-40h43l-46 69z" // x
        "M84-6v-106h39v106c0 29-17 61-61 61-27 0-50-14-58-38l34-11q2 6 8 10 6 5 14 5 12 0 18-8 6-7 6-19zm3-47c0 41-17 52-35 52-26 0-44-20-44-49v-62h39v58q0 9 5 15 5 5 13 5c12 0 19-9 19-22z" // y
        "M95-81l-47 48h48v33h-91v-31l45-49h-44v-32h89z" // z
        "M66 1c-39 0-58-31-58-75 0-44 19-74 58-74 39 0 58 30 58 74 0 44-19 75-58 75zm0-37q7 0 11-5c10-12 11-43 4-59-6-14-25-14-30 0-9 20-7 64 15 64z" // 0
        "M3 0v-31h32v-70c-5 9-19 15-32 16v-36c17 0 32-9 37-25h32v115h30v31z" // 1
        "M6 0v-30c20-13 33-24 44-37 16-17 23-37 14-44-8-8-19 0-22 9q-1 4-2 7l-33-8c5-28 22-45 50-45 33 0 52 18 52 44 0 28-22 53-50 73h50v31z" // 2
        "M63 1c-31 0-52-12-55-41l37-7c1 7 5 16 17 16q4 0 7-2c10-6 10-26-11-26h-13v-31h10q7 0 13-4 6-3 6-10 0-6-4-9-3-3-8-3c-10 0-13 9-14 14l-36-8q3-19 16-29 13-9 35-9c31 0 48 16 48 39q0 14-6 22-6 7-16 11 13 4 19 14 6 9 6 22c0 24-20 41-51 41z" // 3
        "M75 0v-26h-65v-32l62-88h43v86h15v34h-15v26zm-25-60h28v-42z" // 4
        "M73 1c-31 0-50-15-55-39l38-6c2 10 15 17 24 12 9-6 9-26-1-32-8-5-18-1-21 8l-39-9v-81h97v34h-60v31c5-10 15-16 28-16 23 0 40 20 40 49 0 28-20 49-51 49z" // 5
        "M67 1c-40 0-56-30-56-72 0-45 20-77 56-77 28 0 46 15 50 38l-35 6q-1-7-6-10-4-3-11-3c-19 0-20 30-20 44 4-12 17-21 30-21 27 0 43 18 43 47 0 28-20 48-51 48zm-2-32c13 0 19-15 14-25-6-9-23-9-28 0-6 10 1 25 14 25z" // 6
        "M13 0l49-112h-57v-34h96v29l-48 117z" // 7
        "M65 1c-32 0-55-18-55-46q0-12 6-21 5-9 15-14-8-5-13-12-4-7-4-18c0-26 22-38 51-38 27 0 52 11 52 38q0 11-5 18-5 7-13 12 10 5 16 14 5 9 5 21c0 28-22 46-55 46zm0-32q8 0 13-5 4-4 4-11 0-8-4-12-5-4-13-4-8 0-12 4-5 4-5 12 0 7 5 11 4 5 12 5zm0-59q6 0 10-3 3-4 3-11c0-18-26-17-26 0q0 7 4 11 3 3 9 3z" // 8
        "M59-148c40 0 56 31 56 73 0 44-19 76-56 76-28 0-45-14-50-37l35-6q1 5 6 8 4 3 11 3c19 0 20-26 20-41-4 13-16 20-28 20-28 0-45-18-45-48 0-27 20-48 51-48zm2 31c-12 0-19 14-14 25 4 9 16 12 23 7 12-9 7-32-9-32z" // 9
        "M25-86h90v33h-90z" // hyphen
        "M30 1c-21 0-29-23-17-35 8-7 25-8 33 0 12 12 4 35-16 35z" // dot
        "M81 1q-10 0-16-6-6-5-6-14 0-9 6-15 6-6 16-6 11 0 17 6 6 6 6 15 0 9-6 15-6 5-17 5zm52 0q-11 0-17-6-6-5-6-14 0-9 6-15 6-6 17-6 10 0 16 6 6 6 6 15 0 9-6 15-6 5-16 5zm-103 0q-11 0-17-6-6-5-6-14 0-9 6-15 6-6 17-6 10 0 16 6 6 6 6 15 0 9-6 15-6 5-16 5z" // ellipsis
        "M14 0v-140h92v140zm16-16h60v-108h-60z" // any other byte
    ;

    bytes private constant NAME_INDEX =
        hex"00b988016e88020c7802c58803907c03db4b04c988052f8905953b063f4106a08206ec4807a1d508068908877f092b8809cf880a155a0ab96d0b4a5b0bd0890bfb820c4ab10c8f7e0d42860d6f650dfa830e3c690ebf720fa77d0fe18a10758511438011666912878313527a136374139a3b148fa214b478";

    bytes private constant NAME_KERN =
        hex"0024fc010202010302010402010502010e020117fe0124fe0224fc0324fa050102050508050702050802050a02050b020513040514020515020516080517020524060525fc0526fc0609080624fa0715fe0724fc07250207260209090a090cfe090dfe0911fe0924fc0925fc0926fc0a02fe0a03fe0a04fe0a05040a0efe0a13020a16040a17020a24f20a25040a26040b0bfe0b0f020b13fc0b25040b26040c15fe0c24fc0c25020c26020d15fe0d24fc0d25020d26020e02020e03020e04020e05020e0e020e17fe0e24fe0f02020f03020f04020f05020f0e020f17fe0f24fe100914110003110202110302110402110506110e021113041115021116041118021119021124021125f41126f41219021302fe1303fe1304fe130efe1313fe1324f81325021326021505021525f41526f41605081613021616041617041619021624021625f61626f61702fe1703fe1704fe170502170efe1717041724fa1809061919041a1b021a1df81a1efa1a1ff61a22fe1a25f61a26f61b1afa1b1b081b1c061b1efc1b1ff61b20fa1b25061b26061c17041c1b081c1c041c1ff81c23021c25041c26041d1dfa1d1ff41d20fc1e1b041e1ff81e21fe1f1cfc1f1dfc1f1ffc1f20fc1f25fc1f26fc201b04201ff82020fc211b04211efa2120fe2121042125ee2126ee221afe221cfc2222fc2225fc2226fc231ff82325fc2326fc24000a24010c24021224031224041224051424061024070c240814240914240a0c240b12240c14240d14240e12240f0e2410142411142412102413102414122415142416122417122419122505fc250bfc2513f82515f82516fa251afa251b08251c06251efc251ffc2520f82605fc260bfc2613f82615f82616fa261afa261b08261c06261efc261ffc2620f8";

    /**
     * @dev Geist at weight 600, for the small text.
     */
    bytes private constant TEXT_PATHS =
        "M22 1q-8 0-13-4-5-3-5-10 0-7 4-11 5-4 13-6l18-3c0-15-19-15-21-3l-13-1q1-8 8-13 6-5 16-5 11 0 17 6 6 6 6 17v19q0 2 1 3 0 1 2 1h1v9q0 0-1 0c-8 1-15-1-15-12l2 1c-2 7-9 12-20 12zm3-9c9 0 14-6 14-14v-3l-14 3c-11 2-10 14 0 14z" // a
        "M36 1q-6 0-10-2-4-3-7-7v8h-12v-71h13v25c4-8 19-11 28-5 13 9 13 40 0 49q-5 3-12 3zm-3-10q5 0 9-5 3-4 3-13c0-15-12-20-19-15-8 5-8 25 0 31q3 2 7 2z" // b
        "M30 1c-16 0-26-11-26-28 0-17 10-28 26-28 14 0 23 8 25 21h-13c-2-11-16-13-21-6-5 7-5 20 0 26 5 8 19 6 21-6h13c-1 13-11 21-25 21z" // c
        "M26 1q-7 0-12-3c-13-9-13-40 0-49 9-6 24-4 28 5v-25h13v71h-12v-8q-3 4-7 7-4 2-10 2zm4-10c8 0 12-7 12-18 0-11-4-17-12-17q-6 0-9 4-4 5-4 13 0 8 4 13 3 5 9 5z" // d
        "M30 1c-16 0-26-11-26-28 0-17 10-28 26-28 15 0 25 11 25 29v3h-38c1 16 21 18 24 7h13q-2 8-8 13-7 4-16 4zm-13-33h25c-1-17-23-16-25 0z" // e
        "M13 0v-55q0-8 4-12 4-4 12-4h11v10h-9q-3 0-4 2-2 1-2 4v55zm-8-43v-10h34v10z" // f
        "M30 16c-14 0-22-6-25-15l14-1q1 3 3 5 3 2 8 2 6 0 9-3 3-3 3-8v-7c-4 8-18 11-27 5-14-9-14-36 0-45 9-6 23-3 28 6v-8h12v48c0 14-10 21-25 21zm0-29q5 0 9-4 3-4 3-12c0-10-5-16-12-16q-6 0-10 5-3 4-3 11 0 8 4 12 3 4 9 4z" // g
        "M7 0v-71h13v30h-2c4-18 27-16 33-4q2 5 2 11v34h-13v-31q0-7-2-10-2-3-7-3-5 0-8 3-3 4-3 10v31z" // h
        "M7 0v-53h13v53zm0-61v-11h13v11z" // i
        "M0 15v-10h5q3 0 4-1 2-1 2-5v-52h13v53q0 8-4 11-4 4-13 4zm11-76v-11h13v11z" // j
        "M7 0v-71h13v42l22-24h15l-20 22 21 31h-14l-16-24-8 9v15z" // k
        "M20 0q-6 0-10-3-3-3-3-10v-58h13v57q0 2 1 3 1 1 3 1h4v10z" // l
        "M7 0v-53h12v13l-1-1c3-14 19-17 27-10q4 4 5 11h-2c3-18 26-18 32-5q2 4 2 11v34h-13v-31q0-7-2-10c-4-6-17-3-17 10v31h-11v-31q0-6-2-10c-4-6-17-3-17 10v31z" // m
        "M7 0v-53h12v15l-1-1c3-21 27-19 33-6q2 5 2 11v34h-13v-30q0-5-1-8c-2-10-19-7-19 8v30z" // n
        "M30 1c-16 0-26-11-26-28 0-17 10-28 26-28 16 0 26 11 26 28 0 17-10 28-26 28zm0-10q6 0 10-5 3-4 3-13 0-8-3-13-4-4-10-4-6 0-9 4-4 5-4 13 0 9 4 13 3 5 9 5z" // o
        "M7 15v-68h12l1 11-2-1c5-12 21-14 30-8 13 10 14 38 0 48-9 7-26 4-29-7l1-1v26zm25-24q6 0 10-5 3-4 3-13c0-22-25-23-25 0 0 12 5 18 12 18z" // p
        "M55 15h-13v-26l1 1c-3 11-20 14-29 7-13-10-13-38 0-48 9-6 26-4 30 8l-1 1v-11h12zm-25-24c8 0 12-6 12-18 0-23-25-22-25 0q0 9 4 13 3 5 9 5z" // q
        "M7 0v-53h12v14h-1q2-7 5-11 3-3 9-3h5v11h-5c-8 0-12 3-12 11v31z" // r
        "M29 1c-17 0-24-7-25-18h13q1 4 3 6 3 2 9 2c9 0 14-7 5-11-5-1-15-3-20-5-16-7-9-30 14-30 16 0 23 9 23 18l-13 1c0-5-3-9-10-9-11 0-12 10-5 13q2 0 6 1c17 3 22 7 22 16q0 8-6 12-6 4-16 4z" // s
        "M28 0q-8 0-11-4-4-3-4-11v-51h13v49q0 4 1 6 2 1 5 1h8v10zm-23-43v-10h35v10z" // t
        "M25 1q-9 0-13-5-5-6-5-15v-34h13v31c0 19 20 16 20-1v-30h13v53h-12v-15l1 1q-1 7-6 11-4 4-11 4z" // u
        "M22 0l-20-53h14l13 40 14-40h13l-19 53z" // v
        "M18 0l-16-53h13l11 39 10-39h11l11 39 11-39h13l-16 53h-14l-10-36-11 36z" // w
        "M5 0l19-27-19-26h14l12 18 12-18h15l-19 26 19 27h-14l-12-19-13 19z" // x
        "M11 15v-10h7q2 0 3-1 2-1 2-2l2-4h-4l-19-51h13l14 39 13-39h13l-21 59q-2 5-5 7-3 2-9 2z" // y
        "M5 0v-11l31-32h-30v-10h45v10l-31 33h32v10z" // z
        "M34 2c-18 0-29-14-29-37 0-23 11-38 29-38 18 0 30 15 30 38 0 22-12 37-30 37zm0-12q8 0 12-6 4-7 4-19c0-17-5-26-16-26-10 0-16 9-16 26q0 12 4 19 4 6 12 6z" // 0
        "M19 0v-49h-15v-10h6c8 0 12-3 12-12h10v71z" // 1
        "M6 0c0-17 6-27 26-37q5-3 8-5c9-7 6-19-6-19q-7 0-10 3-4 4-5 10l-13-1q1-11 8-17 7-7 19-7c25 0 33 26 18 38-7 5-20 11-25 16q-4 4-5 8h37v11z" // 2
        "M32 2q-13 0-20-6-7-6-7-16l13-1q0 6 4 9c7 5 24 3 24-9q0-5-4-8-4-3-11-3h-6v-10h6q5 0 9-2c6-4 4-17-8-17q-6 0-9 2-3 2-4 6h-13q1-9 8-14 6-6 18-6 8 0 13 3c16 6 16 29-4 33v-2q8 2 13 7 5 4 5 12c0 14-11 22-27 22z" // 3
        "M38 0v-14h-35v-11l33-46h15v46h9v11h-9v14zm-21-25h21v-29z" // 4
        "M33 2c-17 0-26-9-27-21l13-1c2 14 27 13 27-3q0-5-1-8c-5-8-22-7-25 1h-13l4-41h44v11h-32l-3 23-2-2c6-9 21-11 31-5 15 8 14 35-2 43q-6 3-14 3z" // 5
        "M31 2c-17 0-26-12-26-33 0-24 8-42 29-42q10 0 16 5 6 5 8 13l-13 1q-1-3-3-5-3-2-8-2-8 0-12 6-4 7-5 20h-2c2-6 9-12 19-12 14 0 24 9 24 24 0 15-11 25-27 25zm0-11q6 0 10-4 4-4 4-10c0-12-12-17-20-12-11 5-7 26 6 26z" // 6
        "M17 0c0-22 9-43 23-60h-38v-11h52v11c-16 18-24 35-24 60z" // 7
        "M32 2c-17 0-28-8-28-21q0-8 4-13 5-6 13-7l1 2c-13-3-18-17-12-26 8-12 37-12 44 0 5 6 4 15-1 20q-4 4-10 6v-2q8 2 13 7 5 5 5 13c0 13-12 21-29 21zm0-12q7 0 11-3c8-5 4-20-11-20-15 0-19 15-11 20q4 3 11 3zm0-33q6 0 9-2c6-4 3-16-9-16-12 0-14 12-9 16q4 2 9 2z" // 8
        "M28 2q-9 0-15-5-6-4-8-12l12-1c3 8 18 9 23 0q4-6 4-19h2c-7 16-31 15-39 1q-3-6-3-13c0-16 10-26 26-26 18 0 27 13 27 34 0 25-8 41-29 41zm2-35q4 0 7-2c10-5 7-27-7-27-14 0-17 21-7 27q3 2 7 2z" // 9
        "M4-24v-11h34v11z" // hyphen
        "M4 0v-14h15v14z" // dot
        "M4 0v-14h15v14zm21 0v-14h15v14zm22 0v-14h15v14z" // ellipsis
        "M7 0v-70h46v70zm8-8h30v-54h-30z" // any other byte
        "M2 0l26-71h15l26 71h-14l-5-17h-29l-5 17zm23-28h21l-11-30z" // A
        "M8 0v-71h24q17 0 26 9 9 10 9 27 0 17-9 26-9 9-26 9zm13-11h11q11 0 16-6 5-6 5-18 0-13-5-19-5-6-16-6h-11z" // D
        "M8 0v-71h48v11h-35v19h34v11h-34v19h36v11z" // E
        "M8 0v-71h48v11h-42l7-7v33l-7-6h40v11h-40l7-6v35z" // F
        "M37 2c-21 0-33-16-33-37 0-22 13-38 33-38 18 0 28 10 31 25h-14q-1-6-5-10-4-3-12-3c-22 0-25 37-11 48 8 6 22 3 27-5q2-4 2-8h-17v-11h30v37h-9v-16l1 1c-2 10-12 17-23 17z" // G
        "M8 0v-71h13v71z" // I
        "M30 2c-15 0-24-11-25-27h14c0 21 23 20 23 0v-46h13v46c0 16-10 27-25 27z" // J
        "M8 0v-71h18l19 55 20-55h17v71h-13v-49l-18 49h-12l-18-49v49z" // M
        "M8 0v-71h15l31 53v-53h13v71h-16l-30-52v52z" // N
        "M38 2c-21 0-34-15-34-37 0-23 13-38 34-38 21 0 34 15 34 38 0 22-13 37-34 37zm0-12c13 0 21-9 21-25 0-17-8-26-21-26-13 0-20 9-20 26 0 16 7 25 20 25z" // O
        "M35 2c-18 0-29-10-30-25l14-1q0 5 2 8c6 10 27 8 27-3 0-5-3-9-17-12-18-4-24-9-24-21 0-12 9-21 25-21 17 0 27 10 28 24l-13 1c-1-8-6-13-15-13-13 0-17 12-6 17q4 1 10 3c19 4 25 11 25 22 0 12-10 21-26 21z" // S
        "M23 0v-60h-22v-11h56v11h-21v60z" // T
        "M35 2c-17 0-29-11-29-27v-46h14v46q0 7 4 11 4 4 11 4 7 0 11-4 4-4 4-11v-46h13v46c0 16-11 27-28 27z" // U
    ;

    bytes private constant TEXT_INDEX =
        hex"00dc3a016c3e01eb3a02853e03073b03512b04243e047f3c049e1b04e71f051e3f05561e05eb59063e3c06d53c075a3e07e13e081f2908d237091c2b09783c099e3a09e4540a253f0a7a390aa4390b3a440b632b0bea400cb5400ced400d76420e453e0e7c360f7540102e3e103e2a104d16107c41109b3c109b1810d447113b4711643e11943c12384812471d128d3e12c85a12f24b13834c14474314663a14c746";

    bytes private constant TEXT_KERN =
        hex"0013fb0117fa0121f90217fa0221f90305fc0317fb0417fa0421f90502fc0503fc0504fc0505fb0506fc0509fb050efc0510fc0512fc0515fc0516fc0517fc0518fc0526fa0621fc0713fc0717fb0721fc0805fc0817fb0905fc0917fb0a00fb0a01fb0a02fa0a03fa0a04fa0a05fa0a06fa0a07fb0a08fb0a0afb0a0bfc0a0cfc0a0dfc0a0efa0a0ffc0a10fa0a11fc0a12fa0a13fb0a15f90a16f90a17fc0a18f90a24fa0b13fb0c13fc0c17fb0c21fc0d13fc0d17fb0d21fc0e17fa0e21f90f17fa0f21f91021fc1100fc1102fc1103fc1104fc1105fb1106fc1109fa110efc1110fc1112fc1113fc1117f91126fa1217fa1221f91421fc1509fc1517fc1526fa1609fc1617fc1626fa1700fb1701fb1702fa1703fa1704fa1705fa1706fa1707fb1708fb170afb170bfc170cfc170dfc170efa170ffc1710fa1711fc1712fa1713fb1715f91716f91717fc1718f91724fa1809fc1817fc1826fa1917fb1a21fc1b1bfc1f21fb2021fc211efb2126f72321fc2417fb2421fc2515fc2516fc2518fc251bf92521fa261bf92621fa3411fb";

    /**
     * @notice The card of a page as an SVG image.
     * @param parentLabel The label of the parent, or empty for a top level page.
     */
    function render(
        string memory label,
        string memory parentLabel,
        bytes32 id,
        Status status,
        uint256 expiry
    ) external pure returns (string memory) {
        bool dead = status == Status.Expired || status == Status.Invalid;
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">',
            '<rect width="1000" height="1000" fill="', dead ? PANEL : BLUE_100, '"/>',
            _fingerprint(id, dead),
            '<rect x="40" y="560" width="920" height="400" rx="56" fill="', PAPER, '"/>',
            _nameLine(label, parentLabel, dead),
            _footer(parentLabel, status, id, expiry, dead),
            "</svg>"
        );
    }

    /**
     * @dev Eight columns of four rows of squares, one for each nibble of the first 16 bytes of the id: blue for an
     * odd nibble and light blue for an even one, both grey on a dead card.
     */
    function _fingerprint(bytes32 id, bool dead) private pure returns (string memory) {
        string memory on = "";
        string memory off = "";
        for (uint256 i = 0; i < 32; i++) {
            uint8 nibble = i % 2 == 0 ? uint8(id[i / 2]) >> 4 : uint8(id[i / 2]) & 0x0f;
            string memory square = string.concat(
                '<rect x="', (90 + (i % 8) * 104).toString(), '" y="', (90 + (i / 8) * 104).toString(),
                '" width="92" height="92" rx="26"/>'
            );
            if (nibble % 2 == 0) off = string.concat(off, square);
            else on = string.concat(on, square);
        }
        return string.concat(
            '<g fill="', dead ? LINE : BLUE_200, '">', off, '</g><g fill="', dead ? GREY : BLUE, '">', on, "</g>"
        );
    }

    /**
     * @dev The full name, centred, as large as fits up to letters of 150 pixels, with the parent part dimmed. A full
     * name over 18 bytes is cut and has no dimmed part. The baseline moves down as the letters grow, so their middle
     * stays at one height.
     */
    function _nameLine(string memory label, string memory parentLabel, bool dead)
        private
        pure
        returns (string memory)
    {
        bytes memory letters = _letters(bytes(label), false);
        uint256 dimFrom = letters.length;
        if (bytes(parentLabel).length != 0) {
            letters = bytes.concat(letters, bytes1(DOT), _letters(bytes(parentLabel), false));
        }
        if (letters.length > MAX_NAME_BYTES) {
            letters = _cut(letters);
            dimFrom = letters.length;
        }
        Face memory face = Face(NAME_PATHS, NAME_INDEX, NAME_KERN);
        int256 width = _width(face, letters, NAME_TRACKING);
        uint256 scale = NAME_SCALE;
        if (uint256(width) * NAME_SCALE > NAME_WIDTH * 1000) scale = NAME_WIDTH * 1000 / uint256(width);
        return string.concat(
            '<g transform="translate(500 ', (732 + scale * 70 / 1000).toString(), ") scale(0.", _threeDigits(scale),
            ')" fill="', dead ? MUTED : INK, '">',
            _draw(face, letters, dimFrom, -(width / 2), NAME_TRACKING), "</g>"
        );
    }

    /**
     * @dev Two pills. The left one holds the status after a dot, mustard for Grace, blue for Trial and red for Expired
     * and Invalid. An active top level page shows its expiry date there instead, and an active subpage a dot and the
     * label of its parent, cut like the name when over 18 bytes and cut further when too wide for the pill. The right
     * one holds the code of the page.
     */
    function _footer(string memory parentLabel, Status status, bytes32 id, uint256 expiry, bool dead)
        private
        pure
        returns (string memory)
    {
        bytes memory word;
        string memory dot = "";
        if (status == Status.Grace) {
            word = "Grace period";
            dot = MUSTARD;
        } else if (status == Status.Trial) {
            word = "Trial";
            dot = BLUE;
        } else if (status == Status.Expired) {
            word = "Expired";
            dot = RED;
        } else if (status == Status.Invalid) {
            word = "Invalid";
            dot = RED;
        } else if (bytes(parentLabel).length == 0) {
            word = bytes(string.concat("Until ", _formatDate(expiry)));
        }
        Face memory face = Face(TEXT_PATHS, TEXT_INDEX, TEXT_KERN);
        bytes memory left = word.length != 0
            ? _letters(word, true)
            : _fit(face, bytes.concat(bytes1(DOT), _cut(_letters(bytes(parentLabel), true))));
        return string.concat(
            _pill(face, left, 90, false, dead ? MUTED : INK, dot),
            _pill(face, _codeLetters(id), 910, true, MUTED, "")
        );
    }

    /**
     * @dev A grey pill of small text that starts at x, or ends there when fromRight, with a dot before the text when
     * one is given. The text is 28 pixels tall, a scale of 0.280, and its width is rounded up to a whole pixel.
     */
    function _pill(
        Face memory face,
        bytes memory letters,
        uint256 x,
        bool fromRight,
        string memory ink,
        string memory dot
    ) private pure returns (string memory) {
        uint256 dotWidth = bytes(dot).length == 0 ? 0 : 24;
        uint256 w = (uint256(_width(face, letters, 0)) * 7 + 24) / 25 + 52 + dotWidth;
        if (fromRight) x -= w;
        return string.concat(
            '<rect x="', x.toString(), '" y="840" width="', w.toString(), '" height="62" rx="31" fill="', PANEL, '"/>',
            dotWidth == 0
                ? ""
                : string.concat('<circle cx="', (x + 34).toString(), '" cy="871" r="8" fill="', dot, '"/>'),
            '<g transform="translate(', (x + 26 + dotWidth).toString(), ' 881) scale(0.280)" fill="', ink, '">',
            _draw(face, letters, letters.length, 0, 0), "</g>"
        );
    }

    /**
     * @dev The code of the page: the first 14 and the last 6 of the 64 hex digits of its id, with an ellipsis between.
     */
    function _codeLetters(bytes32 id) private pure returns (bytes memory out) {
        bytes memory hexed = _letters(bytes(LibString.toHexStringNoPrefix(uint256(id), 32)), true);
        out = new bytes(21);
        for (uint256 i; i < 14; ++i) out[i] = hexed[i];
        out[14] = bytes1(ELLIPSIS_LETTER);
        for (uint256 i; i < 6; ++i) out[15 + i] = hexed[58 + i];
    }

    /**
     * @dev The letter number of each byte. The name has a to z, 0 to 9, the hyphen and the dot; the small text also
     * the space and its capitals. Any other byte, each byte of a character over one byte included, is the box.
     */
    function _letters(bytes memory s, bool small) private pure returns (bytes memory out) {
        out = new bytes(s.length);
        for (uint256 i; i < s.length; ++i) out[i] = bytes1(_letter(uint8(s[i]), small));
    }

    function _letter(uint8 c, bool small) private pure returns (uint8) {
        if (c >= 0x61 && c <= 0x7a) return c - 0x61;
        if (c >= 0x30 && c <= 0x39) return c - 0x30 + DIGITS;
        if (c == 0x2d) return HYPHEN;
        if (c == 0x2e) return DOT;
        if (small) {
            if (c == 0x20) return SPACE;
            bytes memory capitals = CAPITALS;
            for (uint8 j; j < capitals.length; ++j) {
                if (uint8(capitals[j]) == c) return CAPITALS_FROM + j;
            }
        }
        return BOX;
    }

    /**
     * @dev Letters over 18 keep the first 17 and get the ellipsis.
     */
    function _cut(bytes memory letters) private pure returns (bytes memory) {
        if (letters.length <= MAX_NAME_BYTES) return letters;
        bytes memory out = new bytes(MAX_NAME_BYTES);
        for (uint256 i; i < MAX_NAME_BYTES - 1; ++i) out[i] = letters[i];
        out[MAX_NAME_BYTES - 1] = bytes1(ELLIPSIS_LETTER);
        return out;
    }

    /**
     * @dev The parent in the left pill, cut further with the ellipsis when it is wider than MAX_PILL_TEXT, so the pill
     * never reaches the code pill.
     */
    function _fit(Face memory face, bytes memory letters) private pure returns (bytes memory out) {
        out = letters;
        for (uint256 k = letters.length - 1; _width(face, out, 0) > MAX_PILL_TEXT; --k) {
            out = new bytes(k + 1);
            for (uint256 i; i < k; ++i) out[i] = letters[i];
            out[k] = bytes1(ELLIPSIS_LETTER);
        }
    }

    /**
     * @dev The width of a run of letters in grid units: their advances, the kerning of each pair and the tracking
     * between letters.
     */
    function _width(Face memory face, bytes memory letters, int256 tracking) private pure returns (int256 w) {
        for (uint256 i; i < letters.length; ++i) {
            (,, uint256 advance) = _entry(face, uint8(letters[i]));
            w += int256(advance);
            if (i != 0) w += tracking + _kern(face, uint8(letters[i - 1]), uint8(letters[i]));
        }
    }

    /**
     * @dev The letters as paths, the first at pen and each moved by the advances, tracking and kerning before it. The
     * letters from dimFrom on are in a group of the dimmed colour.
     */
    function _draw(Face memory face, bytes memory letters, uint256 dimFrom, int256 pen, int256 tracking)
        private
        pure
        returns (string memory out)
    {
        out = "";
        for (uint256 i; i < letters.length; ++i) {
            uint8 l = uint8(letters[i]);
            if (i == dimFrom) out = string.concat(out, '<g fill="', GREY, '">');
            if (i != 0) pen += _kern(face, uint8(letters[i - 1]), l);
            (uint256 start, uint256 end, uint256 advance) = _entry(face, l);
            if (end != start) {
                out = string.concat(
                    out, '<path transform="translate(', pen.toString(), ')" d="',
                    LibString.slice(string(face.paths), start, end), '"/>'
                );
            }
            pen += int256(advance) + tracking;
        }
        if (dimFrom < letters.length) out = string.concat(out, "</g>");
    }

    /**
     * @dev Where the outline of a letter starts and ends in the paths of its face, and its advance.
     */
    function _entry(Face memory face, uint256 l) private pure returns (uint256 start, uint256 end, uint256 advance) {
        uint256 o = l * 3;
        if (l != 0) start = uint256(uint8(face.index[o - 3])) << 8 | uint8(face.index[o - 2]);
        end = uint256(uint8(face.index[o])) << 8 | uint8(face.index[o + 1]);
        advance = uint8(face.index[o + 2]);
    }

    /**
     * @dev The kerning of a pair, found by a binary search of the face's ordered pairs, or zero.
     */
    function _kern(Face memory face, uint8 a, uint8 b) private pure returns (int256) {
        uint256 key = uint256(a) << 8 | b;
        uint256 lo = 0;
        uint256 hi = face.kern.length / 3;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 o = mid * 3;
            uint256 pair = uint256(uint8(face.kern[o])) << 8 | uint8(face.kern[o + 1]);
            if (pair == key) return int8(uint8(face.kern[o + 2]));
            if (pair < key) lo = mid + 1;
            else hi = mid;
        }
        return 0;
    }

    /**
     * @dev A number below 1000 as three digits.
     */
    function _threeDigits(uint256 n) private pure returns (string memory) {
        bytes memory b = new bytes(3);
        b[0] = bytes1(uint8(48 + n / 100));
        b[1] = bytes1(uint8(48 + (n / 10) % 10));
        b[2] = bytes1(uint8(48 + n % 10));
        return string(b);
    }

    /**
     * @dev A Unix time as a UTC date such as 5 Mar 2027, with the civil from days method of Howard Hinnant. The day of
     * the era runs from 0 to 146096, the year of the era from 0 to 399, the day of the year from 0 to 365, the month
     * index from 0 to 11 and the day from 1 to 31. The cap on the month index never fires and only keeps the table
     * offset at most 33.
     */
    function _formatDate(uint256 timestamp) private pure returns (string memory) {
        uint256 y;
        uint256 d;
        uint256 mp;
        unchecked {
            uint256 z = timestamp / 86400 + 719468;
            uint256 era = z / 146097;
            uint256 doe = z - era * 146097;
            uint256 yoe =
                (doe + doe / 36524 - doe / 1460 - (doe == 146096 ? 1 : 0)) / 365;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            mp = (5 * doy + 2) / 153;
            d = doy - (153 * mp + 2) / 5 + 1;
            y = yoe + era * 400 + (mp >= 10 ? 1 : 0);
        }
        if (mp > 11) mp = 11;
        uint256 o = 3 * mp;
        return string.concat(d.toString(), " ", LibString.slice(MONTHS, o, o + 3), " ", y.toString());
    }

    /**
     * @notice The address in lowercase as 0x and its first 12 hex digits, an ellipsis and its last 6 hex digits.
     * @dev The hex string is 42 bytes, and the 23 bytes out are its first 14, the 3 byte ellipsis and its last 6.
     */
    function shortAddress(address a) public pure returns (string memory) {
        bytes memory hexed = bytes(LibString.toHexString(uint256(uint160(a)), 20));
        bytes memory out = new bytes(23);
        for (uint256 i; i < 14; ++i) out[i] = hexed[i];
        out[14] = ELLIPSIS[0];
        out[15] = ELLIPSIS[1];
        out[16] = ELLIPSIS[2];
        for (uint256 i; i < 6; ++i) out[17 + i] = hexed[36 + i];
        return string(out);
    }
}
