#!/bin/sh
set -x
# rules:
# images in use should be in the root directory
# lower stores multiple mountpoints

log(){
	echo "${0##*/}:" "$@"
}

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
		# if [ -n "$lowerdirs" ]; then
		# 	lowerdirs=$lowerdirs:$(printf %s "$arg" | sed 's/\([,:\\]\)/\\\1/g')
		# else
		# 	lowerdirs=$(printf %s "$arg" | sed 's/\([,:\\]\)/\\\1/g')
		# fi
	done
}
lowerdirs=lower

tmpfser(){
	upperdir=$tmppath/upper
	workdir=$tmppath/work
	if [ "$1" = "unmount" ]; then
		mv -T "$workdir" "$path/work"
		# mv -T "$upperdir" "$path/upper"
		rsync -aHAWXS --numeric-ids --delete "$upperdir/" "$path/upper"
		rm -rf "$upperdir"
	else # mount
		mv -T "$path/work" "$workdir"
		# mv -T "$path/upper" "$upperdir"
		mkdir "$upperdir"
		rsync -aHAWXS --numeric-ids "$path/upper/" "$upperdir"
	fi
}

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
	mkdir upper work
	log created template
}

mounter(){
	cd "$tmppath" || exit
	mkdir -p lower overlay || exit
	[ "$dwarfs" ] && {
		cd "$path" || exit
		for dwarf in *.dwarfs; do
			mkdir -p "$tmppath/lower/${dwarf%.*}"
			dwarfs "$dwarf" "$tmppath/lower/${dwarf%.*}" && log mounted "'$dwarf'"
		done
		cd "$OLDPWD" || exit
	}
	[ "$tmpfs" ] && tmpfser
	[ -n "$wine" ] && {
		log updating wine...
		WINEPREFIX="$wine" WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
		export WINEPREFIX="$PWD/overlay/.wine-ro"
	}
	[ -n "$foldoutlist" ] && eval foldout "$foldoutlist"
	fuse-overlayfs -o lowerdir="$lowerdirs" -o upperdir="$upperdir" -o workdir="$workdir" overlay && log mounted overlayfs || {
		s=$?
		[ "$tmpfs" ] && tmpfser unmount
		exit $s
	}
}

umounter(){
	cd "$tmppath" || exit
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
			# store upper in tmpfs.
			# this shouldn't be used to workaround filesystem quirks
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
case $path in *:*) log "'$path'" contains "':'", which breaks fuse-overlayfs.; exit 1;; esac
tmppath=$XDG_RUNTIME_DIR/overlay.sh/$(printf %s "$path" | sha1sum | cut -d' ' -f1)
mkdir -p "$tmppath"
shift

upperdir=$path/upper
workdir=$path/work

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
