#!/bin/sh

# todo:
# 	-recursive mounts
# 	-dedupe things besides files and dirs (symlinks, sockets...)
# 	-clean unused indexes
# 	-non-command mode, where you are already privileged and can make overlays freely without entering
# 	a new shell or running a new command, and are free to re-run overlay.sh with some -unmount
# 	argument to undo the damage. mountlog may be harder to handle
# 	-less verbose logging
# 	-try to protect cwd from being destroyed by a new mount

[ "$1" = 1 ] && shift ||
	[ "$(id -u)" = 0 ] ||
	capsh --current | grep -qFi cap_sys_admin ||
	exec unshare -cm --keep-caps -- "$0" 1 "$@"

programName=${0##*/}

log(){
	printf '%s\n' "$programName: $*"
}

mount(){
	command mount "$@" && {
		shift $(($# - 1))
		printf '%s\0' "$1" >>"$Mountlog"
	}
}

# makeIndex and getIndex take storage dir and then pairs of arguments, $2 = key, $3 = value, and repeat.
# this format is used to identify each index.
makeIndex(){
	i=$1
	shift
	mkdir -p "$i"/data "$i"/work
	writeId "$i/id" "$@"
	log added index: "$i"
}

writeId(){
	id=$1
	shift
	printf '%s\0\n' "$@" > "$id"
}

getIndex(){
	[ $# -le 1 ] && exit
	dir=$1
	shift
	getAllIndexes "$dir" | while read -r index; do
		parseId "$index/id" "$@" && printf %s "$index" && return
	done
}

parseId(){
	id=$1
	shift
	# returns 1 if an exact match isn't found
	(printf '%s\0\n' "$@"; cat "$id") | awk '
	BEGIN { RS="\0\n"; ORS="\0"; hit=0; begin=1; }
	{
		if (begin){
			if (NR % 2 == 1){
				k=$0;
			} else {
				map[k] = $0;
				if (NR == '"$#"'){
					begin=0;
					NR=0;
				}
			}
		} else if (NR % 2 == 1){
				k=$0;
		} else {
			for (key in map){
				if (k == key){
					if ($0 != map[k]){
						exit 1; # if any key check fails
					}
					hit=1;
					break;
				}
			}
			if (!hit){
				exit 1; # if any key does not exist
			}
			hit=0
		}
	}
	END { if (NR != '"$#"') exit 1; }
	'
	return $?
}

# takes storage location
# returns a path that doesn't exist yet
getNextIndex(){
	printf %s "$1/"
	getAllIndexes "$1" | awk '
		BEGIN{i=0;FS="/"; OFS="/"}
		{ if ($NF != i) exit; i++; }
		END{print i}'
}

getAllIndexes(){
	find "$1" -maxdepth 1 -mindepth 1 -type d -regex '.*/[0-9]+'
}

# store arrays as escaped single quoted arguments
escapist(){
	if [ $# -eq 0 ]; then cat; else printf "%s\0" "$@"; fi |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

escapeOverlayOpts(){
	fullpath full "$1" | sed 's/\\/\\\\/g; s/,/\\,/g; s/:/\\:/g; s/"/\\"/g'
}

fullpath(){
	arg=
	case $1 in
		# only relative if given path is relative
		rel) [ "${2#/}" = "$2" ] && arg=--relative-to=. ;;
		base) arg=--relative-base=. ;;
		full) arg= ;;
	esac
	realpath -mz $arg -- "$2" | tr -d \\0
	printf /
}

# takes whether to bind outside of tree, then source, sink, and key-value pairs.
# if the pairs show a match, mount with the existing index.
# otherwise, make a new index with those pairs.
placer(){
	s=0
	bind=$1
	source=$2
	sink=$3
	shift 3
	mkdir -p "$Tree/$Lower/$sink"
	unset Index
	Index=$(getIndex "$Storage" "$@")
	[ "$Index" ] || {
		Index=$(getNextIndex "$Storage")
		makeIndex "$Index" "$@"
	}

	[ "$source" != "$Tree/$Lower/$sink" ] && {
		mount -o bind,ro -- "$source" "$Tree/$Lower/$sink" &&
			log bound "$source --> $Lower/${sink#/}" || s=1
		mount -o bind -- "$Index/data" "$Tree/$Upper/$sink" &&
			log bound "$Index/data --> $Upper/${sink#/}" || s=1
	}

	lowerdir=$(escapeOverlayOpts "$source")
	Index=$(escapeOverlayOpts "$Index")
	mount -t overlay overlay -o "${overopts:-userxattr}" \
		-o "lowerdir=$lowerdir" \
		-o "upperdir=$Index/data,workdir=$Index/work" \
		"$Overlay/$sink" && {
			log overlayed "$source --> $Overlay/$sink"
			[ "$bind" = 1 ] && [ "$sink" ] && {
				printf %s\\0 "$Overlay/$sink" "$sink" >>"$Bindlist"
			}
		} || s=1
	return $s
}

makeStorageCwd(){
	cwd=$(realpath -z .; echo x)
	cwd=${cwd%x}
	# hash of cwd encoded in base64url
	out="$1/by-cwd/$(printf %s "$cwd" | openssl dgst -sha1 -binary | openssl enc -base64 | tr +/ -_ | tr -d =)"
	makeDir "$out" || exit
	printf %s "$cwd" >"$out"/name
	printf %s "$out"
}

makeDir(){
	dir=$1
	[ -e "$dir" ] && [ ! -d "$dir" ] && log "'$dir' isn't a directory." && return 1
	mkdir -pv "$dir" >&2
}

# takes opts, then source, then sink
# outputs \0 delimited key-value pairs
placeOptsParse()(
	opts=$1
	source=$2
	sink=$3
	echo "$opts" | grep -qF i && printf %s\\0 source "$source"
	echo "$opts" | grep -qF o && printf %s\\0 sink "$sink"
)

superUmount(){
	mnt=$1
	until err=$(umount -vr -- "$mnt" 2>&1) && printf %s\\n "$err"; do
		pidlist=$(fuser -Mm "$mnt" 2>/dev/null) || {
			mountpoint -q "$mnt" || break
			# if there are no processes but point is still mounted, lazy umount
			umount -l "$mnt"
			log lazily unmounted "'$mnt'"
			break
		}
		if [ "$pidlist" != "$prevlist" ]; then
			echo "$err"
			# ps -p "$(echo "$pidlist" | sed 's/\s\+/,/g; s/^,\+//')"
			fuser -vmM "$mnt"
			change=1
		elif [ "$change" -eq 1 ]; then
			log waiting...
			change=0
		fi
		prevlist=$pidlist
	
		sleep 1
	done
}

umounter(){
	n=$(tr -cd '\0' <"$Mountlog" | wc -c) 2>/dev/null
	for i in $(seq 1 "$n" | tac); do
		line=$(sed -zn "$i"p <"$Mountlog"; echo x)
		superUmount "${line%x}"
	done

	umount -vl "$Tree"
}

exiter(){
	umounter
	[ "$Mountlog" ] && rm "$Mountlog"
	[ "$arglist" ] && rm "$arglist"
	[ "$Bindlist" ] && rm "$Bindlist"
}

# for use in flag parsing
pass(){
	[ "$Pass" -eq "$1" ] && return 0
	shift
	[ $# -lt $shift ] && return 1
	i=0
	while [ $i -lt "$shift" ]; do
		printf %s\\0 "$1" >> "$arglist"
		i=$((i + 1))
		shift
	done
	return 1
}

# command running section
[ "$1" = 2 ] && {
	Bindlist=$2
	binder(){
		while [ $# -gt 1 ]; do
			command mount -o bind -- "$1" "$2"
			log bound "$1 --> $2"
			shift 2
		done
	}
	eval binder "$(escapist <"$Bindlist")"
	cd . # in case you just replaced cwd

	shift 2
	if [ $# -ge 1 ]; then
		exec "$@"
	elif [ -t 0 ]; then
		log entering shell...
		exec "$SHELL"
	else
		log provide a command.
		exit 1
	fi
}

arglist=$(mktemp)
Bindlist=$(mktemp)

trap exiter EXIT

for Pass in 1 2; do
	[ "$Pass" -gt 1 ] && eval set -- "$(escapist <"$arglist")" '"$@"'
	: > "$arglist"
	while true; do
		shift=1
		case $1 in
			-d|-dedupe)
				dedupe=true
				;;
			-i|-interactive)
				interactive=true
				;;
			-o|-overlay)
				shift=2
				overlay=$(fullpath full "$2")
				makeDir "$overlay" || exit
				;;
			-t|-tree)
				shift=2
				Tree=$(fullpath full "$2")
				Tree=${Tree%/}
				;;
			-g|-global)
				shift=2
				Global=$(fullpath full "$2")
				makeDir "$Global" || exit
				;;
			-s|-storage)
				shift=2
				Storage=$(fullpath full "$2")
				Storage=${Storage%/}
				;;
			-id)
				shift=2
				Storage="$Global/by-name/$2"
				;;
			-k|key)
				shift=3
				pass 2 "$@" && keys=$keys$(escapist "$2" "$3")
				;;
			-opts)
				shift=2
				Opts=$2
				;;
			-N|-neverbind)
				BindNever=0
				;;
			-n|-nobind)
				Bind=0
				;;
			-p*|-r*) # -place, -replace
				pass 2 && {
					opts=${Opts:-"$(echo "$1" | cut -sd, -f2)"}
					source=$(fullpath base "$2")
					sourceKey=$(fullpath rel "$2")
				}
				case $1 in
					-p*)
						shift=3
						pass 2 "$@" && {
							sink=$(fullpath base "$3")
							sinkKey=$(fullpath rel "$3")
							opts=${opts:-"o"} # default
						}
						;;
					-r*)
						shift=2
						pass 2 "$@" && {
							sink=$source
							sinkKey=$sourceKey
							opts=${opts:-"io"} # default
						}
						;;
				esac
				pass 2 && {
					Bind=${Bind:-"$BindNever"}
					keys=${keys:-"$(placeOptsParse "$opts" "$sourceKey" "$sinkKey" | escapist)"}
					eval 'placer "${Bind:-1}" "$source" "$sink"' "$keys" || exit
					keys=''
					Bind=''
				}
				;;
			-su)
				overopts=xino=auto,uuid=auto,metacopy=on
				;;
			--)
				shift
				break;;
			*)
				break;;
		esac
		shift $shift
	done
	[ $Pass -eq 1 ] && {
		XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
		Global=${Global:-"${GLOBAL:-"$XDG_DATA_HOME/$programName"}"}
		Storage=${Storage:-"$(makeStorageCwd "$Global")"}
		Tree=${Tree:-"$Storage/tree"}
		mkdir -p "$Storage" "$Tree"
		Mountlog=$Storage/mountlog
		touch "$Mountlog"
		Upper=upper
		Lower=lower
		Overlay=$Tree/overlay

		grep -zq . "$Mountlog" && {
			log "$Mountlog" is not empty, indicating bad unmounting. Investigate and remove the file.
			unset Mountlog
			exit 1
		}

		command mount -t tmpfs tmpfs "$Tree"
		command mount --make-rslave "$Tree"
		mkdir "$Tree/$Lower" "$Tree/$Upper" "$Overlay"
		mount -o bind,ro -- "$Tree/$Lower" "$Tree/$Upper"
		placer 0 "$Tree/$Lower/" "" overlay true
	}
done
rm "$arglist"
unset arglist

[ "$overlay" ] && printf %s\\0 "$Overlay" "$overlay" >>"$Bindlist"

log entering new mount namespace...
trap 'log INT recieved' INT # TODO: signal handling
unshare -m --propagation unchanged -- "$0" 2 "$Bindlist" "$@"
echo
log exiting...
trap - INT


dedupeFind(){
	find "$Tree/$Upper" -mindepth 1 -depth "$@" -print0 |
		(printf %s\\0 "$Tree"; cut -zb "$(printf %s "$Tree/$Upper/" | wc -c)"-) |
		awk -v "upper=${Upper##*/}" -v "lower=${Lower##*/}" '
			BEGIN { RS="\0"; ORS="\0" }
			{
				if (NR == 1) tree = $0;
				else print tree "/" upper $0 ORS tree "/" lower $0
			}
		' | xargs -0 sh -c '
			until [ $# -lt 2 ]; do
				[ -e "$2" ] && printf %s\\0 "$1" "$2"
				shift 2
			done
		' sh
}

[ "$dedupe" ] && {
	tmp=$(mktemp)
	log looking for duplicates in "$Tree/$Upper"
	# unshare creates a new pid namespace so that pid collisions are impossible
	dedupeFind -type f | unshare -rmpf --mount-proc -- xargs -0 -n 64 -- sh -c '
			until [ $# -lt 2 ]; do
				(cmp -s -- "$1" "$2" && { waitpid "$pid" 2>/dev/null; printf "%s\0" "$1"; } ) & pid=$!
				shift 2
			done
			wait
		' sh | tee "$tmp" | tr '\0' '\n'
	grep -qz . <"$tmp" && {
		[ "$interactive" ] && {
			printf "delete these files? y/N: "
			read -r line
		} || line=y
		case $line in y|Y)
			xargs -0 rm -- <"$tmp"
			dedupeFind -type d | awk 'BEGIN{RS="\0"; ORS="\0";} {if (NR % 2 == 1) print $0;}' |
			xargs -0 rmdir --ignore-fail-on-non-empty --
			log removed duplicates
			;;
		esac
	}
	rm "$tmp"
}
