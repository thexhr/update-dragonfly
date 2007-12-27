#!/bin/sh

if [ -e gen_update.conf ]; then
	. gen_update.conf
else
	echo "Config file not found."
	exit 1
fi

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

# Print a message if -v is given
log()
{
	MSG=$1
	if [ ${DEBUG} -eq 1 ]; then
		echo ${MSG}
	fi
}


# Check if $LOC is available
startup()
{

	ARCH=`uname -m`
	VERSION=`uname -r | cut -d '-' -f 1`
	LOC="${BASE}/${VERSION}/${ARCH}"
	INDEX="${LOC}/INDEX"

	if [ ! -d ${LOC} ]; then
		log "${LOC} does not exists.  Create it"
		install -d -o root -g wheel -m 750 -p ${LOC}
	elif [ -d ${LOC} ]; then
		log "${LOC} exists.  Clean it"
		rm -rf -I ${LOC}/*
	fi

	# If we do a build stamp run and BSLOG exists, delete it
	if [ ${BFLAG} -eq 1 -a -e ${BSLOG} ]; then
		rm ${BSLOG}
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

	# Create unique file name
	FLOC=${LOC}/`echo ${5} | sed -e 's/\//_/g'`

	# Check the file type
	case "`stat -f "%ST" $prefix/${1}`" in
		'@')
			echo "Symlink.  Skip it"
			break
		;;
		*)
			# Just copy the file
			cp $prefix/${2} ${FLOC}	
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
                '*'|*)
			# Executable, so use bsdiff (works with shell scripts
			# as well)
                        bsdiff $prefix/${1} $prefix/${2} ${DIFF} || return 1
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
                #*)
			# Normal file
		#	diff -uN $prefix/${1} $prefix/${2} > ${DIFF}
		#	if [ ! -e ${DIFF} ]; then
		#		echo "Creating ${DIFF} failed.  Abort"
		#		exit $?
		#	fi
		#	SUM_DIFF="`${SUM} -q ${DIFF}`"
			# Generate INDEX entry
		#	echo "${5}#`basename ${DIFF}`#${SUM_DIFF}#${3}#${4}"\
		#		 >> ${INDEX}
        esac

}

create_build_stamp()
{
	# $1 = orig path
	# $2 = new path
	# $3 = real path

	# Count the number of differences between the two files
	CNT=`${DC} ${1} ${2}` #|| return 1
	# If we have a difference between 1 and 128 chars, consider the file
	# modified from a build timestamp.  See Colin Percivals Paper for 
	# further information
	if [ ${CNT} -ge 1 -a ${CNT} -le 128 ]; then
		log "1. Create build stamp for ${3}"
		echo "${3}" >> ${BSLOG}
	# The difference is bigger.  This happens in most cases for lib
	# archives. 
	else
		diff1="/tmp/obdj1"
		diff2="/tmp/obdj2"
		objdump -a ${1} > ${diff1}
		objdump -a ${2} > ${diff2}
		# Do we have a diff in the archive header?
		if [ `diff -u ${diff1} ${diff2} | wc -l | awk '{print $1}'` -ge 1 ]; then
			echo "${3}" >> ${BSLOG}
			log "2. Create build stamp for ${3}"
		fi
	fi
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
		# Don't try to diff fortune files.  They are randomized during
		# every build (and dont ask me why)
		if [ "$ropath" = "/usr/share/games/fortune" ]; then
			log "Dont try to diff fortunes dat files"
			break
		fi
		# Compare two files
		if [ -f "$prefix/$opath/$i" ]; then
			if [ -f "$prefix/$mpath/$i" ]; then
				#echo "Check $opath/$i and $mpath/$i"
				OSUM=`${SUM} -q $prefix/$opath/$i`
				NSUM=`${SUM} -q $prefix/$mpath/$i`
				# Checksum different, so generate a patch
				if [ "${OSUM}" != "${NSUM}" ]; then
					if [ ${BFLAG} -eq 0 ] && [ -n "`grep -x ${ropath}/$i ${BSLOG}`" ]; then
						log "Build stamp file for ${ropath}/$i found"
						continue
					fi
					# No build stamp run
					if [ ${BFLAG} -eq 0 ]; then
						log "NOTE: $ropath/$i and 
							$rmpath/$i differ.  Create patch"
						create_patch "$opath/$i" "$mpath/$i" "${OSUM}" "${NSUM}" "${ropath}/$i"
						copy_file "$opath/$i" "$mpath/$i" "${OSUM}" "${NSUM}" "${ropath}/$i"
					# Build stamp run
					else
						create_build_stamp "$prefix/$opath/$i" "$prefix/$mpath/$i" "${ropath}/$i"
					fi
				fi
			# XXX What to do now?
			else
				log "WARNING: $prefix/$opath/$i exists 
				whether $prefix/$mpath/$i not"
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

usage()
{
	echo "usage: $0 [-bh] <prefix> <old tree> <new tree>"
	echo "		-b : Create build stamps log"
	echo "		-h : Display this help"
	echo "		-v : Be more verbose"
	echo ""
	echo "Example $0 /usr/build old new"
	exit 0
}

args=`getopt bhv $*`

if [ $? -ne 0 ]; then
	usage
fi

BFLAG=0
DEBUG=0

set -- $args
for i; do
        case "$i" in
	# Create build stamps log
	-b)
		BFLAG=1
		shift;;
	-h)
		usage; shift;;
	-v)
		DEBUG=1
		shift;;
	--)
		shift; break;;
	esac
done

prefix=$1
opath=$2
mpath=$3

# Keep track of the real pathes in the system
ropath=""
rmpath=""
otemp=$2

startup
cd "$prefix/$opath"
dir "."

# Generate the INDEX hash
if [ ! -e ${INDEX} ]; then
	echo "INDEX file not found."
else
	${SUM} -q ${INDEX} > ${INDEX}.sum
fi

exit $?

