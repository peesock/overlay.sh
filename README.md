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

## Purpose of overlay.sh

Setting up Overlay mounts is tedious, as it looks like this:
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

By default, the storage path used for a particular source dir is based on the sink dir (mount dir).
Meaning that for commands `overlay.sh -place ./foo ./baz` and `overlay.sh -place ./bar ./baz`, ./foo
and ./bar use the same storage because they both went to ./baz.

This is called output mode, and can be changed by adding options to the -place flag like so:
```sh
overlay.sh -place,i ./foo ./baz
```
Which sets it to use input mode, where storage is based on ./foo being the source.

You can explicitly use output mode with `-place,o`, or use both constraints, with `-place,io`.

### Keys

Internally, "io" options are key-value pairs set to ["source", "/path/to/source"] and
["sink", "/path/to/sink"] respectively.

Custom keys can be set per-mount by putting `-key key value` before -place. Multiple keys per mount
can be set by using -key more than once:
```sh
overlay.sh -key myDir true -key yourDir false -place ./foo ./baz
```
All "io" options are ignored when using -key. Key and value strings allow any character except \0.

## Global storage system

The entire storage system of overlay.sh consists of "Global" and "Storage" paths, where Global sets a
system-wide location to place different Storages for convenience.

Global is set to `$XDG_DATA_HOME/overlay.sh`.

Storage is meant to represent one instance or particular application of overlay.sh, containing
information for operation and all the individual source dir storages, called Indexes.

Indexes are directories named with numbers that contain storage for a particular -place argument and
an "id" file that contains key-value pairs to identify them.

By default, Storage is set to `$Global/by-cwd/$hash` where the hash is SHA1 as base64url created
from your current working directory (cwd).

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
The Index/name files are exclusive to "by-cwd" paths, containing the cwd they were created from.

The Index/tree directories are covered later.

If you want to run multiple overlay.sh instances at once from the same working directory, or use
conflicting Index locations, you will have to set Storage somehow.

### Manually set Storage

The -id flag lets you choose any name for a Storage to be placed in `$Global/by-name`, offering an
easy way to segregate instances without manually making new folders.

If you need to avoid potential collisions, need a different filesystem than the one offered in
$Global, or whatever else, you can set Storage directly with -storage.

```sh
overlay.sh -id myStorage -place ./foo ./baz
overlay.sh -storage ./myCoolStorage -place ./foo ./baz
```

Global can also be changed, with either the `GLOBAL` environment variable or the -global flag, using
the same syntax as -storage.

## The "tree"

For convenience, debugging, transparency, and internal utility, every Storage has a "tree" directory
that, when overlay.sh is active, mounts a tmpfs with 3 subdirs, "upper", "lower", and "overlay".

Overlay contains a tree of all overlay mounted sink dirs.

Lower, representing OverlayFS's 'lowerdir' mount option, contains a tree of every sink dir path, but
only holds the contents of its respective source dirs.

Upper, representing the 'upperdir' mount option, contains an exact copy of the Lower tree, but only
holds the contents of its respective Index/data dirs.

The Tree allows you to freely browse your mounts and compare the exact makeup of them, as separated
by their read-only and read-write counterparts.

## Root mode

A quirk of OverlayFS and the Xattrs it uses to do its magic is that a lot of useful features are
locked behind real, genuine, root namespace, root user access.

Running in normal user mode means, among other things, that moving directories inside an overlay
that come from the source dir will not actually move them — it will *copy* them.

That means if you want to use OverlayFS to rename a large root-owned directory like /usr to /usr2 in
your personal chroot experiment, it will copy everything inside /usr to achieve it.

Instead, either use bind mounts to rename things or run overlay.sh as superuser with the -su flag.

## Usage

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

### Actual bug

As of util-linux 2.41, while rare, source dir paths cannot contain an odd number of double quotes.

They have an open issue for it that should be resolved in the next release.
