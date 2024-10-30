#!/bin/sh
# notes:
# 	socket files don't work until all prior connections are terminated
# 	moving files from lowerdir will *copy* them, using disk space

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
		printf '%s\0' "$last" >>"$path/$mountlog"
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
		mv -T "$tmp" "$1/${1##*/}" &&
			log moved "'$1'" to "'$1/${1##*/}'"
	else
		mkdir "$1"
	fi
	cd "$1" || exit
	mkdir "$mount" "$upper" "$work" "$overlay" "$data"
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

mountplacer(){
	[ -n "$2" ] && {
		one=$1
		shift
		commadd premount log running "'$*'"...
		commadd premount "$@"
		set -- "$one" "$@"
	}
	commadd premount binder add "$mount/public" "$1"
	postmount=$postmount'until [ -z "$(lsof +D '"$(escapist "$1")"' 2>/dev/null)" ]; do true; done;'
	commadd postmount mount --bind "$overlay/${1##*/}" "$1"
}

mount=mount
upper=upper
work=work
overlay=overlay
mountlog=mountlog
data=data
export XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
global=$XDG_DATA_HOME/$programName
while true; do
	case $1 in
		-auto)
			autocd=true
			automount=true
			;;
		-autocd) # cd into either overlaydir or the only available non-hidden mount dir
			autocd=true
			;;
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
		-i|-interactive) # prompt before deleting
			interactive=true
			;;
		-bind*|-mnt*)
			[ "${1#'-bind'}" != "$1" ] && root=$overlay var=postmount || root=$mount/private var=premount
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
			export WINEPREFIX="$global/$2"
			mkdir -p "$WINEPREFIX"
			mountplacer "$WINEPREFIX" wineboot
			shift
			;;
		-proton)
			export STEAM_COMPAT_DATA_PATH="$global/$2"
			mkdir -p "$STEAM_COMPAT_DATA_PATH"
			mountplacer "$STEAM_COMPAT_DATA_PATH" proton wineboot
			shift
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
s=0; for d in "$mount" "$upper" "$work" "$overlay"; do
	[ -d "$d" ] || { log "$path/$d isn't a dir"; s=1; }
done
[ "$s" -gt 0 ] && {
	log "$path isn't properly formatted"
	exit 1
}
grep -zq . "$mountlog" 2>/dev/null && {
	log "$path/$mountlog" is not empty, indicating bad unmounting
	exit 1
}
trap 'rm "$mountlog"' EXIT
mount -t tmpfs tmpfs "$mount"
command mount --make-rslave "$mount"
mkdir "$mount"/private "$mount"/public

eval "$premount"

[ "$automount" ] && (
	cd "$data" || {
		log create a directory named "'$data'"
		exit 1
	}
	for p in * .[!.]* ..[!$]*; do
		[ -e "$p" ] || continue
		[ "${p%.dwarfs}" != "$p" ] && {
			mkdir -p "$path/$mount/private/${p%.*}"
			dwarfs "$p" "$path/$mount/private/${p%.*}" &&
				log dwarf mounted "$p" && continue
		}
		binder add "$mount/private" "$p"
	done
)

# ponder making overlay/{private,public} too
fuse-overlayfs \
	-o "lowerdir=$mount/public:$mount/private,upperdir=$upper,workdir=$work" \
	-o "squash_to_uid=$(id -ru),squash_to_gid=$(id -rg)" \
	"$overlay" && log mounted fuse-overlayfs || exit

eval "$postmount"

[ "$autocd" ] && {
	unset dir
	for p in "$mount"/private/*; do
		[ -d "$p" ] && {
			if [ -z "$dir" ]; then
				dir=$overlay/${p##*/}
			else
				dir=$overlay
				break
			fi
		}
	done
	cd "${dir-"$overlay"}" || exit
}

trap 'log INT recieved' INT # TODO: signal handling
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
trap - INT

cd "$path" || exit

[ "$dedupe" ] && {
	tmp=$(mktemp)
	for p in "$mount"/*/*; do
		upp="$upper/${p##*/}"
		[ -e "$upp" ] || continue
		log looking for duplicates in "$upp"
		find "$upp" -depth -type f -print0 |
			cut -zb $(($(printf %s "$upper/" | wc -c) + 1))- |
			awk -v upper="$upper/" -v mount="${p%/*}/" 'BEGIN{RS="\0"; ORS="\0"} {print upper$0; print mount$0}' |
			unshare -rmpf --mount-proc -- xargs -0 -n 64 -- sh -c '
				until [ $# -le 0 ]; do
					[ -e "$2" ] &&
						(cmp -s -- "$1" "$2" && { waitpid "$pid" 2>/dev/null; printf "%s\0" "$1"; } ) & pid=$!
					shift 2
				done
				wait
			' sh | tee "$tmp" | tr '\0' '\n'
			# unshare creates a new pid namespace so that pid collisions are impossible
		grep -qz . <"$tmp" && {
			[ "$interactive" ] && {
				printf "delete these files? y/N: "
				read -r line
			} || line=y
			case $line in y|Y)
				xargs -0 rm -- <"$tmp"
				# todo: better rmdir
				xargs -0 dirname -z -- <"$tmp" | uniq -z | xargs -0 rmdir -p --ignore-fail-on-non-empty -- 2>/dev/null
				log removed duplicates
				;;
			esac
		}
	done
	rm "$tmp"
}

{ # not foolproof but helps
	n=$(tr -cd '\0' <"$mountlog" | wc -c)
	[ "$n" ] || return
	for i in $(seq 1 "$n" | tac); do
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
