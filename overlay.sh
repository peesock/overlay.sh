#!/bin/sh

# todo:
# 	recursive mounts
# 	allow mixing of -overlay and not
# 	dedupe things besides files and dirs (symlinks, sockets...)

# notes:
# 	utils-linux BUG! your source dir cannot have an odd number of double quotes in the path.

# 	Without using -su, as root, in the root namespace, moving files from lowerdir will *copy*
# 	them, using disk space, among other overlayfs downsides.

# 	Putting Storage on a fuse mount will fail if it was mounted in a different user namespace. To
# 	avoid using root, you can run `unshare -cm --keep-caps "$SHELL"` to drop into a privileged
# 	namespace before mounting fuse, and this script will detect those capabilities and keep you in
# 	the same namespace.

# 	Socket files don't work until all prior connections are terminated.

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

# store arguments as a command inside an eval-able variable named $1
commadd(){
	v=$1
	shift
	eval "$v=\$$v"'"$(escapist "$@");"'
}

# takes source, sink, then key-value pairs.
# if the pairs show a match, mount with the existing index.
# otherwise, make a new index with those pairs.
placer(){
	s=0
	source=$1
	sink=$2
	shift 2
	mkdir -p "$Tree/$Upper/$sink" "$Tree/$Lower/$sink"
	unset I
	I=$(getIndex "$Storage" "$@")
	[ "$I" ] || {
		I=$(getNextIndex "$Storage")
		makeIndex "$I" "$@"
	}
	lowerdir=$(printf %s "$source" | sed 's/\\/\\\\/g; s/,/\\,/g; s/:/\\:/g; s/"/\\"/g'; echo x)
	lowerdir=${lowerdir%x}

	[ "$source" != "$Tree/$Lower/$sink" ] && {
		mount -o bind,ro -- "$source" "$Tree/$Lower/$sink" &&
			log bound "$source --> $Lower/${sink#/}" || s=1
		mount -o bind -- "$I/data" "$Tree/$Upper/$sink" &&
			log bound "$I/data --> $Upper/${sink#/}" || s=1
	}
	mount -t overlay overlay -o "${overopts:-userxattr}" \
		-o "lowerdir=$lowerdir" \
		-o "upperdir=$I/data,workdir=$I/work" \
		"$Root$sink" && log overlayed "$source --> $Root$sink" || s=1
	return $s
}

exiter(){
	[ -e "$Mountlog" ] && rm "$Mountlog"
}

makeStorageCwd(){
	cwd=$(realpath -z .; echo x)
	cwd=${cwd%x}
	# base64 of a hash but / is replaced with _
	out="$1/by-cwd/$(printf %s "$cwd" | openssl dgst -sha1 -binary | openssl enc -base64 | tr / _)"
	makeDir "$out" || exit
	printf %s "$cwd" >"$out"/name
	printf %s "$out"
}

makeDir(){
	dir=$1
	[ -e "$dir" ] && [ ! -d "$dir" ] && log "'$dir' isn't a directory." && return 1
	mkdir -pv "$dir" >&2
}

fullpath(){
	case $1 in
		full) args='-mz' ;;
		relative) args='-mz --relative-base=.' ;;
	esac
	realpath $args -- "$2" | tr -d \\0
	printf /
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

while true; do
	case $1 in
		-d|-dedupe)
			dedupe=true
			;;
		-i|-interactive)
			interactive=true
			;;
		-root)
			Root=$(fullpath full "$2")
			makeDir "$Root" || exit
			shift
			;;
		-tree)
			Tree=$(fullpath full "$2")
			Tree=${Tree%/}
			shift
			;;
		-global)
			Global=$(fullpath full "$2")
			makeDir "$Global" || exit
			shift
			;;
		-storage)
			Storage=$(fullpath full "$2")
			Storage=${Storage%/}
			shift
			;;
		-id)
			Storage="$Global/by-name/$2"
			shift
			;;
		-key)
			keys=$keys$(escapist "$2" "$3")
			shift 2
			;;
		-opts)
			Opts=$2
			shift
			;;
		-relative)
			Relative=true
			;;
		-place*|-replace*)
			opts=${Opts:-"$(echo "$1" | cut -sd, -f2)"}
			[ "$Relative" ] && arg=relative || arg=full
			source=$(fullpath $arg "$2")
			case $1 in
				-place*)
					sink=$(fullpath $arg "$3")
					opts=${opts:-"o"} # default
					shift
					;;
				-replace*)
					sink=$source
					opts=${opts:-"io"} # default
					;;
			esac
			[ "$Root" ] && sink=${sink#/} # yucky...
			keys=${keys:-"$(placeOptsParse "$opts" "$source" "$sink" | escapist)"}
			eval 'commadd arr1 placer "$source" "$sink"' "$keys"
			keys=''
			shift
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
	shift
done

XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
Global=${Global:-"${GLOBAL:-"$XDG_DATA_HOME/$programName"}"}
Storage=${Storage:-"$(makeStorageCwd "$Global")"}
Tree=${Tree:-"$Storage/tree"}
mkdir -p "$Storage" "$Tree"
Mountlog=$Storage/mountlog
Upper=upper
Lower=lower

grep -zq . "$Mountlog" 2>/dev/null && {
	log "$Mountlog" is not empty, indicating bad unmounting. Investigate and remove the file.
	exit 1
}

trap exiter EXIT
command mount -t tmpfs tmpfs "$Tree"
command mount --make-rslave "$Tree"
mkdir "$Tree/$Lower" "$Tree/$Upper"

[ "$Root" ] && {
	placer "$Tree/$Lower/" "" root true
}

eval "$arr1"

trap 'log INT recieved' INT # TODO: signal handling
if [ $# -ge 1 ]; then
	"$@"
elif [ -t 1 ]; then
	log entering shell...
	"$SHELL"
else
	log provide a command.
	exit 1
fi
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

{
	n=$(tr -cd '\0' <"$Mountlog" | wc -c) 2>/dev/null
	[ "$n" ] || return
	for i in $(seq 1 "$n" | tac); do
		line=$(sed -zn "$i"p <"$Mountlog"; echo x)
		superUmount "${line%x}"
	done
}

umount -vl "$Tree"
