#!/bin/sh

# Copyright (c) 2007 Matthias Schmidt <schmidtm@mathematik.uni-marburg.de>

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

# Print a message if -v is given
log()
{
	MSG=$1
	if [ ${DEBUG} -eq 1 ]; then
		echo ${MSG}
	fi
}

# Check if update location is available.  If not, create it
check_temp_loc()
{
	if [ ! -d ${LOC} ]; then
		install -d -o root -g wheel -m 750 ${LOC}
	fi
}

# Fetch a file from the server and check the checksum against the one in the
# config file.  Idea partly stolen from freebsd-update.  Note:  The key is not
# used to perform a verfiy operation like freebsd-update-verify.
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

# Save all file information needed for a correct installation:
# User, Group, Location, Mode
save_file_perm()
{
	# $1 = Path to the file
	# $2 = Checksum of the modified (new) file

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
		# Write install log entry
                echo "${1}#${STR}#${2}#${FL}" >> ${TMPLOG}
        else
                log "${1} not installed.  Help me"
        fi
}

# Patch the original file with the patch, validate
# the result with the checksum and store it for later installation
patch_file()
{
	# $1 = Path to the file
	# $2 = Path to the diff file
	# $3 = Checksum of the modified (new) file

	SUFFIX=`echo ${1} | sed -e 's/\//_/g'`
	BIN_TEMP=${LOC}/${VERSION}/${SUFFIX}

	# File exists and checksums match
	if [ -e ${BIN_TEMP} ] && [ "`${SUM} -q ${BIN_TEMP}`" = "${SUM_NEW}" ]; then
		log "${BIN_TEMP} already patched"
		return 1
	fi

	# XXX What about other file types (@, |, =) ???
	FTYPE=`stat -f "%ST" ${1}` || return
	case "${FTYPE}" in
		'*'|*)
			# Executable file.  We have to use bspatch.  Works with
			# text files as well
			bspatch ${1} ${BIN_TEMP} \
				${LOC}/${VERSION}/${2}
		;;
		'@')
			echo "Cannot patch symlink."
		;;
		#*)
			# Text file.  Use patch
		#	patch -p1 -o ${BIN_TEMP} ${1} \
		#		${LOC}/${VERSION}/${2} 2> /dev/null
		#;;
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
check_for_file()
{
	# $1 = Path to the file
	# $2 = Checksum of the original (old) file

	if [ ! -e ${1} ]; then
		log "${1} is not installed locally,  Skip over it"
		return 1
	else
		# Modified locally
		if [ "`${SUM} -q ${1}`" != "${2}" -a ${OVERWRITE} -eq 0 ]; then
			echo "${1} was modified locally.  Skip it."
			return 2
		# Modified locally, but the user want to overwrite it
		elif [ "`${SUM} -q ${1}`" != "${2}" -a ${OVERWRITE} -eq 1 ]; then
			log "${1} modified locally, but you choosed to overwrite it"
			return 3
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
	# $3 = operation mode
 
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
	# $1 = Path to the file
	# $2 = Checksum of the modified (new) file

	if [ "`${SUM} -q ${1}`" = "${2}" ]; then
		log "${1} already installed"
		return 1
	fi

	return 0
}

# Backup file and zip it
backup_file()
{
	# $1 = Path to the file

	BACKUPD=${LOC}/${VERSION}/backup
	BACKUPF=${BACKUPD}/`echo ${1} | sed -e 's/\//_/g'`

	if [ ! -d ${BACKUPD} ]; then
		install -d -o root -g wheel -m 750 ${BACKUPD} || return 1
	fi

	if [ ${ZIP} = "gzip" ]; then
		cat ${1} | ${ZIP} -9 - > ${BACKUPF}.gz || return 1
	elif [ ${ZIP} = "bzip2" ]; then
		cat ${1} | ${ZIP} -9 - > ${BACKUPF}.bz2 || return 1
	else
		echo "Unsupported compress program ${ZIP}"
		exit 1
	fi

	return 0
}

# Reinstall a previously updated file from the backup
reinstall_backup()
{
	BACKUPDIR=${LOC}/${VERSION}/backup/

	if [ ! -d ${BACKUPDIR} ]; then
		echo "No backups found."
		exit 1
	fi

	if [ ! -e ${TMPLOG} ]; then
		echo "No update log found.  Cannot reinstall backups"
		exit 1
	fi

	echo -n "Reinstalling backups... "	
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

		if [ ${NFLAG} -eq 0 ]; then
			log "${BINARY}"
			# Unextract the file into a temporary location
			TMPF=`mktemp ${LOC}/${VERSION}/backup/bi.XXXXX` || return 1
			if [ ${ZIP} = "gzip" ]; then
				FSUFFIX=`echo ${BINARY} | sed -e 's/\//_/g'`.gz
			elif [ ${ZIP} = "bzip2" ]; then
				FSUFFIX=`echo ${BINARY} | sed -e 's/\//_/g'`.bz2
			else
				echo "failed."
				echo "Unsupported compress program ${ZIP}"
				exit 1
			fi
			# Calculate the filename of the modified (new) file
			BACKUP_TEMP=${BACKUPDIR}/${FSUFFIX}
			cat ${BACKUP_TEMP} | ${ZIP} -d > ${TMPF} || return 1
			install -m ${MODE} -o ${USER} -g ${GROUP} \
				${TMPF} ${BINARY} || return 1
			rm -f ${TMPF} || return 1
		else
			echo "${BINARY}"
		fi
	done
	echo "done."

	return 0
}

# Install the patched files.  Before installating check if the file was already
# installed.
install_updates()
{
	# Number of installed files
	ISUM=0

	if [ ! -e ${TMPLOG} ]; then
		echo "No update log found.  Please run `basename $0` -g at first"
		exit 1
	fi
	
	if [ ${NFLAG} -eq 0 ]; then
		echo -n "Installing updates... "
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
				ISUM=$(($ISUM + 1))
			else
				echo "${BINARY}"
			fi
		fi
	done
	
	if [ ${ISUM} -gt 0 -a ${NFLAG} -eq 0 ]; then
		echo "done."
	elif [ ${ISUM} -eq 0 -a ${NFLAG} -eq 0 ]; then
		echo "updates already installed."
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
	echo "Updates for the following files are available:"
	for i in `cat ${TMPLOG}`; do
		echo ${i} | cut -d '#' -f 1
	done
}

# Fetch the diff or the whole file  from the server and verify it
get_updates()
{
	INDEX=${LOC}/${VERSION}/INDEX
	
	echo -n "Get all available updates... "
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
			echo "failed."
			echo "Cannot fetch ${LOC}/${VERSION}/${DIFF}.  Abort"
			exit 1
		}
	
		# Verify the diff	
		if [ "`${SUM} -q ${LOC}/${VERSION}/${DIFF}`" != "${SUM_DIFF}" ]; then
			echo "failed."
			echo "Patch ${DIFF} corrupt.  Abort."
			exit 1
		fi
		
		# Check if the file is already installed.  This is necessary here
		# because trying to patch an already patched file would fail
		check_already_installed ${BINARY} ${SUM_NEW}
		CAIRET=$?
		if [ ${CAIRET} -eq 1 ]; then
			continue
		fi

		# Check if the file we want to patch is installed on the local
		# machine and if the file matches the original checksum
		check_for_file ${BINARY} ${SUM_OLD}
		RET=$?
		OVER=0
		if [ ${RET} -eq 1 -o ${RET} -eq 2 ]; then
			continue	
		# User agreed to overwrite, but we have a checksum mismatch
		# thus fetch the whole file
		elif [ ${RET} -eq 3 ]; then
			log "Fetch complete file"
			FNAME=`echo ${BINARY} | sed -e 's/\//_/g'`
			# Fetch the complete file
			fetch -q -o ${LOC}/${VERSION}/${FNAME} \
				${SERVER}/${RPATH}/${VERSION}/${ARCH}/${FNAME} || {
				echo "failed."
				echo "Cannot fetch ${LOC}/${VERSION}/${FNAME}.  Abort"
				exit 1
			}
			# Verify the file
			if [ "`${SUM} -q ${LOC}/${VERSION}/${FNAME}`" != "${SUM_NEW}" ]; then
				echo "failed."
				echo "Fetched ${BINARY} corrupt.  Abort."
				exit 1
			fi
			OVER=1
		fi
		
		if [ ${CAIRET} -eq 0 -a ${OVER} -eq 0 ]; then
			# Patch existing file
			save_file_perm ${BINARY} ${SUM_NEW}
			log "Patch ${BINARY}"
			patch_file ${BINARY} ${DIFF} ${SUM_NEW}
		elif [ ${CAIRET} -eq 0 -a ${OVER} -eq 1 ]; then
			# Overwrite existing file
			save_file_perm ${BINARY} ${SUM_NEW}
		fi
	done

	echo "done."
}


# Check for the installed kernel binary and kernel version
check_version()
{
	VERSION=`uname -r | cut -d '-' -f 1`
	RELEASE=`uname -r | cut -d '-' -f 2`
	ARCH=`uname -m`

	if [ ! -e `sysctl -n kern.bootfile` ]; then
		echo "Cannot find your running kernel binary.  Abort."
		exit 1
	fi

	if [ ${RELEASE} != "RELEASE" ]; then
		echo -n "Sorry, `basename $0` supports RELEASE kernel "
		echo "version only"
		exit 1
	fi

}

# Check for an INDEX file on the server and compute the checksum
get_index()
{

	# update-dragonfly directory not found
	if [ ! -d ${LOC}/${VERSION} ]; then
		install -d -o root -g wheel -m 750 ${LOC}/${VERSION} || \
			return 1
	fi

	# Checksum file exists, remove it
	if [ -e ${LOC}/${VERSION}/INDEX.sum ]; then
		rm -f ${LOC}/${VERSION}/INDEX.sum || return 1
	fi

	# This is the file where all to-be-installed files are recorded	
	TMPLOG=${LOC}/${VERSION}/INSTALL.LOG
	#if [ -e ${TMPLOG} ]; then
	#	rm -f ${TMPLOG}
	#fi

	# Fetch the checksum first.  If the fetched checksum and the computed
	# checksum of an installed INDEX file match, no newer updates are
	# available
	echo -n "Check for DragonFly $VERSION updates... "
	fetch -q -o ${LOC}/${VERSION}/INDEX.sum \
		${SERVER}/${RPATH}/${VERSION}/${ARCH}/INDEX.sum || {
		echo "failed."
		echo "Cannot fetch INDEX.sum.  Abort."
		cleanup_after_failure
		exit 1
	}

	SUM_CONT=`cat ${LOC}/${VERSION}/INDEX.sum`
	if [ -e ${LOC}/${VERSION}/INDEX ]; then
		INDEX_SUM_B=`${SUM} -q ${LOC}/${VERSION}/INDEX`
		if [ "$SUM_CONT" = "$INDEX_SUM_B" ]; then
			echo "done."
			echo "No new updates available."
			exit 1
		fi
	fi
	echo "done."
	
	fetch -q -o ${LOC}/${VERSION}/INDEX \
		${SERVER}/${RPATH}/${VERSION}/${ARCH}/INDEX || {
		echo "Getting INDEX file failed.  Abort."
		cleanup_after_failure
		exit 1
	}

	# INDEX checksum mismatch
	INDEX_SUM_B=`${SUM} -q ${LOC}/${VERSION}/INDEX`
	if [ "$SUM_CONT" != "$INDEX_SUM_B" ]; then
		echo "INDEX file corrupt.  Abort."
		cleanup_after_failure
		exit 1
	fi

	return 0
}

# Remove the INDEX and the checksum file after a failure.  This prevents $0
# from displaying "No new updates" even if there are new updates available.
cleanup_after_failure()
{
	if [ -e ${LOC}/${VERSION}/INDEX.sum ]; then
		rm -f ${LOC}/${VERSION}/INDEX.sum || return 1
	fi

	if [ -e ${LOC}/${VERSION}/INDEX ]; then
		rm -f ${LOC}/${VERSION}/INDEX || return 1
	fi
	
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

	if [ `sysctl -n kern.securelevel` -gt 0 ]; then
		echo "securelevel greater than zero.  Cannot modifly"
		echo "system flags."
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
	check_version
	verify_server
	get_index
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

