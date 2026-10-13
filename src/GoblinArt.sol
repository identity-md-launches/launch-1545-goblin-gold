// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title GoblinArt
/// @notice On-chain 32x32 pixel-art goblin traders. Every function is internal so the library is inlined into
///         GoblinNFT and the deployed bytecode carries no link placeholder.
library GoblinArt {
    using Strings for uint256;

    struct Traits {
        uint8 skin;
        uint8 ears;
        uint8 face;
        uint8 outfit;
        uint8 headwear;
        uint8 bag;
        uint8 peek;
        uint8 held;
        uint8 background;
        uint8 rarity; // 0 common, 1 uncommon, 2 rare, 3 epic, 4 legendary
    }

    /// @dev Maps one byte of the hash onto [0, n) without the modulo operator: (b * n) >> 8.
    function _pick(bytes32 h, uint256 slot, uint256 n) private pure returns (uint8) {
        uint256 b = uint256(uint8(h[slot]));
        return uint8((b * n) >> 8);
    }

    /// @notice Derives the traits of `tokenId` from the collection seed revealed after sellout.
    function traitsOf(bytes32 seed, uint256 tokenId) internal pure returns (Traits memory t) {
        bytes32 h = keccak256(abi.encode(seed, tokenId));
        t.skin = _pick(h, 0, 6);
        t.ears = _pick(h, 1, 4);
        t.face = _pick(h, 2, 5);
        t.outfit = _pick(h, 3, 6);
        t.headwear = _pick(h, 4, 6);
        t.bag = _pick(h, 5, 5);
        t.peek = _pick(h, 6, 5);
        t.held = _pick(h, 7, 5);
        t.background = _pick(h, 8, 6);
        // Rarity from a 16-bit draw: common 60%, uncommon 25%, rare 10%, epic 4%, legendary 1%.
        uint256 r = (uint256(uint16(bytes2(bytes32(h << 72)))) * 10_000) >> 16;
        if (r < 6000) t.rarity = 0;
        else if (r < 8500) t.rarity = 1;
        else if (r < 9500) t.rarity = 2;
        else if (r < 9900) t.rarity = 3;
        else t.rarity = 4;
    }

    function _rect(uint256 x, uint256 y, uint256 w, uint256 h, string memory fill) private pure returns (bytes memory) {
        return abi.encodePacked(
            '<rect x="',
            x.toString(),
            '" y="',
            y.toString(),
            '" width="',
            w.toString(),
            '" height="',
            h.toString(),
            '" fill="',
            fill,
            '"/>'
        );
    }

    function _skin(uint8 i) private pure returns (string memory) {
        string[6] memory c = ["#6abe30", "#4b8b3b", "#99c24d", "#8f9779", "#5fa38c", "#b5a642"];
        return c[i];
    }

    function _bg(uint8 i) private pure returns (string memory) {
        string[6] memory c = ["#1d2b53", "#2e1f3d", "#3b2f2f", "#16302b", "#40351f", "#26323c"];
        return c[i];
    }

    function _outfitColor(uint8 i) private pure returns (string memory) {
        string[6] memory c = ["#8b5a2b", "#5b3a8c", "#a33b3b", "#2f6f8f", "#3f3f3f", "#c9a227"];
        return c[i];
    }

    function _bagColor(uint8 i) private pure returns (string memory) {
        string[5] memory c = ["#a0785a", "#6b4226", "#c0c0c8", "#7a2e8e", "#e5b80b"];
        return c[i];
    }

    function _name(uint256 kind, uint8 i) private pure returns (string memory) {
        if (kind == 0) return ["Swamp", "Moss", "Lime", "Ash", "Jade", "Brass"][i];
        if (kind == 1) return ["Pointy", "Droopy", "Bat", "Notched"][i];
        if (kind == 2) return ["Grin", "Scheming", "Gold Tooth", "Squint", "Shocked"][i];
        if (kind == 3) {
            return ["Leather Vest", "Merchant Robe", "Red Coat", "Sailor Jacket", "Rags", "Gilded Tunic"][i];
        }
        if (kind == 4) return ["None", "Hood", "Top Hat", "Crown", "Bandana", "Helmet"][i];
        if (kind == 5) return ["Burlap", "Leather", "Silk", "Velvet", "Gold"][i];
        if (kind == 6) return ["Coins", "Gems", "Tokens", "Scroll", "ETH Diamond"][i];
        if (kind == 7) return ["Nothing", "Abacus", "Dagger", "Lantern", "Ledger"][i];
        if (kind == 8) return ["Night", "Dusk", "Cave", "Forest", "Desert", "Fog"][i];
        return ["Common", "Uncommon", "Rare", "Epic", "Legendary"][i];
    }

    function _head(Traits memory t) private pure returns (bytes memory out) {
        string memory skin = _skin(t.skin);
        // head
        out = abi.encodePacked(_rect(10, 7, 10, 9, skin), _rect(9, 9, 1, 5, skin), _rect(20, 9, 1, 5, skin));
        // ears
        if (t.ears == 0) out = abi.encodePacked(out, _rect(6, 8, 3, 2, skin), _rect(21, 8, 3, 2, skin));
        else if (t.ears == 1) out = abi.encodePacked(out, _rect(6, 11, 3, 2, skin), _rect(21, 11, 3, 2, skin));
        else if (t.ears == 2) out = abi.encodePacked(out, _rect(5, 6, 4, 4, skin), _rect(21, 6, 4, 4, skin));
        else out = abi.encodePacked(out, _rect(7, 9, 2, 2, skin), _rect(21, 9, 2, 1, skin));
        // eyes and mouth
        string memory eye = t.face == 4 ? "#ffffff" : "#ffeb3b";
        uint256 eyeH = t.face == 3 ? 1 : 2;
        out = abi.encodePacked(out, _rect(12, 10, 2, eyeH, eye), _rect(17, 10, 2, eyeH, eye));
        out = abi.encodePacked(out, _rect(13, 10, 1, 1, "#111111"), _rect(18, 10, 1, 1, "#111111"));
        if (t.face == 1) out = abi.encodePacked(out, _rect(13, 14, 5, 1, "#3a1f1f"));
        else if (t.face == 4) out = abi.encodePacked(out, _rect(14, 13, 2, 2, "#3a1f1f"));
        else out = abi.encodePacked(out, _rect(12, 13, 7, 1, "#3a1f1f"), _rect(13, 14, 5, 1, "#3a1f1f"));
        if (t.face == 2) {
            out = abi.encodePacked(out, _rect(14, 13, 1, 1, "#ffd700"));
        } else if (t.face != 4) {
            out = abi.encodePacked(out, _rect(13, 13, 1, 1, "#ffffff"), _rect(17, 13, 1, 1, "#ffffff"));
        }
    }

    function _hat(uint8 h) private pure returns (bytes memory) {
        if (h == 1) return abi.encodePacked(_rect(9, 5, 12, 3, "#4a3b2a"), _rect(8, 7, 2, 6, "#4a3b2a"));
        if (h == 2) return abi.encodePacked(_rect(11, 1, 8, 5, "#151515"), _rect(9, 6, 12, 1, "#151515"));
        if (h == 3) {
            return abi.encodePacked(
                _rect(11, 4, 8, 3, "#ffd700"),
                _rect(11, 3, 1, 1, "#ffd700"),
                _rect(14, 3, 2, 1, "#ffd700"),
                _rect(18, 3, 1, 1, "#ffd700")
            );
        }
        if (h == 4) return abi.encodePacked(_rect(10, 6, 10, 2, "#b22222"), _rect(20, 7, 2, 1, "#b22222"));
        if (h == 5) return abi.encodePacked(_rect(10, 4, 10, 3, "#7d7d7d"), _rect(14, 3, 2, 1, "#9e9e9e"));
        return "";
    }

    function _body(Traits memory t) private pure returns (bytes memory) {
        string memory skin = _skin(t.skin);
        string memory cloth = _outfitColor(t.outfit);
        return abi.encodePacked(
            _rect(11, 16, 9, 9, cloth),
            _rect(9, 17, 2, 6, skin),
            _rect(20, 17, 2, 6, skin),
            _rect(12, 25, 3, 4, "#2b2b2b"),
            _rect(16, 25, 3, 4, "#2b2b2b"),
            _rect(11, 21, 9, 1, "#3a2a1a")
        );
    }

    function _bagArt(Traits memory t) private pure returns (bytes memory out) {
        string memory c = _bagColor(t.bag);
        out = abi.encodePacked(_rect(22, 18, 7, 8, c), _rect(23, 17, 5, 1, c), _rect(24, 16, 3, 1, "#3a2a1a"));
        if (t.peek == 0) {
            out = abi.encodePacked(out, _rect(23, 15, 2, 2, "#ffd700"), _rect(26, 14, 2, 2, "#ffd700"));
        } else if (t.peek == 1) {
            out = abi.encodePacked(out, _rect(23, 15, 2, 2, "#e0115f"), _rect(26, 14, 2, 2, "#50c878"));
        } else if (t.peek == 2) {
            out = abi.encodePacked(out, _rect(23, 14, 2, 3, "#2775ca"), _rect(26, 15, 2, 2, "#f7931a"));
        } else if (t.peek == 3) {
            out = abi.encodePacked(out, _rect(24, 13, 3, 4, "#f5e6c8"));
        } else {
            out = abi.encodePacked(
                out, _rect(25, 12, 1, 1, "#8c8cff"), _rect(24, 13, 3, 2, "#627eea"), _rect(25, 15, 1, 1, "#3c3c99")
            );
        }
    }

    function _heldArt(uint8 h) private pure returns (bytes memory) {
        if (h == 1) {
            return abi.encodePacked(
                _rect(4, 19, 5, 4, "#8b5a2b"), _rect(5, 20, 1, 1, "#ffffff"), _rect(7, 21, 1, 1, "#ffffff")
            );
        }
        if (h == 2) return abi.encodePacked(_rect(7, 14, 1, 6, "#c0c0c0"), _rect(6, 20, 3, 1, "#5b3a1a"));
        if (h == 3) return abi.encodePacked(_rect(5, 19, 3, 4, "#ffcc33"), _rect(6, 18, 1, 1, "#555555"));
        if (h == 4) return abi.encodePacked(_rect(4, 18, 5, 5, "#2f4f2f"), _rect(5, 19, 3, 1, "#f5e6c8"));
        return "";
    }

    /// @notice Placeholder image shown before the collection seed is revealed.
    function hiddenSvg() internal pure returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" shape-rendering="crispEdges">',
            _rect(0, 0, 32, 32, "#1d2b53"),
            _rect(10, 7, 10, 9, "#000000"),
            _rect(11, 16, 9, 13, "#000000"),
            _rect(22, 17, 7, 9, "#000000"),
            _rect(14, 10, 4, 1, "#ffeb3b"),
            "</svg>"
        );
    }

    function svg(Traits memory t) internal pure returns (bytes memory) {
        bytes memory glow = "";
        if (t.rarity >= 3) {
            string memory gc = t.rarity == 4 ? "#ffd700" : "#b388ff";
            glow = abi.encodePacked(
                '<defs><filter id="g"><feGaussianBlur stdDeviation="0.8"/></filter></defs>',
                '<rect x="7" y="4" width="22" height="25" fill="',
                gc,
                '" opacity="0.45" filter="url(#g)"/>'
            );
        }
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" shape-rendering="crispEdges">',
            _rect(0, 0, 32, 32, _bg(t.background)),
            _rect(0, 29, 32, 3, "#2a1d12"),
            glow,
            _body(t),
            _head(t),
            _hat(t.headwear),
            _bagArt(t),
            _heldArt(t.held),
            "</svg>"
        );
    }

    function _attr(string memory k, string memory v, bool last) private pure returns (bytes memory) {
        return abi.encodePacked('{"trait_type":"', k, '","value":"', v, last ? '"}' : '"},');
    }

    function attributes(Traits memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "[",
            abi.encodePacked(
                _attr("Skin", _name(0, t.skin), false),
                _attr("Ears", _name(1, t.ears), false),
                _attr("Face", _name(2, t.face), false),
                _attr("Outfit", _name(3, t.outfit), false),
                _attr("Headwear", _name(4, t.headwear), false)
            ),
            abi.encodePacked(
                _attr("Bag", _name(5, t.bag), false),
                _attr("Peeking Out", _name(6, t.peek), false),
                _attr("Held Item", _name(7, t.held), false),
                _attr("Background", _name(8, t.background), false),
                _attr("Rarity", _name(9, t.rarity), true)
            ),
            "]"
        );
    }
}
