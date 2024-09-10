#!/bin/sh
# set -x
# rules:
# images in use should be in the root directory
# lower stores multiple mountpoints

log(){
	printf '%s\n' "${0##*/}: $*"
}

escapist(){ # to store arrays as escaped single quoted arguments
	printf "%s\0" "$@" |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

foldout(){ # /path/to/dir -> /path/to/dir/dir
	until [ $# -eq 0 ]; do
		arg=$1
		pickup=$2
		tmp=$(mktemp -up "${arg%/*}")
		mv -T "$arg" "$tmp" || return 1
		mkdir "$arg"
		mv -T "$tmp" "$arg/${arg##*/}"
		[ "$pickup" = 1 ] && {
			foldinlist="$foldinlist $(escapist "$arg")$(stat -c %a "$arg")"
			chmod a-w "$arg"
		}
		shift 2
		log moved "'$arg'" to "'$arg/${arg##*/}'"
	done
}

foldin(){ # /path/to/dir/dir -> /path/to/dir
	until [ $# -eq 0 ]; do
		arg=$1
		octal=$2
		chmod "$octal" "$arg"
		tmp=$(mktemp -up "${arg%/*}")
		mv -T "$arg/${arg##*/}" "$tmp"
		rmdir "$arg" || { mv -T "$tmp" "$arg/${arg##*/}"; return 1; }
		mv -T "$tmp" "$arg"
		shift 2
		log moved "'$arg/${arg##*/}'" to "'$arg'"
	done
}

loweradd(){
	for arg; do
		case $arg in *:*) log "'$arg'" contains "':'", which breaks fuse-overlayfs.; exit 1;; esac
		if [ -d "$arg/${arg##*/}" ] && [ "$(find "$arg" -maxdepth 1 -print0 | head -zn3 | tr -cd '\0' | wc -c)" -eq 2 ]; then
			log "'$arg'" already in correct format
		else
			foldoutlist="$foldoutlist $(escapist "$arg")1"
		fi
		# escaping colons SHOULD work, but it doesn't, because it's not yet implemented
		lowerdirs=$lowerdirs:$(printf %s "$arg" | sed 's/\([,:\\]\)/\\\1/g')
	done
}
lowerdirs=lower

creator(){
	if [ -e "$path" ]; then
		log "'$path'" exists, moving into folder of same name
		foldout "$path" 0
	else
		mkdir "$path"
	fi
	cd "$path" || exit
	mkdir lower upper work
	log created template
}

mounter(){
	cd "$path" || exit
	for d in lower upper work; do [ -d "$d" ] || exit; done
	mkdir -p "$overlaydir"
	[ -n "$foldoutlist" ] && eval foldout "$foldoutlist"
	fuse-overlayfs -o lowerdir="$lowerdirs" -o upperdir=upper -o workdir=work "$overlaydir" && log mounted overlayfs || exit
	ln -sfnT "$overlaydir" "$path"/overlay
}

umounter(){
	cd "$path" || exit
	s=0
	fusermount3 -u "$overlaydir" && log unmounted overlayfs || return 1
	cd lower || exit
	for name in * .*; do
		case $name in .|..) continue;; esac
		mountpoint -q "$name" && {
			fusermount3 -u "$name" && { log unmounted "'$name'"; rmdir "$name"; } || s=1
		}
	done
	cd ..
	[ "$tmpfs" ] && tmpfser unmount
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
	cd overlay || exit 1

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

	supumounter
}

exiter(){
	[ -n "$foldinlist" ] && eval foldin "$foldinlist"
	exit
}
trap exit INT TERM HUP
trap exiter EXIT

case $1 in
	c*)
		func=create;;
	m*)
		func=mount;;
	u*)
		func=umount;;
	e*)
		func=execute;;
esac
shift


while true; do
	case $1 in
		-automount) # get all paths in root and mount to lower
			automount=true
			;;
		-dwarfs) # find *.dwarfs files and mount to lower
			dwarfs=true
			;;
		-lower)
			loweradd "$2"
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

[ $# -eq 0 ] && exit 1
path=$(realpath -m "$1")
overlaydir=$XDG_RUNTIME_DIR/overlay.sh/$(printf %s "$path" | sha1sum | cut -d' ' -f1)
shift

[ "$automount" ] && {
	for p in "$path"/*; do
		case $p in */upper|*/work|*/overlay|*/lower) continue;; esac
		loweradd "$p"
	done
}

[ "$dwarfs" ] && (
	cd "$path" || exit
	for dwarf in *.dwarfs; do
		mkdir -p "lower/${dwarf%.*}"
		dwarfs "$dwarf" "lower/${dwarf%.*}" && log mounted "'$dwarf'"
	done
)

[ "$wine" ] && {
	[ -d ~/.wine-ro ] && wine=$HOME/.wine-ro || wine=${WINEPREFIX-"$HOME"/.wine}
	log updating wine...
	WINEPREFIX="$wine" WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
	export WINEPREFIX="$overlaydir/.wine-ro"
	loweradd "$wine"
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
