# overlay.sh

Transparently mounts overlay filesystems with automatic storage placement.

## What is OverlayFS

OverlayFS is a linux filesystem that lets you mount a source directory somewhere else where all
changes made to it — new files, removal of files, changed files and directories, etc — are actually
written to a different directory.

In short, you can take a directory, overlay mount it, mess it up, and the source directory will be
untouched.

This can also be used to write to read-only directories, such as those created by SquashFS, DwarFS,
or even dirs only writable by other users (like root), provided you can write to the storage dir.

## Quickstart

Mount directory "foo" as an overlay at directory "baz":
```sh
overlay.sh -place foo baz
```
Mount "foo" as an overlay on top of itself:
```sh
overlay.sh -replace foo # same as "-place foo foo"
```
Mount "foo" on top of itself, keeping overlay.sh's data inside "qux"
```sh
overlay.sh -storage qux -replace foo
```
Run a command instead of just dropping into $SHELL:
```sh
overlay.sh -place foo baz -- mountpoint baz # the "--" is optional
```

## Usage

```
Usage:
overlay.sh [FLAGS...] [COMMAND]

If COMMAND is not specified and a terminal is attached, launch $SHELL.

Flags:

-p[,OPTS]|-place[,OPTS] SOURCE SINK
    Overlay mount SOURCE dir onto SINK dir, optionally using OPTS to change Indexing mode.

-r[,OPTS]|-replace[,OPTS] SOURCE
    Overlay mount SOURCE dir onto itself, optionally using OPTS to change Indexing mode.
    Same as `-place SOURCE SOURCE`.

-d|-dedupe
    Show and remove all duplicate files and dirs between source and Index.

-i|-interactive
    Ask before removing files with -dedupe.

-o|-overlay DIR
    Bind mount Tree/overlay to DIR.

-t|-tree DIR
    Place Tree at DIR.

-s|-storage DIR
    Place Storage at DIR.

-g|-global DIR
    Place Global at DIR.

-id NAME
    Place Storage at $Global/by-name/NAME.

-k|-key KEY VALUE
    Modify the next specified overlay mount to access storage labelled by KEY with VALUE.
    Can be used multiple times for multiple keys per mount.

-opts OPTS
    OPTS can be i, o, or io, specifying the storage access mode for ALL overlay mounts.

-n|-nobind
    Modify the next specified overlay mount *not* to bind to the sink dir; keep it inside
    Tree/overlay.

-N|-neverbind
    Do not bind sink dir outside of Tree/overlay for ALL overlay mounts.

-su
    Mount all overlays with options useful for root users.
```

## Purpose of overlay.sh

Setting up overlay mounts is tedious, as it looks like this:
```sh
mount -t overlay overlay -o userxattr \
    -o lowerdir=/path/to/source \
    -o upperdir=/path/to/storage/upper \
    -o workdir=/path/to/storage/work \
    /path/to/sink
```
While overlay.sh simplifies the process:
```sh
overlay.sh -place /path/to/source /path/to/sink
```

But overlay.sh is more than a wrapper, it also provides easy ways to set the storage location
per-mount.

## Storage system

The storage locations used for each overlay mount are called Indexes, and the Index used for a
particular mount is, by default, based on the path of the sink dir (the mount dir).

For the commands `overlay.sh -place ./foo ./baz` and `overlay.sh -place ./bar ./baz`, ./foo and
./bar might have different contents, but they use the same Index because they both sink at ./baz.

This is called "output Indexing mode," and can be changed by adding options to the -place flag like
so:
```sh
overlay.sh -place,i ./foo ./baz
```
Where the "i" sets it to use input mode, where Indexing is based on the path of the source dir,
./foo.

You can explicitly use output mode with `-place,o`, or use both constraints with `-place,io`.

### Keys

Internally, "io" options are key-value pairs that look like ["source", "/path/to/source"] and
["sink", "/path/to/sink"] respectively.

Custom keys can be set per-mount by putting `-key key value` before -place. Multiple keys per mount
can be set by using -key more than once:
```sh
overlay.sh -key "myDir" "true" -key "yourDir" "false" -place ./foo ./baz
```
All "io" options are ignored when using -key. Boths key and value allow strings with any characters
besides '\0'.

## Global storage system

The full storage system of overlay.sh consists of "Global" and "Storage" paths, where Global is a
fixed location to automatically place Storages for convenience.

By default Global is set to `$XDG_DATA_HOME/overlay.sh`.

Storage represents one instance or "container" of overlay.sh, containing data needed to run
overlay.sh and all of the individual overlay dir storages, Indexes.

Indexes are directories named as numbers, containing "data" and "work" dirs for OverlayFS and an
"id" file that holds the key-value pairs needed to access the Index.

By default, Storage is set to `$Global/by-cwd/HASH` where HASH is a SHA1 hash created from your
current working directory (cwd) and encoded in base64url.

A Global path will look something like this:
```
    $ tree ~/.local/share/overlay.sh
/home/user/.local/share/overlay.sh
└── by-cwd
    ├── 0LjknW4Ia5uPFD-17RqTF2S4XN8
    │   ├── 0
    │   │   ├── data/
    │   │   ├── id
    │   │   └── work/
    │   ├── name
    │   └── tree/
    └── PEOlF35TGDZlXyT30-6Xe0TmfSo
        ├── 0
        │   ├── data/
        │   ├── id
        │   └── work/
        ├── 1
        │   ├── data/
        │   ├── id
        │   └── work/
        ├── name
        └── tree/
```
Index/name files are exclusive to "by-cwd" paths, containing the cwd they were created from.

Index/tree directories are covered later.

If you want to run multiple overlay.sh instances at once from the same working directory, or use
conflicting Index locations, you will have to manually set Storage.

### Manually set Storage

If you need a quick way to separate instances, the -id flag lets you choose a name for a Storage to
be placed in `$Global/by-name`.

If you need to base an instance off of an actual path, need a different filesystem than the one
offered in Global, etc, you can set Storage directly with -storage.

```sh
overlay.sh -id myStorage -place ./foo ./baz
overlay.sh -storage ./myCoolStorage -place ./foo ./baz
```

You can also change Global with either the `GLOBAL` environment variable or the -global flag, using
the same syntax as -storage.

## The tree

For convenience, debugging, transparency, and internal utility, every Storage has a "tree" directory
that, when overlay.sh is active, mounts a tmpfs with 3 subdirs: Upper, Lower, and Overlay.

Overlay contains the tree of all overlay mounts, ie, sink dirs.

Lower (for OverlayFS's "lowerdir" option) contains the same tree as Overlay, but only holds the
contents of the overlay mounts' respective source (read-only) dirs.

Upper (for OverlayFS's "upperdir" option) only holds the contents of the overlay mounts' respective
Index/data (read-write) dirs.

The Tree allows you to easily browse your mounts and see what's happening under the hood via their
read-only and read-write counterparts.

## Examples

## Strange behavior

Due to complicated kernel permission and namespace and mounting rules, there are many unexpected
edge cases.

### Unprivileged submount viewing

Paths not owned by your user that contain submounts cannot be overlayed on their own.

OverlayFS cannot view submounts in the source dir. For example attempting to do `overlay.sh -replace
/` would render the /tmp directory empty, as it is a separate mount under root.

If you are not the root user, this actually opens a security risk, as root may have placed sensitive
files under /tmp before hiding them with the tmpfs mount. So this is not allowed.   
(This is also the reason bind mounts in this scenario need `-o rbind` instead of `-o bind`; rbind
mounts the entire tree so snooping is impossible.)

Beyond manually copying everything under /, it can be worked around by using fuse-overlayfs to
replace the kernel version, or mergerfs, unionfs, bindfs, or any other FUSE "passthrough" system
between the real source dir and what you feed overlay.sh.

For example:
```sh
bindfs / ~/fakeRoot
overlay.sh -place ~/fakeRoot / -- ls /tmp
```
However this will probably error out anyway due to attempting to run pseudo-filesystems like /dev,
/sys, and /proc through FUSE and pretending that's okay to run your system on. Overlaying root
requires more setup.

Hopefully OverlayFS adds submount support at some point...

### FUSE privileges

Putting Storage on a FUSE mount will fail if it was mounted in a different user namespace.

This means that this:
```sh
sshfs 192.168.0.69: mount/ # mount a remote user's $HOME fs onto mount/
overlay.sh -storage mount/bozoStorage -replace ./browser_history -- Ladybird
```
under usual circumstances (not already running in a privileged namespace), will fail to mount an
overlay with a permission error.

Of course, you *should* have ownership of mount/, but something about it being FUSE, which is a
hacky mess according to kernel devs, and specifically OverlayFS being in a different user namespace
created by overlay.sh errors it out.

To fix this, drop into a new user and mount namespace with `unshare` before mounting FUSE:
```sh
unshare -cm --keep-caps
sshfs 192.168.0.69: mount/
overlay.sh -storage mount/bozoStorage -replace ./browser_history -- Ladybird
```
overlay.sh will detect your capabilities and keep you in the same namespace.

### Socket files

Socket files that are already in use before being placed in an overlay cannot be used in the
overlay. All prior connections must be terminated first.

That means you can't just `overlay.sh -replace /tmp`, because /tmp contains your Xorg socket, which
will prevent you from launching new X programs.

### Filesystem capabilities

When you mount an overlay, it will probably produce warning messages in your kernel log (run `sudo
dmesg -H | tail`) telling you what the filesystem is supposed to support, but doesn't.

These are usually just warnings, but some filesystems are truly not supported. For example Storage
locations *need* Xattr support, which a lot of FUSE fs's lack.

### Root mode

A quirk of OverlayFS and the Xattrs it uses to do its magic is that a lot of useful features are
locked behind real, genuine, root namespace, root user access.

Running in normal user mode means, among other things, that moving directories inside an overlay
that come from the source dir will not actually move them — it will *copy* them.

That means if you want to use OverlayFS to rename a large root-owned directory like /usr to /usr2 in
your personal chroot experiment, it will copy everything inside /usr to achieve it.

Instead, either use bind mounts to rename things, or run overlay.sh with the -su flag as superuser.

## Bugs

- As of util-linux 2.41, while rare, source dir paths cannot contain an odd number of double quotes.
  They have an open issue for it that should be resolved in the next release.

- Recursive mounting is not yet implemented, meaning `-replace ./path` may reproduce ./path
  successfully, but any mounts at ./path/tmpfs will be empty.

- The Tree cannot currently be used if mounting over a path that contains the Tree. It will still
  work outside of the command, but things like -overlay won't, since it is a piece of the Tree.
  Recursive mounts should fix this once added.
