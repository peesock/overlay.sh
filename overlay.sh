#!/bin/sh

# todo:
# 	make indexer free do more and run it in exiter
# 	recursive overmounts
# 	remove specific code. add some API to replace it

# notes:
# 	KERNEL BUG!!!!!!!!!!!!!!! it's not possible to mount overlay upperdirs on fuse in a new user namespace,
# 		so this can't be used on fuse right now. investigating now as of committing this unseen comment...
# 	KERNEL BUG 2!!!!!!!!!!!!! your lowerdir cannot have an odd number of double quotes in the path.

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
	command mount "$@" && {
		eval last=\$$#
		printf '%s\0' "$last" >>"$Path/$Mountlog"
	}
}

# get is read-only, while add and free overwrite index.
indexer(){
	case $1 in
		get) # index from path
			{ printf %s\\0 "$2"; cat "$Index"; } | awk '
				BEGIN{ RS="\0" }
				{
					if (NR == 1) path=$0;
					else if (NR % 2 == 1) {if ($0 == path && prev != "free") print prev}
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
		free)
			# search for nonexistent or empty paths in index and mark as free
			for dir in $(awk 'BEGIN{RS="\0"}{if (NR % 2 == 1) print $0}' <"$Index"); do
				[ ! -d "$Storage/$dir" ] || find "$Storage/$dir/up" -maxdepth 1 -mindepth 1 | grep -q . || {
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
		clean)
			# rmdir
			# for dirs; do if entry missing or free, rmdir?
			;;
	esac
}

# $1 is the input path, remains as-is
# $2 is the output, relative to overlay
# `overbind /home/balls /buh/muh` mounts /home/balls to $Overlay/buh/muh.
overbind(){
	s=0
	pathin=$1
	pathout=$2
	if [ -d "$pathin" ]; then
		mkdir -p "$Upper/$pathout" "$Lower/$pathout"
	else
		[ "${pathout%/*}" != "$pathout" ] &&
			mkdir -p "$Upper/${pathout%/*}" "$Lower/${pathout%/*}"
		touch "$Upper/$pathout" "$Lower/$pathout"
	fi
	unset I
	I=$(indexer get "$pathin")
	[ "$I" ] || {
		indexer add "$pathin"
		I=$(indexer get "$pathin")
		[ "$I" ] || exit 1
		mkdir -p "$Storage/$I/up" "$Storage/$I/wrk"
		log added index "$I"
	}
	mount -t overlay overlay \
		-o "lowerdir=$(printf %s "$pathin"|sed 's/\\/\\\\/g;s/,/\\,/g;s/:/\\:/g')" \
		-o "upperdir=$Storage/$I/up,workdir=$Storage/$I/wrk" \
		"$Overlay/$pathout" &&
		log overlay "$pathin --> $Overlay/$pathout" &&
		[ "$pathout" ] && { # logic note
		[ "$pathin" != "$Lower/$pathout" ] && {
			mount -o bind,ro -- "$pathin" "$Lower/$pathout" &&
				log bound "$pathin --> $Lower/$pathout" || s=1
		}
		mount -o bind -- "$Storage/$I/up" "$Upper/$pathout" &&
			log bound "$Storage/$I/up --> $Upper/$pathout" || s=1
	} || s=1
	return $s
}

overbinder(){
	pathin=$(realpath --relative-base="$Path" -ez -- "$2"; echo x)
	pathin=${pathin%x}
	case $1 in
		add) # add basename of path inside the root of overlay
			pathout=${pathin##*/} ;;
		copy) # copy full path inside overlay
			pathout=$pathin ;;
		free) # mount path anywhere inside overlay
			pathout=$3
	esac
	pathout=$(realpath -mLsz -- "/$pathout"; echo x)
	pathout=${pathout%x}
	pathout=${pathout#/}
	overbind "$pathin" "$pathout"
}

creator(){
	if [ -e "$1" ] && ! ([ -d "$1" ] && ! find "$1" -maxdepth 1 -mindepth 1 | grep -q .); then
		log "'$1'" exists, moving into folder of same name
		tmp=$(mktemp -up "${1%/*}")
		mv -T "$1" "$tmp" || return 1
		mkdir "$1"
		mv -T "$tmp" "$1/${1##*/}" &&
			log moved "'$1'" to "'$1/${1##*/}'"
	else
		mkdir -p "$1"
	fi
	cd "$1" || exit
	mkdir "$Tree" "$Storage" "$Data"
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

mountplacer(){ # would be more efficient to mount overlays directly, reserved for the future
	[ -n "$2" ] && {
		one=$1
		shift
		commadd arr1 log running "'$*'"...
		commadd arr1 "$@"
		set -- "$one" "$@"
	}
	commadd arr1 overbinder add "$1"
	arr2=$arr2'until [ -z "$(lsof +D '"$(escapist "$1")"' 2>/dev/null)" ]; do true; done;'
	commadd arr2 mount --bind "$Overlay/${1##*/}" "$1"
}

autodiradd(){
	if [ "$autodir" ]; then
		autodir=.
	else
		autodir=$1
	fi
}

automount(){
	[ -d "$Data" ] || {
		log create a directory named "'$Data'"
		return 1
	}
	for low in "$Data"/* "$Data"/..[!$]* "$Data"/.[!.]*; do
		[ -e "$low" ] || continue
		[ "${low%.dwarfs}" != "$low" ] && {
			dwarfdir="$Path/$Lower/${low##*/}"
			dwarfdir="${dwarfdir%.*}"
			mkdir -p "$dwarfdir"
			dwarfs "$low" "$dwarfdir" &&
				printf %s\\0 "$dwarfdir" >> "$Mountlog" &&
				log dwarf mounted "$low" &&
				overbinder add "$dwarfdir" &&
				autodiradd "${dwarfdir##*/}"
			continue
		}
		overbinder add "$low" &&
			autodiradd "${low##*/}"
	done
}

exiter(){
	rm "$Mountlog"
}

Tree=tree
Storage=storage
Overlay=$Tree/overlay
Upper=$Tree/upper
Lower=$Tree/lower
Data=$Storage/data
Index=$Storage/index
Mountlog=$Storage/mountlog
export XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
global=$XDG_DATA_HOME/$programName

while true; do
	case $1 in
		-auto*)
			case $1 in
				-auto) commadd arr1 automount; autocd=true;;
				# mount things in $Data
				-automount) commadd arr1 automount;;
				# cd to either the only directory in overlay, the only automounted dir, or just overlay
				# (currently just for automount)
				-autocd) autocd=true;;
			esac
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
				*add) commadd arr1 overbinder add "$2";;
				*copy) commadd arr1 overbinder copy "$2";;
				*) commadd arr1 overbinder free "$2" "$3"; shift;;
			esac
			shift
			;;
		# -tmpfs)
		# 	commadd arr1 tmpfs "$2"
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
s=0; for d in "$Storage" "$Tree"; do
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

trap exiter EXIT
command mount -t tmpfs tmpfs "$Tree"
command mount --make-rslave "$Tree"
mkdir "$Lower" "$Upper" "$Overlay"

overbind "$Lower"

eval "$arr1"
# commands that need to run after mounting
eval "$arr2"

[ "$autocd" ] && {
	cd "$Overlay/$autodir" || exit
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
	tmp=$(mktemp)
	for low in "$Lower"/* "$Lower"/..[!$]* "$Lower"/.[!.]*; do
		[ -e "$low" ] || continue
		up="$Upper/${low##*/}"
		# [ -e "$up" ] || continue
		log looking for duplicates in "$up"
		find "$up" -depth -type f -print0 |
			cut -zb "$(printf %s "$Upper/" | wc -c)"- |
			awk -v "upper=$Upper" -v "lower=$Lower" '
				BEGIN{ RS="\0"; ORS="\0" }
				{ print upper $0 "\0" lower $0 }' |
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

{
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
umount -vl "$Tree"
