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

creator(){
	if [ -e "$1" ]; then
		log "'$1'" exists, moving into folder of same name
		tmp=$(mktemp -up "${1%/*}")
		mv -T "$1" "$tmp" || return 1
		mkdir "$1"
		mv -T "$tmp" "$1/$data/${1##*/}"
		log moved "'$1'" to "'$1/$data/${1##*/}'"
	else
		mkdir "$1"
	fi
	cd "$1" || exit
	mkdir "$mount" "$upper" "$work" "$overlay" "$data"
	touch "$mountlog"
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
mountlog=mountlog
data=data
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
s=0; for d in "$mount" "$upper" "$work" "$overlay" "$data"; do
	[ -d "$d" ] || { log "$path/$d isn't a dir"; s=1; }
done
[ "$s" -gt 0 ] && {
	log "$path isn't properly formatted"
	exit 1
}
{ [ "$(wc -c <"$mountlog")" -gt 0 ]; } 2>/dev/null && {
	log "$path/$mountlog" is not empty, indicating bad unmounting
	exit 1
}
trap 'printf "" > "$mountlog"' EXIT
mount -t tmpfs tmpfs "$mount"
command mount --make-rslave "$mount"

eval "$premount"

[ "$automount" ] && (
	cd "$data" || exit
	for p in * .[!.]* ..[!$]*; do
	[ -e "$p" ] || continue
		binder add "$mount" "$p"
	done
)

[ "$dwarfs" ] && (
	cd "$data" || exit
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
echo
log exiting...

cd "$path" || exit
{ # not foolproof but helps
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
		# if there are no processes but overlay is still mounted, lazy umount
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
