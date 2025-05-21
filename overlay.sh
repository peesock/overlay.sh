#!/bin/sh
set -x

# todo:
# 	recursive overmounts
# 	remove specific code. add some API to replace it
# 	allow files in $Data
# 	allow files in storage/i
# 	might want to store index locations based on pathout, not pathin. ponder...
# 	ponder a config file, store mount info for a certain "instance" forever, change mounting options to config changing options. that way you can also script things like proton and wine manually without needing to store a script file for the massive command line.

# notes:
# 	utils-linux BUG! your lowerdir (-mnt* options) cannot have an odd number of double quotes in the path.

# 	Putting $Storage on a fuse mount will fail if it was mounted in a different user namespace.
# 	To avoid using root, you can run `unshare -cm --keep-caps "$SHELL"` to drop into a privileged
# 	namespace before mounting fuse, and this script should detect those needed capabilities and
# 	keep you in the same namespace.

# 	Socket files don't work until all prior connections are terminated.

# 	Without using -root, as root, in the root namespace, moving files from lowerdir will *copy* them,
# 	using disk space, among other overlayfs downsides.

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

# writeIndex and getIndex take one file and then pairs of arguments, $2 = label, $3 = data, and repeat.
# this format is used to identify each index.
writeIndex(){
	i=$1
	shift
	mkdir -p "$i"/data "$i"/work
	writeId "$i/id" "$@"
	log added "$i"
}

getIndex(){
	[ $# -le 1 ] && exit
	dir=$1
	shift
	unset winner
	args=$(escapist "$@")
	winner=$(getAllIndexes "$dir" | while read -r index; do
		eval set -- "$args"
		while [ $# -gt 0 ]; do
			value=''
			value=$(parseId "$index/id" "$1"; echo x)
			[ "$value" = "$2"x ] || continue 2
			shift 2
		done
		printf %s "$index"
		break
	done)
	printf %s "$winner"
}

writeId(){
	id=$1
	shift
	printf '%s\0\n' "$@" > "$id"
}

parseId(){
	id=$1
	shift
	# for keys, awk will spit out \0 delimited values.
	# if there are missing keys, do not output anything.
	# in the future, have awk validate as well as parse.
	keylist=$(printf '%s,' "$@")
	keylist=${keylist%?}
	awk '
	BEGIN {
		RS="\0\n"; ORS="\0"; set="";
		split("'"$keylist"'", keylist, ",");
		for (key in keylist)
			map[keylist[key]] = "";
	}
	{
		if (NR % 2 == 1){
			for (key in keylist)
				if (keylist[key] == $0){
					set = keylist[key];
					break;
				}
		} else {
			if (set != ""){
				map[set] = $0;
				set = "";
			}
		}
	}
	END {
		for (key in map)
			if (map[key] == "") exit;
		for (key in map)
			print map[key];
	}
	' < "$id"
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

escapist(){ # to store arrays as escaped single quoted arguments
	if [ $# -eq 0 ]; then cat; else printf "%s\0" "$@"; fi |
		sed -z 's/'\''/'\''\\'\'\''/g; s/\(.*\)/'\''\1'\''/g' | tr '\0' ' '
}

commadd(){
	v=$1
	shift
	eval "$v=\$$v"'"$(escapist "$@");"'
}

# log beginning antics
# set -x
# "$@"
# exit

# $1 is the input path, remains as-is
# $2 is the output, relative to overlay
# `overbind /home/balls /buh/muh` mounts /home/balls to $Overlay/buh/muh.
placer(){
	s=0
	dir=$1
	source=$2
	sink=$3
	shift 3
	if [ -d "$source" ]; then
		mkdir -p "$Upper/$sink" "$Lower/$sink"
	# else # does not work
	# 	[ "${pathout%/*}" != "$pathout" ] &&
	# 		mkdir -p "$Upper/${pathout%/*}" "$Lower/${pathout%/*}"
	# 	touch "$Upper/$pathout" "$Lower/$pathout"
	fi
	unset I
	I=$(getIndex "$dir" "$@")
	[ "$I" ] || {
		I=$(getNextIndex "$dir")
		writeIndex "$I" "$@"
	}
	mount -t overlay overlay -o "${overopts:-userxattr}" \
		-o "lowerdir=$(printf %s "$source"|sed 's/\\/\\\\/g; s/,/\\,/g; s/:/\\:/g; s/"/\\"/g')" \
		-o "upperdir=$I/data,workdir=$I/work" \
		"$sink" &&
		log overlay "$source --> $Overlay/$sink" # &&
	# 	[ "$sink" ] && { # logic note
	# 	[ "$source" != "$Lower/$sink" ] && {
	# 		mount -o bind,ro -- "$source" "$Lower/$sink" &&
	# 			log bound "$source --> $Lower/$sink" || s=1
	# 	}
	# 	mount -o bind -- "$I/data" "$Upper/$sink" &&
	# 		log bound "$I/data --> $Upper/$sink" || s=1
	# } || s=1
	# return $s
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

Tree=tree
Storage=storage
Overlay=$Tree/overlay
Upper=$Tree/upper
Lower=$Tree/lower
Mountlog=$Storage/mountlog
export XDG_DATA_HOME="${XDG_DATA_HOME-"$HOME/.local/share"}"
global=$XDG_DATA_HOME/$programName

while true; do
	case $1 in
		-d|-dedupe) # compare lowerdirs with corresponding overlay dirs and remove dupes
			dedupe=true
			;;
		-i|-interactive) # prompt before deleting
			interactive=true
			;;
		-relative)
			[ -e "$2" ] && [ ! -d "$2" ] && log Bad relative dir && exit 1
			mkdir -p "$2"
			Relative=$2
			shift
			;;
		-opts)
			true # default opts for all placements
			;;
		-place*|-replace*)
			opts=${Opts:-"$(echo "$1" | cut -sd, -f2)"}
			case $1 in
				-place*)
					source=$2
					sink=$3
					opts=${opts:-"o"} # default
					shift 2
					;;
				-replace*)
					source=$2
					sink=$source
					opts=${opts:-"io"} # default
					shift
					;;
			esac
			eval 'commadd arr1 placer "$Storage" "$source" "$sink"' "$(placerOptsParse "$opts" "$source" "$sink" | escapist)"
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

grep -zq . "$Mountlog" 2>/dev/null && {
	log "$Path/$Mountlog" is not empty, indicating bad unmounting. Investigate and/or remove the file.
	exit 1
}

trap exiter EXIT
# command mount -t tmpfs tmpfs "$Tree"
# command mount --make-rslave "$Tree"
# mkdir "$Lower" "$Upper" "$Overlay"
#
# overbind "$Lower"

eval "$arr1"
# commands that need to run after mounting
# eval "$arr2"

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

# [ "$dedupe" ] && {
# 	tmp=$(mktemp)
# 	for low in "$Lower"/* "$Lower"/..[!$]* "$Lower"/.[!.]*; do
# 		[ -e "$low" ] || continue
# 		up="$Upper/${low##*/}"
# 		# [ -e "$up" ] || continue
# 		log looking for duplicates in "$up"
# 		find "$up" -depth -type f -print0 |
# 			cut -zb "$(printf %s "$Upper/" | wc -c)"- |
# 			awk -v "upper=$Upper" -v "lower=$Lower" '
# 				BEGIN{ RS="\0"; ORS="\0" }
# 				{ print upper $0 "\0" lower $0 }' |
# 			unshare -rmpf --mount-proc -- xargs -0 -n 64 -- sh -c '
# 				until [ $# -le 0 ]; do
# 					[ -e "$2" ] &&
# 						(cmp -s -- "$1" "$2" && { waitpid "$pid" 2>/dev/null; printf "%s\0" "$1"; } ) & pid=$!
# 					shift 2
# 				done
# 				wait
# 			' sh | tee "$tmp" | tr '\0' '\n'
# 			# unshare creates a new pid namespace so that pid collisions are impossible
# 		grep -qz . <"$tmp" && {
# 			[ "$interactive" ] && {
# 				printf "delete these files? y/N: "
# 				read -r line
# 			} || line=y
# 			case $line in y|Y)
# 				xargs -0 rm -- <"$tmp"
# 				# todo: better rmdir
# 				xargs -0 dirname -z -- <"$tmp" | uniq -z | xargs -0 rmdir -p --ignore-fail-on-non-empty -- 2>/dev/null
# 				log removed duplicates
# 				;;
# 			esac
# 		}
# 	done
# 	rm "$tmp"
# }
#
# {
# 	n=$(tr -cd '\0' <"$Mountlog" | wc -c)
# 	[ "$n" ] || return
# 	for i in $(seq 1 "$n" | tac); do
# 		line=$(sed -zn "$i"p <"$Mountlog")
# 		umount -vr -- "$line"
# 	done
# }
# until err=$(umount "$Overlay" 2>&1) && log unmounted overlayfs; do
# 	pidlist=$(fuser -Mm "$Overlay" 2>/dev/null) || {
# 		mountpoint -q "$Overlay" || break
# 		# if there are no processes but overlay is still mounted, lazy umount
# 		umount -l "$Overlay"
# 		log lazily unmounted overlayfs
# 		break
# 	}
# 	if [ "$pidlist" != "$prevlist" ]; then
# 		echo "$err"
# 		# ps -p "$(echo "$pidlist" | sed 's/\s\+/,/g; s/^,\+//')"
# 		fuser -vmM "$Overlay"
# 		change=1
# 	elif [ "$change" -eq 1 ]; then
# 		log waiting...
# 		change=0
# 	fi
# 	prevlist=$pidlist
#
# 	sleep 1
# done
# umount -vl "$Tree"
