"""Validate/repair release font subsetting against all app IconData constants."""
from pathlib import Path
import re

def verify_material_icons(root: Path, release: Path):
    from fontTools.ttLib import TTFont
    from fontTools import subset
    config = (root/'desktop/morrow/windows/flutter/ephemeral/generated_config.cmake').read_text(encoding='utf8')
    match = re.search(r'set\(FLUTTER_ROOT "([^"]+)"', config) or re.search(r'file\(TO_CMAKE_PATH "([^"]+)" FLUTTER_ROOT\)', config)
    if not match:
        raise ValueError('Flutter SDK path not found in generated_config.cmake')
    sdk = Path(match.group(1).replace('\\', '/'))
    source = (sdk/'packages/flutter/lib/src/material/icons.dart').read_text(encoding='utf8')
    definitions = {n: int(v, 16) for n, v in re.findall(r'static const IconData (\w+) = IconData\(\s*0x([0-9a-f]+),\s*fontFamily: \'MaterialIcons\'', source)}
    names = set()
    for path in (root/'desktop/morrow/lib').rglob('*.dart'):
        names.update(re.findall(r'\bIcons\.(\w+)', path.read_text(encoding='utf8')))
    unknown = names-definitions.keys()
    if unknown:
        raise ValueError('Unknown Material icon constants: '+', '.join(sorted(unknown)))
    required = {definitions[n] for n in names}
    target = release/'data/flutter_assets/fonts/MaterialIcons-Regular.otf'
    current = set(TTFont(target).getBestCmap())
    missing = required-current
    if missing:
        font = TTFont(sdk/'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        options = subset.Options(); options.recalc_timestamp = False
        builder = subset.Subsetter(options=options)
        builder.populate(unicodes=current|required); builder.subset(font); font.save(target)
    assert required <= set(TTFont(target).getBestCmap()), 'Release is missing Material icon glyphs'
    return len(required), len(missing)
