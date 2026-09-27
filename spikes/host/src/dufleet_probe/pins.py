"""Upstream files the installer may put into the game folder, pinned by commit and SHA-256.

ArchHUD is The-Third-Verse/ArchHUD 2.105, modular master build (ADR-0002). The atlas
is The Third Verse's AtlasFile; ArchHUD 2.105 loads autoconf/custom/atlas.lua by default.
"""

ARCHHUD_REPO = "The-Third-Verse/ArchHUD"
ARCHHUD_COMMIT = "6c952221d9c82797b282161d9ae94744d3f8c9cf"
ARCHHUD_RAW_URL = f"https://raw.githubusercontent.com/{ARCHHUD_REPO}/{ARCHHUD_COMMIT}/"  # + repo path
ARCHHUD_ZIP_URL = f"https://github.com/{ARCHHUD_REPO}/archive/{ARCHHUD_COMMIT}.zip"  # for manual download

ATLAS_REPO = "The-Third-Verse/AtlasFile"
ATLAS_COMMIT = "48dd00f910782e9707af923264b387bd2a4357ee"
ATLAS_URL = f"https://raw.githubusercontent.com/{ATLAS_REPO}/{ATLAS_COMMIT}/atlas.lua"

# Path in the ArchHUD repository -> (path under autoconf/custom, SHA-256)
ARCHHUD_FILES = {
    "ArchHUD.conf": ("ArchHUD.conf", "2a58215b386f4b36c16e09efaa18d8c74dd7c82f9520a26a73633a26523fabac"),
    "src/requires/apclass.lua": ("archhud/apclass.lua", "590e77948d0b2a38f4e0f7d4dd1487ba370a05757456e30924243999b3873c27"),
    "src/requires/atlasclass.lua": ("archhud/atlasclass.lua", "3cba3001983ab51848468fbc6234cc6242c8befa9175f01cbb0cb00b699a4a71"),
    "src/requires/axiscommandoverride.lua": ("archhud/axiscommandoverride.lua", "213a0c24d8a88d64b87954331b10969c6fa3de4d0844afd01a9c1da9798f7f36"),
    "src/requires/baseclass.lua": ("archhud/baseclass.lua", "58f54acee98091feba29ea662561685233823dd78e47abfb8e14d17a697f8ec4"),
    "src/requires/controlclass.lua": ("archhud/controlclass.lua", "22c286621f00eb4eb47c7ea0e0296ca1394df8d936e1d637e327cb40288cbd9a"),
    "src/requires/fueltankdefinitions.lua": ("archhud/fueltankdefinitions.lua", "de1416af9d38373b442ef61b372a79fbaaa6c3578d0d17bfe5af6fdc42f65536"),
    "src/requires/globals.lua": ("archhud/globals.lua", "584ce0314c0996fc90907d018a012f4c4ea072c088d58272ee59b8ec1ad94f0e"),
    "src/requires/hudclass.lua": ("archhud/hudclass.lua", "edc804974b955388f65c0768725eb87a50c4f824875713c1eb2a33aac7abbc1b"),
    "src/requires/radarclass.lua": ("archhud/radarclass.lua", "85e97b0b55a7e807683bf19a6345bf423fb40758b1c48c8eb8b3caf72ad13133"),
    "src/requires/shieldclass.lua": ("archhud/shieldclass.lua", "33b9c84c7e4cdb8622220b8dd2a59f7ad4624a93617a80ae11a3acdbe9d0bccd"),
}

ATLAS_FILE = ("atlas.lua", "0044de9e1ee3cd4ecd981939738ea6ec18a8c0d96d8177d65e967c6cc9ae5fda")
