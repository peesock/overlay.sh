#!/bin/sh
set -x
# rules:
# images in use should be in the root directory
# lower either is a mointpoint, or stores multiple mountpoints

log(){
	echo "${0##*/}:" "$@"
}

# [ "$1" = binder ] && {
# 	[ $# -le 2 ] && exit
# 	path=$2
# 	shift 2
# 	for name; do
# 		name2="$path/lower/${name##*/}"
# 		mkdir -p "$name2"
# 		bindfs --multithreaded "$name" "$name2" || exit 1
# 		log mounted "$name"
# 	done
# 	exit
# }

escapist(){ # to store arrays as escaped single quoted arguments
	printf "%s\0" "$@" |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

foldout(){ # /path/to/dir -> /path/to/dir/dir
	for arg; do
		tmp=$(mktemp -dp "${arg%/*}")
		mv -Tf "$arg" "$tmp"
		mkdir "$arg"
		mv -T "$tmp" "$arg/${arg##*/}"
		foldinlist="$foldinlist $(escapist "$arg") $(stat -c %a "$arg")"
		chmod a-w "$arg"
		log moved "'$arg'" to "'$arg/${arg##*/}'"
	done
}

foldin(){ # /path/to/dir/dir -> /path/to/dir
	until [ $# -eq 0 ]; do
		arg=$1
		octal=$2
		chmod "$octal" "$arg"
		tmp=$(mktemp -dp "${arg%/*}")
		mv -Tf "$arg/${arg##*/}" "$tmp"
		mv -Tf "$tmp" "$arg" || { mv -T "$tmp" "$arg/${arg##*/}"; return 1; }
		shift 2
		log moved "'$arg/${arg##*/}'" to "'$arg'"
	done
}

loweradd(){
	for arg; do
		if [ -d "$arg/${arg##*/}" ] && [ "$(find "$arg" -maxdepth 1 -print0 | head -zn3 | tr -cd '\0' | wc -c)" -eq 2 ]; then
			log "'$arg'" already in correct format
		else
			foldoutlist="$foldoutlist $(escapist "$arg")"
		fi
		# escaping colons SHOULD work, but it doesn't, because it's not yet implemented
		lowerdirs=$lowerdirs:$(printf %s "$arg" | sed 's/\([,:\\]\)/\\\1/g')
	done
}
# tmplist=$(mktemp)
# trap '[ -n "$tmplist" ] && rm "$tmplist"' EXIT
# bindadd(){
# 	printf "%s\0" "$@" >> "$tmplist"
# }

creator(){
	if [ -e "$path" ]; then
		log "'$path'" exists, moving into folder of same name
		foldout "$path"
	else
		mkdir "$path"
	fi
	cd "$path" || exit
	mkdir lower upper work overlay
	log created template
	exit
}

mounter(){
	cd "$path" || exit
	for name in lower upper work overlay; do [ -d "$name" ] || exit 1; done
	# xargs -0 "$0" binder "$path" <"$tmplist" || exit 1
	# rm "$tmplist"; unset tmplist
	[ "$dwarfs" ] && {
		for dwarf in *.dwarfs; do
			mkdir -p "lower/${dwarf%.*}"
			dwarfs "$dwarf" "lower/${dwarf%.*}" && log mounted "'$dwarf'"
		done
	}
	[ "$tmpfs" ] && {
		name=$XDG_RUNTIME_DIR/overlay.sh/$(printf %s "$path" | sha256sum | cut -d' ' -f1)
		upper=$name/upper
		work=$name/work
		mkdir -p "$name"
		mv -T work "$work" || exit
		mv -T upper "$upper" || exit
	}
	[ -n "$wine" ] && {
		log updating wine...
		WINEPREFIX="$wine" WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
		export WINEPREFIX="$PWD/overlay/.wine-ro"
	}
	[ -n "$foldoutlist" ] && eval foldout "$foldoutlist"
	fuse-overlayfs -o lowerdir="$lowerdirs" -o upperdir="$upper" -o workdir="$work" overlay && log mounted overlayfs || exit 1
}

umounter(){
	cd "$path" || exit
	s=0
	fusermount3 -u overlay && log unmounted overlayfs || return 1
	cd lower || exit
	for name in * .*; do
		case $name in .|..) continue;; esac
		mountpoint -q "$name" && {
			fusermount3 -u "$name" && { log unmounted "'$name'"; rmdir "$name"; } || s=1
		}
	done
	cd ..
	[ "$tmpfs" ] && {
		name=$XDG_RUNTIME_DIR/overlay.sh/$(printf %s "$path" | sha256sum | cut -d' ' -f1)
		upper=$name/upper
		work=$name/work
		mv -T "$work" work || exit
		mv -T "$upper" upper || exit
		rmdir "$name"
	}
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

lowerdirs=lower
upper=upper
work=work

while true; do
	case $1 in
		-dwarfs)
			dwarfs=true
			;;
		-wine)
			case $func in mount|execute)
				[ -d ~/.wine-ro ] && wine=$HOME/.wine-ro || wine=${WINEPREFIX-"$HOME"/.wine}
				loweradd "$wine"
				;;
			esac
			;;
		-lower)
			case $2 in *:*) log "'$2'" contains "':'", which breaks fuse-overlayfs.; exit 1;; esac
			loweradd "$2"
			shift
			;;
		# -bindfs)
		# 	bindadd "$(realpath -e "$2")" || exit
		# 	shift
		# 	;;
		-tmpfs)
			# store upper in tmpfs to workaround filesystem issues
			tmpfs=true
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
shift

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
