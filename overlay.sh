#!/bin/sh
set -x
# rules:
# images in use should be in the root directory
# lower either is a mointpoint, or stores multiple mountpoints

log(){
	echo "${0##*/}:" "$@"
}

[ "$1" = binder ] && {
	[ $# -le 2 ] && exit
	path=$2
	shift 2
	for name; do
		name2="$path/lower/${name##*/}"
		mkdir -p "$name2"
		bindfs --multithreaded "$name" "$name2" || exit 1
		log mounted "$name"
	done
	exit
}

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

# loweradd(){
# 	# escaping colons SHOULD work, but it doesn't, because it's not yet implemented
# 	for arg; do dirs=$dirs:$(printf %s "$arg" | sed 's/\([,:\\]\)/\\\1/g'); done
# }
# loweradd lower
tmplist=$(mktemp)
trap '[ -n "$tmplist" ] && rm "$tmplist"' EXIT
bindadd(){
	printf "%s\0" "$@" >> "$tmplist"
}

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
				bindadd "$wine"
				;;
			esac
			;;
		# -lower)
		# 	loweradd "$2"
		# 	shift
		# 	;;
		-bindfs)
			bindadd "$(realpath -e "$2")" || exit
			shift
			;;
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

creator(){
	if [ -e "$path" ]; then
		log "'$path'" exists, moving into folder of same name
		tmp=$(mktemp -up "${path%/*}")
		mv "$path" "$tmp"
		mkdir "$path"
		mv "$tmp" "$path/${path##*/}"
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
	xargs -0 "$0" binder "$path" <"$tmplist" || exit 1
	rm "$tmplist"; unset tmplist
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
	fuse-overlayfs -o lowerdir=lower -o upperdir="$upper" -o workdir="$work" overlay && log mounted overlayfs || exit 1
}

umounter(){
	cd "$path" || exit
	s=0
	fusermount3 -u overlay && log unmounted overlayfs || return 1
	cd lower || exit
	for name in * .*; do
		[ "$name" = '.' ] && continue
		[ "$name" = '..' ] && continue
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

exiter(){
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

	exiter
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
