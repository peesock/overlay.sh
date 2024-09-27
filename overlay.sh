#!/bin/sh
# set -x

if [ "$1" = 1 ]; then
	shift
else
	exec unshare -cm --keep-caps -- "$0" 1 "$@"
fi

log(){
	printf '%s\n' "${0##*/}: $*"
}

bindadd(){
	for arg; do
		mkdir "$mountdir/${arg##*/}"
		mount --bind "$arg" "$mountdir/${arg##*/}"
	done
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
	if [ -e "$path" ]; then
		log "'$path'" exists, moving into folder of same name
		foldout "$path"
	else
		mkdir "$path"
	fi
	cd "$path" || exit
	mkdir upper work
	log created template
}

mounter(){
	cd "$path" || exit
	for d in upper work; do [ -d "$d" ] || exit; done
	mkdir -p "$mountdir" "$overlaydir"
	# mount -t overlay overlay -o lowerdir="$mountdir",upperdir=upper,workdir=work,userxattr "$overlaydir" && log mounted overlayfs || exit
	fuse-overlayfs -o lowerdir="$mountdir",upperdir=upper,workdir=work "$overlaydir" && log mounted overlayfs || exit
	ln -sfnT "$overlaydir" "$path"/overlay
	ln -sfnT "$mountdir" "$path"/mount
}

umounter(){
	cd "$path" || exit
	mountpoint -q "$overlaydir" && {
		umount "$overlaydir" && log unmounted overlayfs || return 1
	}
	s=0
	cd "$mountdir" || exit
	[ "$(find . -maxdepth 1 | wc -c)" -gt 2 ] &&
		for name in * .*; do
			case $name in .|..) continue;; esac
			if mountpoint -q "$name"; then
				umount "$name" && { log unmounted "'$name'"; rmdir "$name"; } || s=1
			else
				rmdir "$name"
			fi
		done
	cd "$OLDPWD" || exit
	return $s
}

supumounter(){
	i=0
	until umounter; do
		log waiting...
		sleep 1
		# [ $i -ge 5 ] && {
		# 	log killing...
		# 	fuser -Mikv "$mount" || break
		# }
		i=$((i + 1))
	done
}

executor(){
	mounter
	cd "$path/overlay" || exit
	if [ $# -ge 1 ]; then
		unshare -c "$@"
	elif [ -t 1 ]; then
		log entering shell...
		unshare -c "$SHELL"
		log returning...
	else
		log provide a command.
		exit 1
	fi
	supumounter
}

case $1 in
	c*)
		func=create;;
	# m*)
	# 	func=mount;;
	u*)
		func=umount;;
	e*)
		func=execute;;
	*)
		log "'$1'" not a function
		exit 1;;
esac
shift


[ $# -eq 0 ] && exit 1
path=$(realpath -m "$1")
overlaydir=$XDG_RUNTIME_DIR/overlay.sh/$(printf %s "$path" | sha1sum | cut -d' ' -f1)
mountdir=$overlaydir/mount
overlaydir=$overlaydir/overlay
shift

while true; do
	case $1 in
		-automount) # get all paths in root and mount to lower
			automount=true
			;;
		-dedupe) # compare lowerdirs with corresponding overlay dirs and remove dupes
			dedupe=true
			;;
		-dwarfs) # find *.dwarfs files and mount to lower
			dwarfs=true
			;;
		-bindadd)
			l=$(realpath -e "$2") || exit
			bindadd "$l"
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

case $func in
	create)
		creator;;
	mount)
		mounter;;
	umount)
		umounter;;
	execute)
		executor "$@";;
esac
