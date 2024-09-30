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

bind(){
	s=0
	root=$1
	shift
	while [ $# -gt 0 ]; do
		if [ -d "$1" ]; then
			mkdir -p "$root/$2"
			echo mkdir -p "$root/$2"
		else
			[ "${2%/*}" != "$2" ] && mkdir -p "$root/${2%/*}"
			touch "$root/$2"
		fi
		mount --rbind "$1" "$root/$2" &&
			mount --make-rslave "$root/$2" || s=1
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
	mkdir mount upper work overlay
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
			[ "${1#'-bind'}" != "$1" ] && root=$overlay func=postmount || root=$mount func=premount
			case $1 in
				*add) commadd $func binder add "$root" "$2";;
				*root) commadd $func binder root "$root" "$2";;
				*) commadd $func bind "$root" "$2"; shift;;
			esac
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
mount -t tmpfs tmpfs "$mount"
mount --make-rslave "$mount"

eval "$premount"

[ "$automount" ] && {
	for p in "$path"/*; do
		case $p in */upper|*/work|*/mount|*/overlay) continue;; esac
		binder add "$mount" "$p"
	done
}

[ "$dwarfs" ] && (
	cd "$path" || exit
	[ "$(find . -maxdepth 1 -type f -name \*.dwarfs | wc -l)" -eq 0 ] && return
	for dwarf in *.dwarfs; do
		mkdir -p "$path/mount/${dwarf%.*}"
		dwarfs "$dwarf" "$path/mount/${dwarf%.*}" && log mounted "'$dwarf'"
	done
)

[ "$wine" ] && {
	[ -d ~/.wine-ro ] && wine=$HOME/.wine-ro || wine=${WINEPREFIX-"$HOME"/.wine}
	log updating wine...
	WINEPREFIX="$wine" WINEDEBUG=-all DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
	export WINEPREFIX="$path/overlay/.wine-ro"
	binder add "$mount" "$wine"
}

# mount -t overlay overlay -o lowerdir="$mount",upperdir=upper,workdir=work,userxattr "$overlay" && log mounted overlayfs || exit
fuse-overlayfs -o "lowerdir=$mount,upperdir=$upper,workdir=$work" "$overlay" && log mounted fuse-overlayfs || exit

eval "$postmount"

cd overlay || exit
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

cd "$path" || exit
until err=$(umount "$overlay" 2>&1) && log unmounted overlayfs; do
	pidlist=$(fuser -Mm "$overlay" 2>/dev/null) || {
		mountpoint -q "$overlay" || break
		umount -l "$overlay"
		log lazily unmounted overlayfs
		break
	}
	if [ "$pidlist" != "$prevlist" ]; then
		echo "$err"
		ps -p "$(echo "$pidlist" | sed 's/\s\+/,/g; s/^,\+//')"
		change=1
	elif [ "$change" -eq 1 ]; then
		log waiting...
		change=0
	fi
	prevlist=$pidlist

	sleep 1
done
umount -l "$mount"
