# Overlay.sh

Alpha software that allows you to create a complex overlayfs environment.

This allows for:
- Writing to compressed read-only filesystems such as SquashFS or [Dwarfs](https://github.com/mhx/dwarfs)
- Creating separate wine or proton prefixes for each game without duplicating ANY data
- Chrooting into a user-writable snapshot of your root FS

# How it works

Overlayfs is a linux filesystem that can combine a read-only directory (lowerdir) with a read-write directory (upperdir) in one directory, so that you can appear to be writing to the read-only layer, while actually only writing to the upper.

This is easy to setup on its own, but gets much more tedious if you want more control, such as placing a lowerdir in a different path in the overlay or using multiple separated lowerdirs.

overlay.sh automatically sets up an environment to create an arbitrary number of overlayfs mounts under a virtual temporary file tree, so that you have complete freedom to place as many lowerdirs wherever you want.

If you want to mount a directory `/etc` (`$pathin`) to a location inside the overlay mount as `/fake/etc` (`$pathout`), here's what happens:

- Create permanent directories `tree`, `storage`, and `storage/data` for later use.
- Mount a tmpfs on `tree`.
- Create `tree/overlay` and `tree/{upper,lower}/$pathout`.
    Tree now contains `overlay`, `upper/fake/etc`, and `lower/fake/etc`.
- Mount an overlayfs with a `tree/upper` lowerdir, and a `storage/0` upperdir on `tree/overlay`.
    Tree now additionally contains `overlay/fake/etc`.
- Check the `storage/index` file to see if `$pathin` was mounted before.
- If not, calculate the next integer-named directory under which to place this path's upperdir data. In this case, 1.
- Mount overlayfs using `$pathin` as lowerdir, `storage/[number]` as an upperdir, and `tree/overlay/$pathout` as the mountpoint.
    `tree/overlay/fake/etc` now contains all of your files from `/etc`.
- Bind-mount `$pathin` to `tree/lower/$pathout`.
- Bind-mount `storage/[number]` to `tree/upper/$pathout`.
    `tree/upper` now contains an easy view of your writable directories, and `tree/lower` shows the read-only ones, for convenience.
    These bind mounts do not appear in the first overlay we created, because submounts are invisible to overlayfs.
- Drop into your $SHELL or run a specified command.
- Unmount all mounts. In most cases you only need to exit, and the destruction of the mount namespace will unmount all included filesystems, but not all.
- If processes are busy, wait. if odd bind mount behavior keeps it open, lazily umount.

# Usage

`overlay.sh [-flag]... [directory] [command]`

if no command is specified and a terminal is attached, $SHELL is launched.

if no directory is specified, $PWD is used.

## Flags

- -auto: autocd + automount.

- -autocd: cd into either the only available automounted directory, or `tree/overlay`.

- -automount: take all files and dirs in `storage/data` and -mntadd them.

- -clean: remove unused index directories in `storage` and re-order them on exit.

- -c|-create <path>: create and format path. if path exists and isn't empty, place it inside of a newly-made path.

- -dedupe: on exit, remove redundant files between lower and upper dir. this is a common issue when programs update timestamps while using `userxattr` overlayfs mount option.

- -i|-interactive: ask before removing files with -dedupe.

- -mnt path1 path2: bind path1 to overlay/path2 or bind path1 to mount/path2.

- -mntadd path: overlay path to `overlay/$(basename path)`.

- -mntroot path: overlay path to `overlay/dir/path`.

- -mountplace path: overlay path to `overlay/$(basename path)`, then bind-mount on top of path.

- -mountplacexec path commandstring: run commandstring before doing the same as -mountplace.

- -root: set overlay options for running as root, improves things.

- -wine dirname: update and remount a global wineprefix in $XDG_DATA_HOME/overlay.sh/dirname as overlayfs.
!!THIS WILL BE REMOVED!!

- -proton dirname: same as wine, but for proton.
!!THIS WILL BE REMOVED!!
