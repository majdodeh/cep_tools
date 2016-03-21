#!/bin/bash

TARGET=mipsel-elf

PREFIX=
SRC_DIR="$PWD"/src
BUILD_DIR="$PWD"/build

NICE=
FORCE=0
VERBOSE=0
LOG="$PWD"/build.log
STAGE=3
INFO=0

OS=$(uname)

BINUTILS=binutils-gdb
GCC=gcc
NEWLIB=newlib
QEMU=qemu

# Plateform specifics
JOBS=1
GET=
USE_SYSTEM_GMP=n
USE_SYSTEM_MPFR=n
USE_SYSTEM_MPC=n

# GMP, MPFR and MPC
GMP_SRC="https://gmplib.org/download/gmp/gmp-5.1.3.tar.bz2"
MPFR_SRC="http://www.mpfr.org/mpfr-3.1.2/mpfr-3.1.2.tar.bz2"
MPC_SRC="http://www.multiprecision.org/mpc/download/mpc-1.0.1.tar.gz"

GMP_ARCHIVE="$SRC_DIR/$(basename "$GMP_SRC")"
MPFR_ARCHIVE="$SRC_DIR/$(basename "$MPFR_SRC")"
MPC_ARCHIVE="$SRC_DIR/$(basename "$MPC_SRC")"

GMP="$(echo $(basename $(echo "$GMP_ARCHIVE")) | sed -e 's/\.tar\..*//')"
MPFR="$(echo $(basename $(echo "$MPFR_ARCHIVE")) | sed -e 's/\.tar\..*//')"
MPC="$(echo $(basename $(echo "$MPC_ARCHIVE")) | sed -e 's/\.tar\..*//')"

function append_to() {
	local target=$1
	local append=$2

	eval $target=\"\$$target $append\"
}

function get_num_of_proc() {
	local num
	case "$OS" in
		"Linux")
			num=$(grep ^processor /proc/cpuinfo | wc -l);;
		"Darwin")
			num=$(hostinfo | grep "processors are logically available" | cut -f1 -d' ');;
		*)
			num=0;;
	esac

	echo $(($num + 1))
}

function find_gmp() {
	local gmp_ver
	local gmp_header="/usr/include/gmp.h"

	# Simple heuristic to try to find gmp
	[ -r "$gmp_header" ] || return

	gmp_ver=$(echo "__GNU_MP_RELEASE" | cat "$gmp_header" - | cpp | tail -1)
	gmp_ver=$(($gmp_ver))

	if [ $gmp_ver -ge 40200 ]; then
		USE_SYSTEM_GMP=y
	fi
}

function find_mpfr() {
	local mpfr_ver
	local mpfr_header="/usr/include/mpfr.h"

	# Simple heuristic to try to find mpfr
	[ -r "$mpfr_header" ] || return

	mpfr_ver=$(echo "(MPFR_VERSION_MAJOR * 10000) + (MPFR_VERSION_MINOR * 100) + MPFR_VERSION_PATCHLEVEL" | cat "$mpfr_header" - | cpp | tail -1)
	mpfr_ver=$(($mpfr_ver))

	if [ $mpfr_ver -ge 20400 ]; then
		USE_SYSTEM_MPFR=y
	fi

}

function find_mpc() {
	local mpc_ver
	local mpc_header="/usr/include/mpc.h"

	# Simple heuristic to try to find mpc
	[ -r "$mpc_header" ] || return

	mpc_ver=$(echo "(MPC_VERSION_MAJOR * 10000) + (MPC_VERSION_MINOR * 100) + MPC_VERSION_PATCHLEVEL" | cat "$mpc_header" - | cpp | tail -1)
	mpc_ver=$(($mpc_ver))

	if [ $mpc_ver -ge 00800 ]; then
		USE_SYSTEM_MPC=y
	fi

}

function set_platform_specifics() {
	# Try to find a download tool
	for i in wget curl
	do
		if which $i >/dev/null 2>&1; then
			GET=$i
			break
		fi
	done

	if [ -z $GET ]; then
		echo "Error: Unable to find a download tool"
		exit 1
	fi

	# Try to find the good parallel jobs number
	# Fallback to 1 if we don't know
	JOBS=$(get_num_of_proc)

	# Use GMP, MPFR, MPC from the system if we can find them and the
	# version is ok
	find_gmp
	find_mpfr
	find_mpc
}

function log_begin() {
# Stream redirections
	if [ $VERBOSE -eq 0 ]; then
		exec 6>&1
		exec 7>&2
		exec >$LOG 2>&1
	fi
}

function log_end() {
	if [ $VERBOSE -eq 0 ]; then
		exec 1>&6 6>&-
		exec 2>&7 7>&-
	fi
}

function log() {
	echo "---------------------"
	echo $1
	echo "---------------------"

	if [ $VERBOSE -eq 0 ]; then
		echo $1 >&6
	fi
}

function info() {
	echo "Some info based on your system:"
	echo " - Use system GMP: $USE_SYSTEM_GMP"
	echo " - Use system MPFR: $USE_SYSTEM_MPFR"
	echo " - Use system MPC: $USE_SYSTEM_MPC"
	echo " - Found download tool: $GET"

	if [ $USE_SYSTEM_GMP == n ]; then
		echo " - GMP version to be downloaded: $GMP"
	fi
	if [ $USE_SYSTEM_MPFR == n ]; then
		echo " - MPFR version to be downloaded: $MPFR"
	fi
	if [ $USE_SYSTEM_MPC == n ]; then
		echo " - MPC version to be downloaded: $MPC"
	fi
}

function print_help() {
	exec 6>&1
	exec >&2
	echo "Usage: $0 --prefix PREFIX [--stage STAGE] [-j JOBS] [-l FILE] [-n] [-f] [-v]"
	echo "Build the CEP tools."
	echo "Exemple: $0 --prefix $HOME/local/cep"
	echo -e "\nArguments:"
	echo -e "\t--prefix PREFIX\t Set the tools installation prefix"
	echo -e "\t--stage STAGE\t Set the tools to be built (default: $STAGE)"
	echo -e "\t             \t STAGE: 0  Build binutils and gdb only"
	echo -e "\t             \t \t1  Also build bare GCC (without libc)"
	echo -e "\t             \t \t2  Also build newlib and GCC stage2 (with libc)"
	echo -e "\t             \t \t3  Also build QEMU"
	echo -e "\t-j JOBS\t\t Specify the -j argument to pass to make (default: $(get_num_of_proc))"
	echo -e "\t-n\t\t Renice the make commands"
	echo -e "\t-f\t\t Ignore non-empty prefix"
	echo -e "\t-v\t\t Be verbose"
	echo -e "\t-l FILE\t\t Log build output to FILE (default: $LOG)"
	echo -e "\t-i\t\t Print some debug info and exit"
	exec >&6 6>&-
}

function error_check() {
	if [ $2 -ne 0 ]; then
		log "Error during $1. Consult $LOG for more details."
		exit 3
	fi
}

function download_extract() {
	local src=$1
	local archive=$2
	local target=$3

	if [ ! -f "$archive" ]; then
		log "Downloading $target..."
		case $GET in
			wget)
				$GET "$src" -O "$archive";;
			curl)
				$GET "$src" >"$archive";;
			*)
				log "Don't know how to use $GET"
				exit 1;;
		esac
	fi

	if [ ! -d "$SRC_DIR"/"$target" ]; then
		log "Extracting $target..."
		# Let tar determine the compression type, hopefully...
		tar xvf $archive -C "$SRC_DIR"
	fi
}

function build() {
	local tool=$1
	local conf_args=$2
	local make_target=$3
	local make_install_target=$4

	mkdir -p "$BUILD_DIR"/$tool
	pushd "$BUILD_DIR"/$tool >/dev/null 2>&1

	if [ ! -z "$conf_args" ]; then 
		log "Configuring ${tool}..."
		"$SRC_DIR"/$tool/configure $conf_args
		error_check configure $?
	fi

	log "Building ${tool}..."
	$NICE make -j$JOBS $make_target
	error_check build $?

	log "Installing ${tool}..."
	make $make_install_target
	error_check install $?

	popd >/dev/null 2>&1
}

function stage_done() {
	if [ $STAGE -eq 0 ]; then
		log_end
		exit 0
	fi

	STAGE=$(($STAGE - 1))
}

set_platform_specifics

# Args parsing
while [ $# -ne 0 ]; do
	case $1 in
		"--prefix")
			shift
			PREFIX=$1;;

		"--stage")
			shift
			STAGE=$1;;

		"-j")
			shift
			JOBS=$1;;

		"-n")
			NICE=nice;;

		"-f")
			FORCE=1;;

		"-v")
			VERBOSE=1;;

		"-l")
			shift
			LOG=$1;;

		"-i")
			INFO=1;;

		"--help")
			print_help
			exit 0;;
		*)
			print_help
			exit 1;;
	esac
	shift
done

if [ $INFO -eq 1 ]; then
	info
	exit 0
fi

# Prefix checks
if [ -z "$PREFIX" ]; then
	print_help
	exit 1
fi

if [ -e "$PREFIX" ]; then
	if [ ! -d $PREFIX ]; then
		echo "$PREFIX already exists and is not a directory"
		exit 2
	else
		if [[ $(ls -1 "$PREFIX" | wc -l) -ne 0 && $FORCE -eq 0 ]]; then
			echo "$PREFIX is not empty. Use -f to proceed anyway"
			exit 2
		fi
	fi

	touch "$PREFIX"/__foo__ >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		echo "Unable to write to $PREFIX"
		exit 2
	fi
	rm -f "$PREFIX"/__foo__

else
	mkdir -p "$PREFIX" || exit 2
fi


rm -rf "$BUILD_DIR"
rm -f "$LOG"

log_begin

export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:$LD_LIBRARY_PATH
export LD_RUN_PATH=$PREFIX/lib

# Let's Rock

if [ $USE_SYSTEM_GMP == n ]; then
	download_extract $GMP_SRC $GMP_ARCHIVE $GMP
	build $GMP "--prefix=$PREFIX" "" install
	append_to GCC_ADDITIONAL_PARAM "--with-gmp=$PREFIX"
	append_to MPFR_ADDITIONAL_PARAM "--with-gmp=$PREFIX"
	append_to MPC_ADDITIONAL_PARAM "--with-gmp=$PREFIX"
fi

if [ $USE_SYSTEM_MPFR == n ]; then
	download_extract $MPFR_SRC $MPFR_ARCHIVE $MPFR
	build $MPFR "--prefix=$PREFIX $MPC_ADDITIONAL_PARAM" "" install
	append_to GCC_ADDITIONAL_PARAM "--with-mpfr=$PREFIX"
fi

if [ $USE_SYSTEM_MPC == n ]; then
	download_extract $MPC_SRC $MPC_ARCHIVE $MPC
	build $MPC "--prefix=$PREFIX $MPC_ADDITIONAL_PARAM" "" install
	append_to GCC_ADDITIONAL_PARAM "--with-mpc=$PREFIX"
fi

build $BINUTILS "--target=$TARGET
                 --prefix=$PREFIX
                 --without-auto-load-safe-path
		 --disable-werror
		 --disable-sim" "" install
stage_done

build $GCC "--target=$TARGET 
    	    --prefix=$PREFIX 
            --disable-nls
            --with-newlib
            --enable-languages=c
            --with-arch=mips32
	    $GCC_ADDITIONAL_PARAM" all-gcc install-gcc
stage_done

export CFLAGS="-DDISABLE_PREFETCH"
build $NEWLIB "--target=$TARGET --prefix=$PREFIX" all install
unset CFLAGS

build $GCC "" all install
stage_done

build $QEMU "--target-list=mips-softmmu --prefix=$PREFIX" "" install
stage_done

log_end
