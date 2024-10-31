# Overlay.sh

ALPHA software that allows you to run commands inside a fuse-overlayfs environment.

This allows for:
- Writing to compressed read-only filesystems such as SquashFS or [Dwarfs](https://github.com/mhx/dwarfs)
- Creating separate wine or proton prefixes for each game without duplicating ANY data
- Chrooting into a user-writable snapshot of your root FS

# How it works

Overlayfs and its FUSE implementation fuse-overlayfs essentially combine a read-only directory (lowerdir) with a read-write directory (upperdir) so that the lowerdir can be written to.

There are plenty of good explanations of how overlayfs works online, so this is what the script does:

0. create a directory with overlay, mount, upper, work, and data directories inside.
1. if mounting options are given, mount files/directories into the mount dir.
2. mount fuse-overlayfs with mount as lowerdir.
3. run command.
4. umount overlay. if processes are busy, wait. if odd bind mount behavior keeps it open, lazily umount.
5. umount everything from step 1.

# Usage

`overlay.sh [-flag]... [directory] [command]`

if no command is specified and a terminal is attached, $SHELL is launched.

if no directory is specified, $PWD is used.

## Flags

- -auto: autocd + automount.

- -autocd: if there's 1 non-hidden mount dir, cd into it. otherwise cd into the root overlay dir.

- -automount: take all files and dirs in data dir and mount to mount dir.

- -c|-create <path>: create and format path, or move path into path/$(basename path) and format.

- -dedupe: on exit, remove redundant files between mount and upper dir.

- -i|-interactive: ask before removing files.

- -bind|-mnt path1 path2: bind path1 to overlay/path2 or bind path1 to mount/path2.

- -bindadd|-mntadd path: bind path to dir/$(basename path).

- -bindroot|-mntroot path: bind path to dir/path.

- -wine dirname: update and remount a global wineprefix in $XDG_DATA_HOME/overlay.sh/dirname as overlayfs.

- -proton dirname: same as wine, but for proton.

## Example

```
$ ls Noita
    data  mount  overlay  upper  work
$ ls Noita/data
    Noita.dwarfs
$ overlay.sh -auto -dedupe -proton proton Noita proton noita.exe
    mount: tmpfs mounted on /home/user/Noita/mount.
    overlay.sh: running 'proton wineboot'...
...
    mount: /home/user/.local/share/overlay.sh/proton bound on /home/user/Noita/mount/public/proton.
    overlay.sh: dwarf mounted Noita.dwarfs
    overlay.sh: mounted fuse-overlayfs
    mount: /home/user/Noita/overlay/proton bound on /home/user/.local/share/overlay.sh/proton.
... playing game ...
    overlay.sh: exiting...
    overlay.sh: looking for duplicates in upper/Noita
    overlay.sh: looking for duplicates in upper/proton
    upper/proton/pfx/drive_c/windows/syswow64/openvr_api_dxvk.dll
...
    overlay.sh: removed duplicates
    umount: /home/user/.local/share/overlay.sh/proton (fuse-overlayfs) unmounted
    umount: /home/user/Noita/mount/public/proton (/dev/mapper/home) unmounted
    umount: /home/user/Noita/mount (tmpfs) unmounted
    overlay.sh: unmounted overlayfs
```

# Caveats

It's still spotty and incomplete and will make breaking changes to both the CLI and the directory format.

The kernel's overlayfs cannot be used, because submounts inside lowerdir are not visible, making it impossible to change dir structure.
This means we accept the speed losses of the FUSE implementation, so high disk usage applications are not really applicable.

Even kernel overlayfs is a somewhat primitive filesystem, and cannot track file renames or moves without real (not namespaced) root access. Renaming your 500gb mount from game1 to game2 will redundantly copy all 500gb to game2.

Additionally, if you modify 1 byte of a 1gb file, the entire 1gb file will be copied to upperdir before modification. Overlayfs is based on files, not raw data, so is not a perfect diffing tool.

# Design issues

Right now, things like wine usage and dwarfs file mounting are hardcoded into the program despite being highly specific uses, because i don't yet have a model for providing arbitrary environment changing or mounting functions.

# Thanks to

- johncena141 for shipping torrents with this dwarfs+overlayfs strategy

- Dwarfs for being good enough to make writing this script worthwhile
