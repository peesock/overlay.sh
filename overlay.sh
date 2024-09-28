#!/bin/sh
# set -x

if [ "$1" = 1 ]; then
	shift
else
	exec unshare -cm --keep-caps -- "$0" 1 "$@"
fi

programName=${0##*/}

log(){
	printf '%s\n' "$programName: $*"
}

escapist(){ # to store arrays as escaped single quoted arguments
	if [ $# -eq 0 ]; then cat; else printf "%s\0" "$@"; fi |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

bind(){
	s=0
	while [ $# -gt 0 ]; do
		mkdir -p "$mountdir/$2"
		mount --rbind "$1" "$mountdir/$2" &&
			mount --make-rslave "$mountdir/$2" || s=1
		shift 2
	done
	return $s
}

bindadd(){
	for arg; do
		bind "$arg" "${arg##*/}"
	done
	return $s
}

bindroot(){
	for arg; do
		bind "$arg" "$arg"
	done
	return $s
}

foldout(){ # /path/to/dir -> /path/to/dir/dir
	for arg; do
		tmp=$(mktemp -up "${arg%/*}")
		mv -T "$arg" "$tmp" || return 1
		mkdir "$arg"
		mv -T "$tmp" "$arg/${arg##*/}"
		log moved "'$arg'" to "'$arg/${arg##*/}'"
	done
}

creator(){
	if [ -e "$1" ]; then
		log "'$1'" exists, moving into folder of same name
		foldout "$1"
	else
		mkdir "$1"
	fi
	cd "$1" || exit
	mkdir upper work
	log created template
}

mounter(){
	cd "$path" || exit
	for d in upper work; do [ -d "$d" ] || exit; done
	# mount -t overlay overlay -o lowerdir="$mountdir",upperdir=upper,workdir=work,userxattr "$overlaydir" && log mounted overlayfs || exit
	fuse-overlayfs -o lowerdir="$mountdir",upperdir=upper,workdir=work "$overlaydir" && log mounted fuse-overlayfs || exit
	ln -sfnT "$overlaydir" "$path"/overlay
	ln -sfnT "$mountdir" "$path"/mount
}

umounter(){
	cd "$path" || exit
	until umount "$overlaydir" && log unmounted overlayfs; do
		mountpoint -q "$overlaydir" || break
		fuser -v "$overlaydir"
		sleep 1
	done
	umount -l "$mountdir"
}

runner(){
	mounter
	cd "$path/overlay" || exit
	if [ $# -ge 1 ]; then
		"$@"
	elif [ -t 1 ]; then
		log entering shell...
		"$SHELL"
		log returning...
	else
		log provide a command.
		exit 1
	fi
	umounter
}

commadd(){
	commstring=$commstring"$(escapist "$@");"
}

while true; do
	case $1 in
		-automount) # get all paths in root and mount to lower
			automount=true
			;;
		-c*)
			creator "$(realpath -m "$2")"
			exit
			;;
		-dedupe) # compare lowerdirs with corresponding overlay dirs and remove dupes
			dedupe=true
			;;
		-dwarfs) # find *.dwarfs files and mount to lower
			dwarfs=true
			;;
		-bind)
			commadd bind "$2" "$3"
			shift 2
			;;
		-bindadd)
			commadd bindadd "$(realpath -e "$2")" || exit
			shift
			;;
		-bindroot)
			commadd bindroot "$(realpath -e "$2")" || exit
			shift
			;;
		-wine) # update wine and mount to lower
			wine=true
			;;
		--)
			shift
			break;;
		*)
			break;;
	esac
	shift
done

if [ $# -ge 1 ]; then
	path=$(realpath -e "$1")
	[ -z "$path" ] && exit 1
	shift
else
	path=$(realpath .)
fi
overlaydir="$XDG_RUNTIME_DIR/$programName/$(printf %s "$path" | sha1sum | cut -d' ' -f1)"
mountdir=$overlaydir/mount
overlaydir=$overlaydir/overlay
mkdir -p "$overlaydir" "$mountdir"
mount -t tmpfs tmpfs "$mountdir"
mount --make-rslave "$mountdir"

eval "$commstring"

[ "$automount" ] && {
	for p in "$path"/*; do
		case $p in */upper|*/work|*/mount|*/overlay) continue;; esac
		bindadd "$p"
	done
}

[ "$dwarfs" ] && (
	cd "$path" || exit
	[ "$(find . -maxdepth 1 -type f -name \*.dwarfs | wc -l)" -eq 0 ] && return
	for dwarf in *.dwarfs; do
		mkdir -p "$mountdir/${dwarf%.*}"
		dwarfs "$dwarf" "$mountdir/${dwarf%.*}" && log mounted "'$dwarf'"
	done
)

[ "$wine" ] && {
	[ -d ~/.wine-ro ] && wine=$HOME/.wine-ro || wine=${WINEPREFIX-"$HOME"/.wine}
	log updating wine...
	WINEPREFIX="$wine" WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
	export WINEPREFIX="$overlaydir/.wine-ro"
	bindadd "$wine"
}

runner "$@"
