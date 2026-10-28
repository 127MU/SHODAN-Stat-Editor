"""HTTP/Steam proxy packages do not need packet capture drivers or helpers."""
from pathlib import PurePosixPath


def include_proxy_file(name):
    path = PurePosixPath(name.replace('\\', '/'))
    base = path.name.lower()
    return not (path.suffix.lower() == '.sys'
                or (base.startswith('windivert') and path.suffix.lower() in {'.dll', '.lib'})
                or base == 'windows-redirector.exe')
