"""Build and launch Rust without writing into the watched plugin directory.

Shared by both entry points: each source installation has its own private Cargo
output directory. Python runs in isolated/stdlib mode and writes no bytecode here.
"""
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys


def output_dir(bin_dir):
    source = bin_dir.resolve().parent
    configured = os.environ.get('XDG_CACHE_HOME', '')
    base = Path(configured) if configured.startswith('/') else Path.home() / '.cache'
    base = base.resolve()
    watched = (Path.home() / '.config/omarchy/plugins').resolve()
    # A custom cache inside any installed plugin would recreate the reload loop.
    if base.is_relative_to(source) or base.is_relative_to(watched):
        base = (Path.home() / '.cache').resolve()
    if base.is_relative_to(source) or base.is_relative_to(watched):
        raise OSError('cache directory must be outside the plugin source tree')
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    identity = hashlib.sha256(os.fsencode(str(bin_dir.resolve()))).hexdigest()[:32]
    current = base
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in ['omarchy-task-manager', 'rust', identity]:
            try:
                os.mkdir(name, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                info = os.fstat(child)
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                    raise OSError('unsafe Rust cache ownership')
                os.fchmod(child, 0o700)
            except BaseException:
                os.close(child)
                raise
            os.close(fd)
            fd = child
            current /= name
    finally:
        os.close(fd)
    return current


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('build', 'launch'):
        return 2
    bin_dir = Path(__file__).resolve().parent
    target = output_dir(bin_dir)
    # Help cached executables find reviewed helpers next to their source.
    os.environ['TM_PLUGIN_BIN_DIR'] = str(bin_dir)
    if sys.argv[1] == 'build':
        os.environ['PATH'] = os.environ.get('PATH', '') + ':' + str(Path.home() / '.cargo/bin')
        cargo = shutil.which('cargo')
        if not cargo:
            print('task-manager: cargo not found; install Rust (Omarchy menu: Install > Development > Rust)')
            return 127
        os.execv(cargo, [cargo, 'build', '--release', '--locked', '--offline', '--quiet',
                        '--manifest-path', str(bin_dir / 'task-manager-rs/Cargo.toml'),
                        '--target-dir', str(target)])
    engine = target / 'release/task-manager'
    if not engine.is_file() or not os.access(engine, os.X_OK):
        print('task-manager: engine not built; run ' + str(bin_dir / 'task-manager-build.sh'), file=sys.stderr)
        return 127
    os.execv(engine, [str(engine), *sys.argv[2:]])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except OSError as error:
        print('task-manager: Rust cache unavailable: ' + str(error), file=sys.stderr)
        sys.exit(1)
