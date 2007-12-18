#!/bin/sh

# Base directory where the unpatched and the patched system is
#BASE=/usr/scratch/update-dragonfly
BASE=/home/update/up


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

# Copy the complete file to the update directory.  This is usefull if the user
# has a modified world and agrees to get his files updates
copy_file()
{
	# $1 = Original file in the unmodified tree
	# $2 = Modified file in the modified tree
	# $3 = Checksum of the original file
	# $4 = Checksum of the modified file
	# $5 = Real path (without prefix and directory name) of the file

	FLOC=${LOC}/`echo ${5} | sed -e 's/\//_/g'`

	echo "Copy $1 to $FLOC"
	
	case "`stat -f "%ST" $prefix/${1}`" in
		'*')	
			cp $prefix/${2} ${FLOC}	
			#echo "${5}#FILE#FILE#${3}#${4}"\
			#	>> ${INDEX}
			;;
		'@')
			echo "Symlink.  Skip it"
			;;
	esac
}

# Create a binary/text diff, record it to the INDEX file and
# compute the checksums
create_patch()
{
	# $1 = Original file in the unmodified tree
	# $2 = Modified file in the modified tree
	# $3 = Checksum of the original file
	# $4 = Checksum of the modified file
	# $5 = Real path (without prefix and directory name) of the file

	# Check the file type
	FTYPE=`stat -f "%ST" $prefix/${1}`
	# Convert all slashes (/) to underscores (_) to generate an unique
	# name for the diff
	NAME=`echo ${5} | sed -e 's/\//_/g'`
	# Location of the diff
	DIFF="${LOC}/${NAME}.diff"
        
	case "${FTYPE}" in
                '*')
			# Executable, so use bsdiff (works with shell scripts
			# as well)
                        bsdiff $prefix/${1} $prefix/${2} ${DIFF}
			if [ ! -e ${DIFF} ]; then
				echo "Creating ${DIFF} failed.  Abort"
				exit $?
			fi
			SUM_DIFF="`${SUM} -q ${DIFF}`"
			# Generate INDEX entry
			echo "${5}#`basename ${DIFF}`#${SUM_DIFF}#${3}#${4}"\
				 >> ${INDEX}
                ;;
		'@')
			echo "No symlink support"
		;;
                *)
			# Normal file
			diff -uN $prefix/${1} $prefix/${2} > ${DIFF}
			if [ ! -e ${DIFF} ]; then
				echo "Creating ${DIFF} failed.  Abort"
				exit $?
			fi
			SUM_DIFF="`${SUM} -q ${DIFF}`"
			# Generate INDEX entry
			echo "${5}#`basename ${DIFF}`#${SUM_DIFF}#${3}#${4}"\
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
				#echo "Check $opath/$i and $mpath/$i"
				OSUM=`${SUM} -q $prefix/$opath/$i`
				NSUM=`${SUM} -q $prefix/$mpath/$i`
				# Checksum different, so generate a patch
				if [ "${OSUM}" != "${NSUM}" ]; then
					echo -n "NOTE: $ropath/$i and "
					echo "$rmpath/$i differ.  Create patch"
					# Create a pathc
					create_patch "$opath/$i" "$mpath/$i" "${OSUM}" "${NSUM}" "${ropath}/$i"
					copy_file "$opath/$i" "$mpath/$i" "${OSUM}" "${NSUM}" "${ropath}/$i"
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
	${SUM} -q ${INDEX} > ${INDEX}.sum
fi

exit $?

