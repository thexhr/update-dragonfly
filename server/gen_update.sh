#!/bin/sh

# Base directory where the unpatched and the patched system is
BASE=/home/update


SUM=/sbin/sha1
ARCH=`uname -m`
VERSION=`uname -r | cut -d '-' -f 1`
LOC="${BASE}/${VERSION}/${ARCH}"
INDEX="${LOC}/INDEX"

if [ $# -le 2 ]; then
	echo "Usage: $0 <prefix> <old tree> <new tree>"
	exit 1
fi

prefix=$1
opath=$2
mpath=$3

# Keep track of the real pathes in the system
ropath=""
rmpath=""
otemp=$2

# Check if $LOC is available
startup()
{
	if [ ! -d $LOC ]; then
		echo "$LOC does not exists.  Create it"
		mkdir -p $LOC
		chmod -R 701 ${BASE}
	elif [ -d $LOC ]; then
		echo "$LOC exists.  Clean it"
		rm -rf -I $LOC/*	
		mkdir -p $LOC
	fi

}

# Create a binary/text diff, record it to the INDEX file and
# compute the checksums
create_patch()
{
	# Original file in the unmodified tree
	O=$1
	# Patched file in the modified tree
	N=$2
	# Checksum of the original file
	SUM_OLD=$3
	# Checksum of the patched file
	SUM_NEW=$4
	# Real path (without prefix and directory name) of the file
	RO=$5

	# Check the file type
	FTYPE=`stat -f "%ST" $prefix/${O}`
	# Convert all slashes (/) to underscores (_) to generate an unique
	# name for the diff
	NAME=`echo ${RO} | sed -e 's/\//_/g'`
	# Location of the diff
	DIFF="${LOC}/${NAME}.diff"
        
	case "${FTYPE}" in
                '*')
			# Executable, so use bsdiff (works with shell scripts
			# as well)
                        bsdiff $prefix/${O} $prefix/${N} ${DIFF}
			if [ ! -e ${DIFF} ]; then
				echo "Creating ${DIFF} failed.  Abort"
				exit $?
			fi
			SUM_DIFF="`${SUM} -q ${DIFF}`"
			# Generate INDEX entry
			echo "${RO}#`basename ${DIFF}`#${SUM_DIFF}#${SUM_OLD}#${SUM_NEW}"\
				 >> ${INDEX}
                ;;
		'@')
			echo "No symlink support"
		;;
                *)
			# Normal file
			diff -uN $prefix/${O} $prefix/${N} > ${DIFF}
			if [ ! -e ${DIFF} ]; then
				echo "Creating ${DIFF} failed.  Abort"
				exit $?
			fi
			SUM_DIFF="`${SUM} -q ${DIFF}`"
			# Generate INDEX entry
			echo "${RO}#`basename ${DIFF}`#${SUM_DIFF}#${SUM_OLD}#${SUM_NEW}"\
				 >> ${INDEX}
                ;;
        esac

}

dir()
{
	#echo "Start with $1"
	cd $1 #2> /dev/null
       	 
	for i in `ls`; do
		# We found a directory, so good deeper into the rabbit hole
                if [ -d $i -a ! -h $i ]; then
			# Keep track of the pathes
			ropath="$ropath/$i"
			rmpath="$rmpath/$i"
			opath="$opath/$i"
			mpath="$mpath/$i"
			# Start recursion
               		dir $i
                fi
		# Compare two files
		if [ -f "$prefix/$opath/$i" ]; then
			if [ -f "$prefix/$mpath/$i" ]; then
				echo "Check $opath/$i and $mpath/$i"
				OSUM=`${SUM} -q $prefix/$opath/$i`
				NSUM=`${SUM} -q $prefix/$mpath/$i`
				# Checksum different, so generate a patch
				if [ "${OSUM}" != "${NSUM}" ]; then
					echo -n "NOTE: $ropath/$i and "
					echo "$rmpath/$i differ.  Create patch"
					create_patch "$opath/$i" "$mpath/$i" "${OSUM}" "${NSUM}" "${ropath}/$i"
				fi
			# XXX What to do now?
			else
				echo -n "WARNING: $prefix/$opath/$i exists "
				echo "whether $prefix/$mpath/$i not"
			fi
		fi
        done
        # Descend
        cd ..
	# Keep track of the pathes
	opath=`dirname $opath`
	mpath=`dirname $mpath`
	# We reached /
	if [ $opath = $otemp ]; then
		ropath=""
		rmpath=""
	# if opath = "." we are in $prefix, so skip dirname
	elif [ $opath != "." ]; then
		ropath=`dirname $ropath`
		rmpath=`dirname $rmpath`
	fi
}

startup
cd "$prefix/$opath"
#dir "$prefix/$opath"
dir "."

# Generate the INDEX hash
if [ ! -e ${INDEX} ]; then
	echo "INDEX file not found."
else
	${SUM} -q ${INDEX} > ${INDEX}.sha1
fi

exit $?

