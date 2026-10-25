"""Compare compiled stage reflection, not just GLSL text (strict GL drivers)."""
import argparse
import json
import subprocess
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--qsb', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    for name in ('husliquidglass', 'effect2'):
        blocks = []
        for stage in ('vert', 'frag'):
            matches = list(args.build.rglob(f'{name}.{stage}.qsb'))
            assert len(matches) == 1, matches
            output = subprocess.check_output([str(args.qsb), '--dump', str(matches[0])], encoding='utf8')
            reflection, _ = json.JSONDecoder().raw_decode(output.split('Reflection info: ', 1)[1])
            layout = reflection['uniformBlocks']
            # Compiler-generated SPIR-V identifiers vary between stages.
            for block in layout:
                block.pop('structName', None)
            blocks.append(layout)
        assert blocks[0] == blocks[1], f'{name}: stage uniform layouts differ'
        print(f'{name}: compiled vertex/fragment uniform layouts match')

if __name__ == '__main__':
    main()
