#!/bin/sh

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

# Print a message if -v is give
log()
{
	MSG=$1
	if [ ${DEBUG} -eq 1 ]; then
		echo ${MSG}
	fi
}

# Check if update location is availble.  If not, create it
check_temp_loc()
{
	if [ ! -d $LOC ]; then
		mkdir -p $LOC
		chmod 700 $LOC
	fi
}

# Fetch a file from the server and check the SHA sum with in one in the config
# file.  Idea partly stolen from freebsd-update
verify_server()
{
	if [ -e ${LOC}/pub.ssl ]; then
		rm -f ${LOC}/pub.ssl
	fi

	echo -n "Fetch public key from ${SERVER} ... "
	fetch -q -o ${LOC}/pub.ssl ${SERVER}/${RPATH}/pub.ssl || {
		echo "failed."
		exit 1
	}
	echo "done."

	if [ "`${SUM} -q ${LOC}/pub.ssl`" != "${FINGERPRINT}" ]; then
		echo "Fingerprint does not match.  Abort"
		exit 1
	fi
}

# Save all file information needed for a correct installation
# User, Group, Location, Mode
save_file_perm()
{
	#BINARY=$1
	#SUM_NEW=$2

	if [ -e ${1} ]; then
                log "Save file status"
		# Handle file flag
                if [ `stat -f "%Of" ${1}` -eq 400000 ]; then
			log "schg"
                	FL="schg"
		else
			FL="0"
		fi
		STR=`stat -f "%OLp#%Su#%Sg" ${1}` || return
                echo "${1}#${STR}#${2}#${FL}" >> ${TMPLOG}
        else
                log "${1} not installed.  Help me"
        fi
}

# Patch the original file with the patch (either binary or text diff), validate
# the result with the checksum and store it for later installation
patch_file()
{
	#BINARY=$1
	#DIFF=$2
	#SUM_NEW=$3

	#BIN_TEMP=${LOC}/${VERSION}/`basename ${1}`
	SUFFIX=`echo ${1} | sed -e 's/\//_/g'`
	BIN_TEMP=${LOC}/${VERSION}/${SUFFIX}

	if [ -e ${BIN_TEMP} ] && [ "`${SUM} -q ${BIN_TEMP}`" = "${SUM_NEW}" ]; then
		log "${BIN_TEMP} already patched"
		return 1
	fi

	# XXX What about other file types (@, |, =) ???
	FTYPE=`stat -f "%ST" ${1}` || return
	case "${FTYPE}" in
		'*')
			# Executable file.  We have to use bspatch.  Works with
			# shell scripts as well
			bspatch ${1} ${BIN_TEMP} \
				${LOC}/${VERSION}/${2}
		;;
		*)
			# Text file.  Use patch
			patch -p1 -o ${BIN_TEMP} ${1} \
				${LOC}/${VERSION}/${2} 2> /dev/null
		;;
	esac
	
	# Checksum mismatch,  Patching failed
	if [ "`${SUM} -q ${BIN_TEMP}`" != "${3}" ]; then
		log "Patching ${1} failed".
		exit 1
	else
		log "Patching ${1} successful"
	fi

	return 0	
}

# Check if the file we want to patch is available on the local machine.
# If not, skip over it.
# XXX Can we assume that the user removed the file and its not our fault?
check_for_file()
{
	#BINARY=$1
	#SUM_OLD=$2

	if [ ! -e ${1} ]; then
		log "${1} is not installed locally,  Skip over it"
		return 1
	else
		if [ "`${SUM} -q ${1}`" != "${2}" -a ${OVERWRITE} -eq 0 ]; then
			echo "${1} was modified locally.  Skip it."
			return 2
		elif [ "`${SUM} -q ${1}`" != "${2}" -a ${OVERWRITE} -eq 1 ]; then
			log "${1} modified locally, but you choosed to overwrite it"
		fi
	fi

	return 0
}

# Deal with possible file system flags
# XXX Currently only schg is supported.  Need for more?
handle_file_flags()
{
	# $1 = file path
	# $2 = flags
	# $3 = mode
 
	# Remove flag	
	if [ ${3} -eq 0 ]; then
		if [ "${2}" = "schg" ]; then
			# schg flag set
			log "Remove schg flag from ${1}"
			chflags noschg ${1} || return 1
		fi
	# set flag
	elif [ ${3} -eq 1 ]; then
		if [ "${2}" = "schg" ]; then
			# schg flag set
			log "Set schg flag to ${1}"
			chflags schg ${1} || return 1
		fi
	fi

	return 0
}

# Check if the file was already installed.  This prevents over-installation of 
# previous patched file.
check_already_installed()
{
	#BINARY=$1
	#SUM_NEW=$2

	if [ "`${SUM} -q ${1}`" = "${2}" ]; then
		log "${1} already installed"
		return 1
	fi

	return 0
}

# Backup file and zip it
# XXX Rewrite it and store backups to a proper location with proper naming
backup_file()
{
	#BINARY=$1

	BACKUPD=${LOC}/${VERSION}/backup
	BACKUPF=${BACKUPD}/`echo ${1} | sed -e 's/\//_/g'`.gz

	if [ ! -d ${BACKUPD} ]; then
		mkdir -p ${BACKUPD} || return 1
	fi

	cat ${1} | gzip -9 - > ${BACKUPF} || return 1

	return 0
}

# Reinstall a previously updated file from the backup
reinstall_backup()
{
	if [ ! -e ${TMPLOG} ]; then
		echo "No update log found.  Cannot reinstall backups"
		exit 1
	fi

	echo "Reinstalling backups ..."	
	for i in `cat ${TMPLOG}`; do
		# Location of the file
		BINARY=`echo ${i} | cut -d '#' -f 1`
		# Mode
		MODE=`echo ${i} | cut -d '#' -f 2`
		# Owner
		USER=`echo ${i} | cut -d '#' -f 3`
		# Group
		GROUP=`echo ${i} | cut -d '#' -f 4`
		# Checksum of the modified (new) file
		SUM_NEW=`echo ${i} | cut -d '#' -f 5`
		# Potential file flags (eg schg)
		FLAGS=`echo ${i} | cut -d '#' -f 6`
		# Calculate the filename of the modified (new) file
		FSUFFIX=`echo ${BINARY} | sed -e 's/\//_/g'`.gz
		BACKUP_TEMP=${LOC}/${VERSION}/backup/${FSUFFIX}

		if [ ${NFLAG} -eq 0 ]; then
			echo "${BINARY}"
			TMPF=`mktemp ${LOC}/${VERSION}/backup/bi.XXXXX` || return 1
			cat ${BACKUP_TEMP} | gzip -d > ${TMPF} || return 1
			install -m ${MODE} -o ${USER} -g ${GROUP} \
				${TMPF} ${BINARY} || return 1
			rm -f ${TMPF} || return 1
		else
			echo "${BINARY}"
		fi
	done

	return 0
}

# Install the patched files.  Before installating check if the file was already
# installed.
install_updates()
{
	if [ ! -e ${TMPLOG} ]; then
		echo "No update log found.  Please run `basename $0` -g at first"
		exit 1
	fi
	
	if [ ${NFLAG} -eq 0 ]; then
		echo "Installing updates..."
	else
		echo "Without -n `basename $0` would update the following files"
	fi

	for i in `cat ${TMPLOG}`; do
		# Location of the file
		BINARY=`echo ${i} | cut -d '#' -f 1`
		# Mode
		MODE=`echo ${i} | cut -d '#' -f 2`
		# Owner
		USER=`echo ${i} | cut -d '#' -f 3`
		# Group
		GROUP=`echo ${i} | cut -d '#' -f 4`
		# Checksum of the modified (new) file
		SUM_NEW=`echo ${i} | cut -d '#' -f 5`
		# Potential file flags (eg schg)
		FLAGS=`echo ${i} | cut -d '#' -f 6`
		# Calculate the filename of the modified (new) file
		FSUFFIX=`echo ${BINARY} | sed -e 's/\//_/g'`
		BIN_TEMP=${LOC}/${VERSION}/${FSUFFIX}
	
		# Check if the file is already installed.  If no, install it	
		check_already_installed ${BINARY} ${SUM_NEW}
		if [ $? -eq 0 ]; then
			if [ ${NFLAG} -eq 0 ]; then
				# Remove possible file flags
				handle_file_flags ${BINARY} ${FLAGS} 0
				log "Backup ${BINARY}"
				backup_file ${BINARY} 
				install -m ${MODE} -o ${USER} -g ${GROUP} \
					${BIN_TEMP} ${BINARY} || return 1
				# Reset possible file flags
				handle_file_flags ${BINARY} ${FLAGS} 1
			else
				echo "${BINARY}"
			fi
		fi
	done

	if [ ${NFLAG} -eq 0 ]; then
		echo "All updates installed"
	fi

	return 0
}

# Show all the patched files so that the user can decide either he wants to
# install them or not.
show_updates()
{
	# NO INSTALL.LOG found
	if [ ! -e ${TMPLOG} ]; then
		echo "All available updates are already installed"
		return
	fi

	echo ""
	echo "Use `basename $0` -i to install the following files:"
	for i in `cat ${TMPLOG}`; do
		echo ${i} | cut -d '#' -f 1
	done
}

# Fetch the diffs from the server and verify them
get_updates()
{
	INDEX=${LOC}/${VERSION}/INDEX
	
	echo "Get all available updates..."
	for i in `cat ${INDEX}`; do
		# Absolute path of the file
		BINARY=`echo $i | cut -d '#' -f 1`
		# Name of the diff file
		DIFF=`echo $i | cut -d '#' -f 2`
		# Checksum of the diff file
		SUM_DIFF=`echo $i | cut -d '#' -f 3`
		# Checksum of the original (old) file
		SUM_OLD=`echo $i | cut -d '#' -f 4`
		# Checksum of the patched (new) file
		SUM_NEW=`echo $i | cut -d '#' -f 5`

		# Fetch the diff file
		fetch -q -o ${LOC}/${VERSION}/${DIFF} \
			${SERVER}/${RPATH}/${VERSION}/${ARCH}/${DIFF} || {
			echo "Cannot fetch ${LOC}/${VERSION}/${DIFF}.  Abort"
			exit 1
		}
	
		# Verify the diff	
		if [ "`${SUM} -q ${LOC}/${VERSION}/${DIFF}`" != "$SUM_DIFF" ]; then
			echo "Patch ${DIFF} corrupt.  Abort."
			exit 1
		fi

		# Check if the file we want to patch is installed on the local
		# machine and if the file matches the original checksum
		check_for_file ${BINARY} ${SUM_OLD}
		if [ $? -eq 1 -o $? -eq 2 ]; then
			break
		fi

		# Check if the file is already installed.  This is necessary here
		# because trying to patch an already patched file would fail
		check_already_installed ${BINARY} ${SUM_NEW}
		if [ $? -eq 0 ]; then
			# Patch existing file
			log "Save permissions"
			save_file_perm ${BINARY} ${SUM_NEW}
			log "Patch ${BINARY}"
			patch_file ${BINARY} ${DIFF} ${SUM_NEW}
		fi
	done
}

# Check for an INDEX file on the server and compute the checksum
check_version()
{
	VERSION=`uname -r | cut -d '-' -f 1`
	ARCH=`uname -m`

	# update-dragonfly directory not found
	if [ ! -d ${LOC}/${VERSION} ]; then
		mkdir -p ${LOC}/${VERSION} || return 1
	fi

	# Checksum file exists, remove it
	if [ -e ${LOC}/${VERSION}/INDEX.sha1 ]; then
		rm -f ${LOC}/${VERSION}/INDEX.sha1 || return 1
	fi

	# This is the file where all to-be-installed files are recorded	
	TMPLOG=${LOC}/${VERSION}/INSTALL.LOG

	# Fetch the checksum first.  If the fetched checksum and the computed
	# checksum of an installed INDEX file match, no newer updates are
	# available
	echo "Check for $VERSION updates"
	fetch -q -o ${LOC}/${VERSION}/INDEX.sha1 \
		${SERVER}/${RPATH}/${VERSION}/${ARCH}/INDEX.sha1 || {
		echo "INDEX.sha1 fetch failed"
		exit 1
	}
	
	INDEX_SUM=`cat ${LOC}/${VERSION}/INDEX.sha1`
	if [ -e ${LOC}/${VERSION}/INDEX ]; then
		INDEX_SUM_B=`${SUM} -q ${LOC}/${VERSION}/INDEX`
		if [ "$INDEX_SUM" = "$INDEX_SUM_B" ]; then
			echo "No new updates available."
			exit 1
		fi
	fi
	echo "New updates available."
	
	fetch -q -o ${LOC}/${VERSION}/INDEX \
		${SERVER}/${RPATH}/${VERSION}/${ARCH}/INDEX || {
		echo "Getting INDEX file failed.  Abort.."
		exit 1
	}

	# INDEX checksum mismatch
	INDEX_SUM_B=`${SUM} -q ${LOC}/${VERSION}/INDEX`
	if [ "$INDEX_SUM" != "$INDEX_SUM_B" ]; then
		echo "INDEX file corrupt.  Abort."
		exit 1
	fi

	return 0
}

# Startup checks
startup()
{

	if [ `uname -s` != "DragonFly" ]; then
		echo "Sorry.  `basename $0` is for DragonFlyBSD only."
		exit 1
	fi
	if [ `id -u ` -ne 0 ]; then
		echo "You have to be root to use `basename $0`.  Abort."
		exit 1
	fi

	if [ -z `which bsdiff` ]; then
		echo "`basename $0` needs bspatch and bsdiff.  Please install them at first."
		echo "pkgsrc(7) contains a version in misc/bsdiff"
		exit 1
	fi
	check_temp_loc
}

usage()
{
	echo "usage: `basename $0` [-ghinrv] [-f config]"
	echo "		-g : Get available updates"
	echo "		-h : Print this help"
	echo "		-i : Install previous fetched updates"
	echo "		-n : Do not actually install updates.  Just report all"
	echo "		     install steps taken"
	echo "		-r : Reinstall previously backed up files"
	echo "		-v : Be more verbose"
	echo ""
	echo "		-f config: Use this config file"

	exit 0
}

args=`getopt gf:hinrv $*`

FFLAG=0
GFLAG=0
IFLAG=0
NFLAG=0
RFLAG=0
DEBUG=0

TMPLOG=
SUM=/sbin/sha1

set -- $args
for i; do
        case "$i" in
	# Get updates
	-g)
		GFLAG=1
		shift;;
	# Local config file
	-f)
		if [ -e $2 ]; then
			FFLAG=1
			. $2
		else
			echo "Cannot open $2.  Abort."
			exit 1
		fi
		shift;shift;;
	# Display help
	-h)
		usage
		shift;;
	# Install updates
	-i)
		IFLAG=1
		shift;;
	# Do not install updates
	-n)
		NFLAG=1
		shift;;
	# Reinstall backups from latest run
	-r)
		RFLAG=1
		shift;;
	# Be more verbose
        -v)
                DEBUG=1
                shift;;
	esac
done

if [ ! -e /etc/update-dragonfly.conf -a ${FFLAG} -eq 0 ]; then
	echo "Cannot find /etc/update-dragonfly.conf and no config file via -f specified."
	exit 1
elif [ -e /etc/update-dragonfly.conf -a ${FFLAG} -eq 0 ]; then
	. /etc/update-dragonfly.conf
fi


if [ ${GFLAG} -eq 1 -a ${IFLAG} -eq 1 ]; then
	echo "Please choose either -g or -i.  If you want to get updates first"
	echo "and install them afterwards use `basename $0` -g && `basename $0` -i"
	exit 1
elif [ ${GFLAG} -eq 0 -a ${IFLAG} -eq 0 -a ${RFLAG} -eq 0 ]; then
	usage
fi


# Get updates
if [ ${GFLAG} -eq 1 ]; then
	startup
	verify_server
	check_version
	get_updates
	show_updates
fi

# Install updates
if [ ${IFLAG} -eq 1 ]; then
	startup
	VERSION=`uname -r | cut -d '-' -f 1`
	TMPLOG=${LOC}/${VERSION}/INSTALL.LOG
	install_updates
fi

if [ ${RFLAG} -eq 1 ]; then
	startup
	VERSION=`uname -r | cut -d '-' -f 1`
	TMPLOG=${LOC}/${VERSION}/INSTALL.LOG
	reinstall_backup
fi

exit $?

