#!/bin/sh
# notes:
# 	socket files don't work until all prior connections are terminated
# 	moving files from lowerdir will *copy* them, using disk space

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

mount(){
	command mount -v "$@" && {
		eval last=\$$#
		printf '%s\0' "$last" >>"$mountlog"
	}
}

bind(){
	s=0
	root="$path/$1"
	shift
	while [ $# -gt 0 ]; do
		dirin=$1
		dirout=${2#/}
		if [ -d "$1" ]; then
			mkdir -p "$root/$dirout"
		else
			[ "${dirout%/*}" != "$dirout" ] && mkdir -p "$root/${dirout%/*}"
			touch "$root/$dirout"
		fi
		mount -o rbind,ro=recursive -- "$dirin" "$root/$dirout" &&
			command mount --make-rslave -- "$root/$dirout" || s=1
		shift 2
	done
	return $s
}

binder(){
	root=$2
	arg=$(realpath -e -- "$3")
	case $1 in
		add)
			arg2=${arg##*/} ;;
		root)
			arg2=$arg ;;
	esac
	bind "$root" "$arg" "$arg2"
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
	mkdir "$mount" "$upper" "$work" "$overlay"
	log created template
}

escapist(){ # to store arrays as escaped single quoted arguments
	if [ $# -eq 0 ]; then cat; else printf "%s\0" "$@"; fi |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

commadd(){
	v=$1
	shift
	eval "$v=\$$v"'"$(escapist "$@");"'
}

tmpfs(){
	mount -t tmpfs tmpfs -- "$path/$mount/$1"
}

mount=mount
upper=upper
work=work
overlay=overlay
while true; do
	case $1 in
		-automount) # get all paths in root and mount to lower
			automount=true
			;;
		-c|-create)
			creator "$(realpath -m "$2")"
			exit
			;;
		-dedupe) # compare lowerdirs with corresponding overlay dirs and remove dupes
			dedupe=true
			;;
		-dwarfs) # find *.dwarfs files and mount to lower
			dwarfs=true
			;;
		-bind*|-mnt*)
			[ "${1#'-bind'}" != "$1" ] && root=$overlay var=postmount || root=$mount var=premount
			case $1 in
				*add) commadd $var binder add "$root" "$2";;
				*root) commadd $var binder root "$root" "$2";;
				*) commadd $var bind "$root" "$2" "$3"; shift;;
			esac
			shift
			;;
		-tmpfs)
			commadd premount tmpfs "$2"
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
	path=$(realpath -e -- "$1")
	[ -z "$path" ] && exit 1
	shift
else
	path=$(realpath .)
fi
cd "$path" || exit
for d in "$mount" "$upper" "$work" "$overlay"; do [ -d "$d" ] || exit; done
mountlog=$path/mountlog
trap 'rm "$mountlog"' EXIT
mount -t tmpfs tmpfs "$mount"
command mount --make-rslave "$mount"

eval "$premount"

[ "$automount" ] && {
	for p in * .[!.]* ..[!$]*; do
	[ ! -e "$p" ] || [ "$p" = "$mount" ] || [ "$p" = "$upper" ] || [ "$p" = "$work" ] || [ "$p" = "$overlay" ] || [ "$p" = "$mountlog" ] && continue
		binder add "$mount" "$p"
	done
}

[ "$dwarfs" ] && (
	cd "$path" || exit
	for dwarf in *.dwarfs .*.dwarfs; do
		[ -f "$dwarf" ] || continue
		mkdir -p "$path/mount/${dwarf%.*}"
		dwarfs "$dwarf" "$path/mount/${dwarf%.*}" && log mounted "$dwarf"
	done
)

[ "$wine" ] && {
	[ -d ~/.wine-ro ] && wine=$HOME/.wine-ro || wine=${WINEPREFIX-"$HOME"/.wine}
	log updating wine...
	export WINEPREFIX="$wine"
	WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
	binder add "$mount" "$wine"
}

# mount -t overlay overlay -o lowerdir="$mount",upperdir=upper,workdir=work,userxattr "$overlay" && log mounted overlayfs || exit
fuse-overlayfs \
	-o "lowerdir=$mount,upperdir=$upper,workdir=$work" \
	-o "squash_to_uid=$(id -ru),squash_to_gid=$(id -rg)" \
	"$overlay" && log mounted fuse-overlayfs || exit

eval "$postmount"

[ "$wine" ] && {
	mount --bind "$overlay/${wine##*/}" "$wine"
}

cd "$overlay" || exit
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
log exiting...

cd "$path" || exit
{
	n=$(tr -cd '\0' <"$mountlog" | wc -c)
	[ "$n" ] || return
	for i in $(seq 1 $n | tac); do
		line=$(sed -zn "$i"p <"$mountlog")
		umount -vr -- "$line"
	done
}
until err=$(umount "$overlay" 2>&1) && log unmounted overlayfs; do
	pidlist=$(fuser -Mm "$overlay" 2>/dev/null) || {
		mountpoint -q "$overlay" || break
		umount -l "$overlay"
		log lazily unmounted overlayfs
		break
	}
	if [ "$pidlist" != "$prevlist" ]; then
		echo "$err"
		# ps -p "$(echo "$pidlist" | sed 's/\s\+/,/g; s/^,\+//')"
		fuser -vmM "$overlay"
		change=1
	elif [ "$change" -eq 1 ]; then
		log waiting...
		change=0
	fi
	prevlist=$pidlist

	sleep 1
done
umount -l "$mount"
