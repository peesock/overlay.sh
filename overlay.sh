#!/bin/sh

# todo:
# 	recursive mounts
# 	special keys like "uuid", or custom ones
# 	allow mixing of -overlay and not

# notes:
# 	utils-linux BUG! your source dir cannot have an odd number of double quotes in the path.

# 	Without using -root, as root, in the root namespace, moving files from lowerdir will *copy*
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

# writeIndex and getIndex take one dir and then pairs of arguments, $2 = key, $3 = value, and repeat.
# this format is used to identify each index.
writeIndex(){
	i=$1
	shift
	mkdir -p "$i"/data "$i"/work
	writeId "$i/id" "$@"
	log added "$i"
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

# $1 = storage location
# returns a number, that doesn't exist yet
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
	mkdir -p "$Upper/$sink" "$Lower/$sink"
	unset I
	I=$(getIndex "$Storage" "$@")
	[ "$I" ] || {
		I=$(getNextIndex "$Storage")
		writeIndex "$I" "$@"
	}
	lowerdir=$(printf %s "$source" | sed 's/\\/\\\\/g; s/,/\\,/g; s/:/\\:/g; s/"/\\"/g'; echo x)
	lowerdir=${lowerdir%x}
	mount -t overlay overlay -o "${overopts:-userxattr}" \
		-o "lowerdir=$lowerdir" \
		-o "upperdir=$I/data,workdir=$I/work" \
		"$Overlay$sink" && log overlayed "$source --> $Overlay$sink" && {
			[ "$source" != "$Lower/$sink" ] && {
				mount -o bind,ro -- "$source" "$Lower/$sink" &&
					log bound "$source --> $Lower/$sink" || s=1
			}
		}
		mount -o bind -- "$I/data" "$Upper/$sink" &&
			log bound "$I/data --> $Upper/$sink" || s=1
	return $s
}

exiter(){
	[ -e "$Mountlog" ] && rm "$Mountlog"
}

# takes opts, then source, then sink
# outputs \0 delimited key-value pairs
placerOptsParse()(
	opts=$1
	source=$2
	sink=$3
	echo "$opts" | grep -qF i && printf %s\\0 source "$source"
	echo "$opts" | grep -qF o && printf %s\\0 sink "$sink"
)

makeStorageCwd(){
	cwd=$(realpath .)
	out="$1/by-cwd/$(printf %s "$cwd" | sha256sum | awk '{print $1}')"
	makeDir "$out"
	printf %s "$cwd" >"$out"/name
	printf %s "$out"
}

makeDir(){
	dir=$1
	[ -e "$dir" ] && [ ! -d "$dir" ] && log "'$dir' isn't a directory." && return 1
	mkdir -p "$dir"
}

fullpath(){
	realpath -msz --relative-base=. -- "$1" | tr -d '\0'; printf /
}

place(){
	opts=${Opts:-"$(echo "$1" | cut -sd, -f2)"}
	source=$(fullpath "$2")
	case $# in
		3) # place
			sink=$(fullpath "$3")
			opts=${opts:-"o"} # default
			shift
			;;
		2) # replace
			sink=$source
			opts=${opts:-"io"} # default
			;;
	esac
	[ "$Overlay" ] && sink=${sink#/}
	eval 'placer "$source" "$sink"' "$(placerOptsParse "$opts" "$source" "$sink" | escapist)"
}

while true; do
	case $1 in
		-d|-dedupe)
			dedupe=true
			;;
		-i|-interactive)
			interactive=true
			;;
		-overlay)
			makeDir "$2" || exit
			Overlay=$(fullpath "$2")
			shift
			;;
		-tree)
			makeDir "$2" || exit
			Tree=$2
			shift
			;;
		-global)
			makeDir "$2" || exit
			GlobalStorage=$2
			shift
			;;
		-id)
			Storage="$GlobalStorage/by-name/$2"
			shift
			;;
		-storage)
			makeDir "$2" || exit
			Storage=$2
			shift
			;;
		-opts)
			Opts=$2
			shift
			;;
		-place*)
			commadd arr1 place "$1" "$2" "$3"
			shift 2
			;;
		-replace*)
			commadd arr1 place "$1" "$2" "$2"
			shift
			;;
		-root)
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
GlobalStorage=${GlobalStorage:-"${GLOBAL:-"$XDG_DATA_HOME/$programName"}"}
Storage=${Storage:-"$(makeStorageCwd "$GlobalStorage")"}
Tree=${Tree:-"$Storage/tree"}
mkdir -p "$Storage" "$Tree"
Mountlog=$Storage/mountlog
Upper=$Tree/upper
Lower=$Tree/lower

grep -zq . "$Mountlog" 2>/dev/null && {
	log "$Mountlog" is not empty, indicating bad unmounting. Investigate and remove the file.
	exit 1
}

trap exiter EXIT
command mount -t tmpfs tmpfs "$Tree"
command mount --make-rslave "$Tree"
mkdir "$Lower" "$Upper"

[ "$Overlay" ] && {
	placer "$Lower/" "" relative true
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
