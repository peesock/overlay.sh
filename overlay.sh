#!/bin/sh -x
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
		printf '%s\0' "$last" >>"$Path/$Mountlog"
	}
}

# get is read-only, add and free overwrite.
indexer(){
	case $1 in
		get) # index from path
			{ printf %s\\0 "$2"; cat "$Index"; } | awk '
				BEGIN{ RS="\0" }
				{
					if (NR == 1) key=$0;
					else if (NR % 2 == 1) {if ($0 == key) print prev}
					else prev = $0
				}'
			;;
		add) # calculate new index and assign a path to it
			tmp=$(mktemp -p "$Storage")
			{ printf %s\\0 "$2"; cat "$Index"; } | awk '
				BEGIN{ RS="\0"; ORS="\0"; i=0 }
				{
					if (NR == 1) path=$0;
					else { if (NR % 2 == 0){ if ($0 == "free") exit; i++} print $0 }
				}
				END{ print i "\0" path }' > "$tmp"
			mv "$tmp" "$Index"
			;;
		free) # search for missing paths and mark as free
			for dir in $(awk 'BEGIN{RS="\0"}{if (NR % 2 == 1) print $0}' <"$Index"); do
				[ -d "$Storage/$dir" ] || {
					freelist="$freelist$dir "
				}
			done
			[ "$freelist" ] && {
				tmp=$(mktemp -p "$Storage")
				{ printf %s\\0 "$freelist"; cat "$Index"; } | awk '
				BEGIN{ RS="\0"; ORS="\0"; n=1 }
				{
					if (NR==1) { for (i=1;i<=NF;i++) arr[i] = $i } else {
					if (NR % 2 == 0 && arr[n] == $0) { print "free"; n++ } else print $0
					}
				}' >"$tmp"
				mv "$tmp" "$Index"
			}
			;;
	esac
}

# $1 is the input path, remains as-is
# $2 is the output, relative to overlay
# `overbind /home/balls /buh/muh` mounts /home/balls to $Overlay/buh/muh.
overbind(){
	s=0
	while [ $# -gt 0 ]; do
		pathin=$1
		pathout=${2#/}
		if [ -d "$1" ]; then
			mkdir -p "$Tree/public/$pathout" "$Tree/private/$pathout"
		else
			[ "${pathout%/*}" != "$pathout" ] && mkdir -p "$Tree/public/${pathout%/*}" "$Tree/private/${pathout%/*}"
			touch "$Tree/public/$pathout" "$Tree/private/$pathout"
		fi
		unset I
		I=$(indexer get "$pathin")
		[ "$I" ] || {
			indexer add "$pathin"
			I=$(indexer get "$pathin")
		}
		mkdir -p "$Storage/$I/up" "$Storage/$I/wrk"
		mount -t overlay overlay -o userxattr \
			-o "lowerdir=$pathin,upperdir=$Storage/$I/up,workdir=$Storage/$I/wrk" \
			"$Overlay/$pathout" && log mounted "$pathin" to "$Overlay/$pathout" || s=1
		shift 2
	done
	return $s
}

overbinder(){
	path=$(realpath --relative-base="$Path" -e -- "$2")
	case $1 in
		add) # add basename of path inside the root of overlay
			arg2=${path##*/} ;;
		copy) # copy full path inside overlay
			arg2=$path ;;
		free) # mount path anywhere inside overlay
			arg2=$3
	esac
	overbind "$path" "$arg2"
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
	mkdir "$Storage" "$Tree" "$Overlay" "$Data"
	touch "$Index"
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

# tmpfs(){
# 	mount -t tmpfs tmpfs -- "$Path/$mount/$1"
# }

mountplacer(){ # would be more efficient to mount overlays directly, reserved for the future
	[ -n "$2" ] && {
		one=$1
		shift
		commadd premount log running "'$*'"...
		commadd premount "$@"
		set -- "$one" "$@"
	}
	commadd postmount overbinder add "$1"
	postmount=$postmount'until [ -z "$(lsof +D '"$(escapist "$1")"' 2>/dev/null)" ]; do true; done;'
	commadd postmount mount --bind "$Overlay/${1##*/}" "$1"
}

automount()(
	cd "$Data" || {
		log create a directory named "'$Data'"
		exit 1
	}
	for p in * .[!.]* ..[!$]*; do
		[ -e "$p" ] || continue
		[ "${p%.dwarfs}" != "$p" ] && {
			dwarfdir="$Path/$Tree/private/${p%.*}"
			mkdir -p "$dwarfdir"
			dwarfs "$p" "$dwarfdir" &&
				log dwarf mounted "$p" &&
				overbinder add "$dwarfdir"
		}
		overbinder add "$p"
	done
)

Storage=storage
Overlay=overlay
Tree=tree
Data=$Storage/data
Index=$Storage/index
Mountlog=$Storage/mountlog
export XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
global=$XDG_DATA_HOME/$programName
while true; do
	case $1 in
		-auto)
			autocd=true
			commadd premount automount
			;;
		-autocd) # cd into either overlaydir or the only available non-hidden mount dir
			autocd=true
			;;
		-automount) # get all paths in root and mount to lower
			commadd premount automount
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
		-mnt*)
			case $1 in
				*add) commadd postmount overbinder add "$2";;
				*copy) commadd postmount overbinder copy "$2";;
				*) commadd postmount overbinder free "$2" "$3"; shift;;
			esac
			shift
			;;
		# -tmpfs)
		# 	commadd premount tmpfs "$2"
		# 	shift
		# 	;;
		-mountplace*)
			if [ "$1" = mountplacexec ]; then
				mountplacer "$2" "$3"
				shift 2
			else
				mountplacer "$2"
				shift
			fi
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
	Path=$(realpath -e -- "$1")
	[ -z "$Path" ] && exit 1
	shift
else
	Path=$(realpath .)
fi
cd "$Path" || exit
s=0; for d in "$Storage" "$Overlay" "$Tree"; do
	[ -d "$d" ] || { log "$Path/$d isn't a dir"; s=1; }
done
[ "$s" -gt 0 ] && {
	log "$Path isn't properly formatted"
	exit 1
}
grep -zq . "$Mountlog" 2>/dev/null && {
	log "$Path/$Mountlog" is not empty, indicating bad unmounting. Investigate and/or remove the file.
	exit 1
}

trap 'rm "$Mountlog"' EXIT
command mount -t tmpfs tmpfs "$Tree"
command mount --make-rslave "$Tree"
mkdir "$Tree/private" "$Tree/public"

# commands that need to run before mounting
eval "$premount"

overbind "$Tree/public" /

# commands that need to run after mounting
eval "$postmount"

[ "$autocd" ] && {
	unset dir
	for p in "$Tree/private"/*; do
		[ -d "$p" ] && {
			if [ -z "$dir" ]; then
				dir=$Overlay/${p##*/}
			else
				dir=$Overlay
				break
			fi
		}
	done
	cd "${dir-"$Overlay"}" || exit
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

cd "$Path" || exit

[ "$dedupe" ] && {
	log dedupe? erm not yet sweetheart
	return
	tmp=$(mktemp)
	for p in "$mount"/*/*; do
		upp="$upper/${p##*/}"
		[ -e "$upp" ] || continue
		log looking for duplicates in "$upp"
		find "$upp" -depth -type f -print0 |
			cut -zb $(($(printf %s "$upper/" | wc -c) + 1))- |
			# BUG!!!!!!!!!!!! BUG!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
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
	n=$(tr -cd '\0' <"$Mountlog" | wc -c)
	[ "$n" ] || return
	for i in $(seq 1 "$n" | tac); do
		line=$(sed -zn "$i"p <"$Mountlog")
		umount -vr -- "$line"
	done
}
until err=$(umount "$Overlay" 2>&1) && log unmounted overlayfs; do
	pidlist=$(fuser -Mm "$Overlay" 2>/dev/null) || {
		mountpoint -q "$Overlay" || break
		# if there are no processes but overlay is still mounted, lazy umount
		umount -l "$Overlay"
		log lazily unmounted overlayfs
		break
	}
	if [ "$pidlist" != "$prevlist" ]; then
		echo "$err"
		# ps -p "$(echo "$pidlist" | sed 's/\s\+/,/g; s/^,\+//')"
		fuser -vmM "$Overlay"
		change=1
	elif [ "$change" -eq 1 ]; then
		log waiting...
		change=0
	fi
	prevlist=$pidlist

	sleep 1
done
umount -l "$Tree"
