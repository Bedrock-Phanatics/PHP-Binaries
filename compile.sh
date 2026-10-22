#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/versions.env" || exit 1
test -s "$SCRIPT_DIR/sources.sha256" || { echo "Missing sources.sha256" >&2; exit 1; }
set -o pipefail

function write_out {
	echo "[$1] $2"
}

function write_error {
	write_out ERROR "$1" >&2
}

function write_status {
	echo -n " $1..."
}

function write_library {
  echo -n "[$1 $2]"
}

function write_caching {
  write_status "using cache"
}

function write_download {
	write_status "downloading"
}
function write_configure {
	write_status "configuring"
}
function write_compile {
	write_status "compiling"
}
function write_install {
	write_status "installing"
}
function write_done {
	echo " done!"
}
function cant_use_cache {
	if [ -f "$1/.compile.sh.cache" ]; then
		return 1
	else
		return 0
	fi
}
function mark_cache {
	touch "./.compile.sh.cache"
}

write_out "Quark" "PHP compiler for Linux, macOS and Android"
DIR="$(pwd)"
BASE_BUILD_DIR="$DIR/install_data"
#libtool and autoconf have a "feature" where it looks for install.sh/install-sh in ./ ../ and ../../
#this extra subdir makes sure that it doesn't find anything it's not supposed to be looking for.
BUILD_DIR="$BASE_BUILD_DIR/subdir"
LIB_BUILD_DIR="$BUILD_DIR/lib"
INSTALL_DIR="$DIR/bin/php7"
SYMBOLS_DIR="$DIR/bin-debug/php7"

date > "$DIR/install.log" 2>&1

uname -a >> "$DIR/install.log" 2>&1
write_out "INFO" "Checking dependencies"

COMPILE_SH_DEPENDENCIES=( make autoconf automake m4 getconf gzip bzip2 bison g++ git cmake pkg-config re2c)
ERRORS=0
for(( i=0; i<${#COMPILE_SH_DEPENDENCIES[@]}; i++ ))
do
	type "${COMPILE_SH_DEPENDENCIES[$i]}" >> "$DIR/install.log" 2>&1 || { write_error "Please install \"${COMPILE_SH_DEPENDENCIES[$i]}\""; ((ERRORS++)); }
done

type wget >> "$DIR/install.log" 2>&1 || type curl >> "$DIR/install.log" || { write_error "Please install \"wget\" or \"curl\""; ((ERRORS++)); }

if [ "$(uname -s)" == "Darwin" ]; then
	type glibtool >> "$DIR/install.log" 2>&1 || { write_error "Please install GNU libtool"; ((ERRORS++)); }
	export LIBTOOL=glibtool
	export LIBTOOLIZE=glibtoolize
	export PATH="/opt/homebrew/opt/bison/bin:$PATH"
	[[ $(bison --version) == "bison (GNU Bison) 3."* ]] || { write_error "MacOS bundled bison is too old. Install bison using Homebrew and update your PATH variable according to its instructions before running this script."; ((ERRORS++)); }
else
	type libtool >> "$DIR/install.log" 2>&1 || { write_error "Please install \"libtool\" or \"libtool-bin\""; ((ERRORS++)); }
	export LIBTOOL=libtool
	export LIBTOOLIZE=libtoolize
fi

if [ $ERRORS -ne 0 ]; then
	exit 1
fi

#if type llvm-gcc >/dev/null 2>&1; then
#	export CC="llvm-gcc"
#	export CXX="llvm-g++"
#	export AR="llvm-ar"
#	export AS="llvm-as"
#	export RANLIB=llvm-ranlib
#else
	export CC="gcc"
	export CXX="g++"
	#export AR="gcc-ar"
	export RANLIB=ranlib
	export STRIP="strip"
#fi

COMPILE_FOR_ANDROID=no
HAVE_MYSQLI="--enable-mysqlnd --with-mysqli=mysqlnd"
COMPILE_TARGET=""
IS_CROSSCOMPILE="no"
IS_WINDOWS="no"
DO_OPTIMIZE="yes"
DO_STATIC="no"
DO_CLEANUP="yes"
COMPILE_DEBUG="no"
HAVE_VALGRIND="--without-valgrind"
HAVE_OPCACHE="yes"
HAVE_XDEBUG="yes"
FSANITIZE_OPTIONS=""
HAVE_OPCACHE_JIT="no"

COMPILE_GD="no"

PM_VERSION_MAJOR=""

DOWNLOAD_INSECURE="no"
DOWNLOAD_CACHE="$DIR/download_cache"
SEPARATE_SYMBOLS="no"

PHP_VERSION_BASE="auto"

while getopts "::t:j:sdDxfgnva:P:c:l:Jiz:" OPTION; do

	case $OPTION in
		l)
			mkdir -p "$OPTARG"
			LIB_BUILD_DIR="$(cd "$OPTARG" && pwd)"
			write_out opt "Reusing previously built libraries in $LIB_BUILD_DIR if found"
			write_out WARNING "Reusing previously built libraries may break if different args were used!"
			;;
		c)
			mkdir -p "$OPTARG"
			DOWNLOAD_CACHE="$(cd "$OPTARG" && pwd)"
			write_out opt "Caching downloaded files in $DOWNLOAD_CACHE and reusing if available"
			;;
		t)
			write_out "opt" "Set target to $OPTARG"
			COMPILE_TARGET="$OPTARG"
			;;
		j)
			write_out "opt" "Set make threads to $OPTARG"
			THREADS="$OPTARG"
			;;
		d)
			write_out "opt" "Will compile everything with debugging symbols, will not remove sources"
			COMPILE_DEBUG="yes"
			DO_CLEANUP="no"
			DO_OPTIMIZE="no"
			CFLAGS="$CFLAGS -g"
			CXXFLAGS="$CXXFLAGS -g"
			;;
		D)
			write_out "opt" "Compiling with separated debugging symbols, but leaving optimizations enabled"
			SEPARATE_SYMBOLS="yes"
			CFLAGS="$CFLAGS -g"
			CXXFLAGS="$CXXFLAGS -g"
			;;
		x)
			write_out "opt" "Doing cross-compile"
			IS_CROSSCOMPILE="yes"
			;;
		s)
			write_out "opt" "Will compile everything statically"
			DO_STATIC="yes"
			CFLAGS="$CFLAGS -static"
			;;
		f)
			write_out "deprecated" "The -f flag is deprecated, as optimizations are now enabled by default unless -d (debug mode) is specified"
			;;
		g)
			write_out "opt" "Will enable GD2"
			COMPILE_GD="yes"
			;;
		n)
			write_out "opt" "Will not remove sources after completing compilation"
			DO_CLEANUP="no"
			;;
		v)
			write_out "opt" "Will enable valgrind support in PHP"
			HAVE_VALGRIND="--with-valgrind"
			;;
		a)
			write_out "opt" "Will pass -fsanitize=$OPTARG to compilers and linkers"
			FSANITIZE_OPTIONS="$OPTARG"
			;;
		P)
			PM_VERSION_MAJOR="$OPTARG"
			;;
		J)
			write_out "opt" "Compiling JIT support in OPcache"
			HAVE_OPCACHE_JIT="yes"
			;;
		i)
			write_out "opt" "Disabling SSL certificate verification for downloads"
			write_out "WARNING" "This is a security risk, please only use this if you know what you are doing!"
			DOWNLOAD_INSECURE="yes"
			;;
		z)
			PHP_VERSION_BASE="$OPTARG"
			;;
		\?)
			write_error "Invalid option: -$OPTARG"
			exit 1
			;;
	esac
done

function php_version_id {
	local PHP_VERSION="$1"
	local PHP_VERSION_MAJOR=$(echo "$PHP_VERSION" | cut -d. -f1)
	local PHP_VERSION_MINOR=$(echo "$PHP_VERSION" | cut -d. -f2)
	#TODO: patch is a pain because of suffixes and we don't really need it anyway

	# Use this for switching PHP version specific logic
	local PHP_VERSION_ID=$(((PHP_VERSION_MAJOR * 10000) + (PHP_VERSION_MINOR * 100)))
	echo "$PHP_VERSION_ID"
}

PREFERRED_PHP_VERSION_BASE=""
case $PM_VERSION_MAJOR in
	5)
		PREFERRED_PHP_VERSION_BASE="8.4"
		;;
	"")
		write_error "Use -P5 for the Quark v6 build"
		exit 1
		;;
	*)
		write_error "Legacy build target $PM_VERSION_MAJOR is not supported"
		exit 1
		;;
esac

write_out "opt" "Compiling PHP for Quark v6"

if [ "$PHP_VERSION_BASE" == "auto" ]; then
	PHP_VERSION_BASE="$PREFERRED_PHP_VERSION_BASE"
elif [ "$PHP_VERSION_BASE" != "$PREFERRED_PHP_VERSION_BASE" ]; then
	write_error "Unsupported PHP base version $PHP_VERSION_BASE"
	exit 1
fi

PHP_VERSION_ID=$(php_version_id "$PHP_VERSION")
write_out "opt" "Selected PHP $PHP_VERSION ($PHP_VERSION_ID)"

if [[ "$COMPILE_TARGET" != "linux64" && "$COMPILE_TARGET" != "linux" ]] || [[ "$(uname -sm)" != "Linux x86_64" ]] || [[ "$IS_CROSSCOMPILE" == yes || "$DO_STATIC" == yes ]]; then
	write_error "Quark native packaging requires a native, shared Linux x86_64 build"
	exit 1
fi
for dependency in python3 zig patchelf; do
	command -v "$dependency" >/dev/null || { write_error "Please install $dependency"; exit 1; }
done

#Needed to use aliases
shopt -s expand_aliases
type wget >> "$DIR/install.log" 2>&1
if [ $? -eq 0 ]; then
	wget_flags=""
	if [ "$DOWNLOAD_INSECURE" == "yes" ]; then
		wget_flags="--no-check-certificate"
	fi
	alias _download_file="wget $wget_flags -nv -O -"
else
	type curl >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		curl_flags=""
		if [ "$DOWNLOAD_INSECURE" == "yes" ]; then
			curl_flags="--insecure"
		fi
		alias _download_file="curl $curl_flags --fail --silent --show-error --location --globoff"
	else
		write_error "Neither curl nor wget found. Please install one and try again."
		exit 1
	fi
fi

function download_file {
	local url="$1"
	local prefix="$2"
	local cached_filename="$prefix-${url##*/}"
	local cached_path="$DOWNLOAD_CACHE/$cached_filename"
	local expected_hash
	local actual_hash
	local temp_path="$cached_path.tmp.$$"
	expected_hash=$(awk -v name="$cached_filename" '{ sub(/\r$/, "") } $2 == name { print $1 }' "$SCRIPT_DIR/sources.sha256")
	if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
		write_error "No SHA-256 pin for $cached_filename"
		return 1
	fi

	mkdir -p "$DOWNLOAD_CACHE" >> "$DIR/install.log" 2>&1
	if [[ -f "$cached_path" ]]; then
		actual_hash=$(hash_file "$cached_path")
		if [[ "$actual_hash" != "$expected_hash" ]]; then
			write_error "Discarding corrupt cached file $cached_filename"
			rm -f "$cached_path"
		else
			echo "Cache hit for URL: $url" >> "$DIR/install.log"
		fi
	fi
	if [[ ! -f "$cached_path" ]]; then
		echo "Downloading file to cache: $url" >> "$DIR/install.log"
		_download_file "$url" > "$temp_path" 2>> "$DIR/install.log" || { rm -f "$temp_path"; return 1; }
		actual_hash=$(hash_file "$temp_path")
		if [[ "$actual_hash" != "$expected_hash" ]]; then
			write_error "SHA-256 mismatch for $cached_filename"
			rm -f "$temp_path"
			return 1
		fi
		mv "$temp_path" "$cached_path" >> "$DIR/install.log" 2>&1
	fi
	cat "$cached_path" 2>> "$DIR/install.log"
}

function hash_file {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f1
	else
		shasum -a 256 "$1" | cut -d ' ' -f1
	fi
}

function download_from_mirror {
	download_file "https://github.com/pmmp/DependencyMirror/releases/download/mirror/$1" "$2"
}

#1: github repo
#2: tag or commit
#3: cache prefix
function download_github_src {
	download_file "https://github.com/$1/archive/$2.tar.gz" "$3"
}

GMP_ABI=""
TOOLCHAIN_PREFIX=""
OPENSSL_TARGET=""
CMAKE_GLOBAL_EXTRA_FLAGS=""

if [ "$IS_CROSSCOMPILE" == "yes" ]; then
	export CROSS_COMPILER="$PATH"
	if [ "$COMPILE_TARGET" == "android-aarch64" ]; then
		COMPILE_FOR_ANDROID=yes
		[ -z "$march" ] && march="armv8-a";
		[ -z "$mtune" ] && mtune=generic;
		TOOLCHAIN_PREFIX="aarch64-linux-musl"
		CONFIGURE_FLAGS="--host=$TOOLCHAIN_PREFIX"
		CFLAGS="-static $CFLAGS"
		CXXFLAGS="-static $CXXFLAGS"
		LDFLAGS="-static -static-libgcc -Wl,-static"
		DO_STATIC="yes"
		OPENSSL_TARGET="linux-aarch64"
		export ac_cv_func_fnmatch_works=yes #musl should be OK

		write_out "INFO" "Cross-compiling for Android ARMv8 (aarch64)"
	#TODO: add cross-compile for aarch64 platforms (ios, rpi)
	else
		write_error "Please supply a proper platform [android-aarch64] to cross-compile"
		exit 1
	fi
else
	if [[ "$COMPILE_TARGET" == "" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
		if [ "$(uname -m)" == "arm64" ]; then
			COMPILE_TARGET="mac-arm64"
		else
			COMPILE_TARGET="mac-x86-64"
		fi
	fi
	if [[ "$COMPILE_TARGET" == "linux" ]] || [[ "$COMPILE_TARGET" == "linux64" ]]; then
		[ -z "$march" ] && march=x86-64;
		[ -z "$mtune" ] && mtune=skylake;
		CFLAGS="$CFLAGS -m64"
		GMP_ABI="64"
		OPENSSL_TARGET="linux-x86_64"
		write_out "INFO" "Compiling for Linux x86_64"
	elif [[ "$COMPILE_TARGET" == "linux-arm64" ]] || [[ "$COMPILE_TARGET" == "linux-aarch64" ]]; then
		if [[ "$(uname -s)" != "Linux" ]] || { [[ "$(uname -m)" != "aarch64" ]] && [[ "$(uname -m)" != "arm64" ]]; }; then
			write_error "linux-arm64 must be built natively on an ARM64 Linux host"
			exit 1
		fi
		[ -z "$march" ] && march=armv8-a;
		[ -z "$mtune" ] && mtune=generic;
		GMP_ABI="64"
		OPENSSL_TARGET="linux-aarch64"
		write_out "INFO" "Compiling for Linux ARM64 (AArch64)"
	elif [[ "$COMPILE_TARGET" == "mac-x86-64" ]]; then
		[ -z "$march" ] && march=core2;
		[ -z "$mtune" ] && mtune=generic;
		[ -z "$MACOSX_DEPLOYMENT_TARGET" ] && export MACOSX_DEPLOYMENT_TARGET=10.9;
		CFLAGS="$CFLAGS -m64 -arch x86_64 -fomit-frame-pointer -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		LDFLAGS="$LDFLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		if [ "$DO_STATIC" == "no" ]; then
			LDFLAGS="$LDFLAGS -Wl,-rpath,@loader_path/../lib";
			export DYLD_LIBRARY_PATH="@loader_path/../lib"
		fi
		CFLAGS="$CFLAGS -Qunused-arguments"
		GMP_ABI="64"
		OPENSSL_TARGET="darwin64-x86_64-cc"
		CMAKE_GLOBAL_EXTRA_FLAGS="-DCMAKE_OSX_ARCHITECTURES=x86_64"
		write_out "INFO" "Compiling for MacOS x86_64"
	#TODO: add aarch64 platforms (ios, android, rpi)
	elif [[ "$COMPILE_TARGET" == "mac-arm64" ]]; then
		[ -z "$MACOSX_DEPLOYMENT_TARGET" ] && export MACOSX_DEPLOYMENT_TARGET=11.0;
		CFLAGS="$CFLAGS -arch arm64 -fomit-frame-pointer -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		LDFLAGS="$LDFLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
		if [ "$DO_STATIC" == "no" ]; then
			LDFLAGS="$LDFLAGS -Wl,-rpath,@loader_path/../lib";
			export DYLD_LIBRARY_PATH="@loader_path/../lib"
		fi
		CFLAGS="$CFLAGS -Qunused-arguments"
		GMP_ABI="64"
		OPENSSL_TARGET="darwin64-arm64-cc"
		CMAKE_GLOBAL_EXTRA_FLAGS="-DCMAKE_OSX_ARCHITECTURES=arm64"
		write_out "INFO" "Compiling for MacOS M1"
	elif [[ "$COMPILE_TARGET" != "" ]]; then
		write_error "Please supply a proper platform [mac-arm64 mac-x86-64 linux linux64 linux-arm64] to compile for"
		exit 1
	elif [ -z "$COMPILE_TARGET" ]; then
		if [ `getconf LONG_BIT` == "64" ]; then
			COMPILE_TARGET="linux64"
			write_out "INFO" "Compiling for current machine using 64-bit"
			if [[ "$(uname -m)" == "aarch64" ]] || [[ "$(uname -m)" == "arm64" ]]; then
				COMPILE_TARGET="linux-arm64"
				[ -z "$march" ] && march=armv8-a
				OPENSSL_TARGET="linux-aarch64"
			elif [ "$(uname -m)" == "x86_64" ]; then
				[ -z "$march" ] && march=x86-64
				OPENSSL_TARGET="linux-x86_64"
				CFLAGS="-m64 $CFLAGS"
			else
				write_error "Unsupported architecture $(uname -m)"
				exit 1
			fi
			[ -z "$mtune" ] && mtune=generic
			GMP_ABI="64"
		else
			write_out "ERROR" "Quark requires a 64-bit target"
			exit 1
		fi
	fi
fi

if [ "$DO_STATIC" == "yes" ]; then
	HAVE_OPCACHE="no"
	HAVE_OPCACHE_JIT="no"
	write_out "warning" "OPcache cannot be used on static PHP 8.4 builds; this may have a negative effect on performance"
	if [ "$FSANITIZE_OPTIONS" != "" ]; then
		write_out "warning" "Sanitizers cannot be used on static builds"
	fi
	if [ "$HAVE_XDEBUG" == "yes" ]; then
	  write_out "warning" "Xdebug cannot be built in static mode"
	  HAVE_XDEBUG="no"
	fi
fi

if [ "$TOOLCHAIN_PREFIX" != "" ]; then
		export CC="$TOOLCHAIN_PREFIX-gcc"
		export CXX="$TOOLCHAIN_PREFIX-g++"
		export AR="$TOOLCHAIN_PREFIX-ar"
		export RANLIB="$TOOLCHAIN_PREFIX-ranlib"
		export CPP="$TOOLCHAIN_PREFIX-cpp"
		export LD="$TOOLCHAIN_PREFIX-ld"
		export STRIP="$TOOLCHAIN_PREFIX-strip"
fi

echo "#include <stdio.h>" > test.c
echo "int main(void){" >> test.c
echo "printf(\"Hello world\n\");" >> test.c
echo "return 0;" >> test.c
echo "}" >> test.c


type $CC >> "$DIR/install.log" 2>&1 || { write_error "Please install \"$CC\""; exit 1; }

if [ -z "$THREADS" ]; then
	write_out "WARNING" "Only 1 thread is used by default. Increase thread count using -j (e.g. -j 4) to compile faster."	
	THREADS=1;
fi
[ -z "$march" ] && march=x86-64;
[ -z "$mtune" ] && mtune=generic;
[ -z "$CFLAGS" ] && CFLAGS="";

if [ "$DO_STATIC" == "no" ]; then
	[ -z "$LDFLAGS" ] && LDFLAGS="-Wl,-rpath='\$\$ORIGIN/../lib' -Wl,-rpath-link='\$\$ORIGIN/../lib'";
fi

[ -z "$CONFIGURE_FLAGS" ] && CONFIGURE_FLAGS="";

if [ "$mtune" != "none" ]; then
	$CC -march=$march -mtune=$mtune $CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="-march=$march -mtune=$mtune $CFLAGS"
	fi
else
	$CC -march=$march $CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="-march=$march $CFLAGS"
	fi
fi

if [ "$DO_OPTIMIZE" != "no" ]; then
	case "${PHP_BUILD_OPTIMIZATION:-O2}" in
		O2) CFLAGS="$CFLAGS -O2" ;;
		O3) CFLAGS="$CFLAGS -O3" ;;
		*) write_error "Unsupported PHP_BUILD_OPTIMIZATION"; exit 1 ;;
	esac
fi

if [ "$FSANITIZE_OPTIONS" != "" ]; then
	CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" $CC -fsanitize=$FSANITIZE_OPTIONS -o asan-test test.c >> "$DIR/install.log" 2>&1 && \
		chmod +x asan-test >> "$DIR/install.log" 2>&1 && \
		./asan-test >> "$DIR/install.log" 2>&1 && \
		rm asan-test >> "$DIR/install.log" 2>&1
	if [ $? -ne 0 ]; then
		write_out "ERROR" "One or more sanitizers are not working. Check install.log for details."
		exit 1
	else
		write_out "INFO" "All selected sanitizers are working"
	fi
fi

rm test.* >> "$DIR/install.log" 2>&1
rm test >> "$DIR/install.log" 2>&1

export CC="$CC"
export CXX="$CXX"
export CFLAGS="-fPIC $CFLAGS"
export CXXFLAGS="$CFLAGS $CXXFLAGS"
export LDFLAGS="$LDFLAGS"
export CPPFLAGS="$CPPFLAGS"
export LIBRARY_PATH="$INSTALL_DIR/lib:$LIBRARY_PATH"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"

#some stuff (like curl) makes assumptions about library paths that break due to different behaviour in pkgconf vs pkg-config
export PKG_CONFIG_ALLOW_SYSTEM_LIBS="yes"
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS="yes"

rm -r -f "$BASE_BUILD_DIR" >> "$DIR/install.log" 2>&1
rm -r -f bin/ >> "$DIR/install.log" 2>&1
mkdir -m 0755 "$BASE_BUILD_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 "$BUILD_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p $INSTALL_DIR >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p "$LIB_BUILD_DIR" >> "$DIR/install.log" 2>&1
cd "$BUILD_DIR"
set -e
trap 'status=$?; if [ "$status" -ne 0 ]; then tail -n 60 "$DIR/install.log"; fi; exit "$status"' EXIT

python3 "$SCRIPT_DIR/native.py" prepare "$BUILD_DIR/native" --jobs "$THREADS" >> "$DIR/install.log" 2>&1

#PHP
write_library "PHP" "$PHP_VERSION"
write_download

download_file "https://www.php.net/distributions/php-$PHP_VERSION.tar.gz" "php" | tar -zx >> "$DIR/install.log" 2>&1
mv "php-$PHP_VERSION" php
write_done

function build_zlib {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--static"
	else
		local EXTRA_FLAGS="--shared"
	fi

	write_library zlib "$ZLIB_VERSION"
	local zlib_dir="./zlib-$ZLIB_VERSION"

	if cant_use_cache "$zlib_dir"; then
		rm -rf "$zlib_dir"
		write_download
		download_github_src "madler/zlib" "v$ZLIB_VERSION" "zlib" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$zlib_dir"
		RANLIB=$RANLIB ./configure --prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$zlib_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	if [ "$DO_STATIC" != "yes" ]; then
		rm -f "$INSTALL_DIR/lib/libz.a"
	fi
	write_done
}

function build_gmp {
	export jm_cv_func_working_malloc=yes
	export ac_cv_func_malloc_0_nonnull=yes
	export jm_cv_func_working_realloc=yes
	export ac_cv_func_realloc_0_nonnull=yes

	if [ "$IS_CROSSCOMPILE" == "yes" ]; then
		local EXTRA_FLAGS=""
	else
		local EXTRA_FLAGS="--disable-assembly"
	fi

	write_library gmp "$GMP_VERSION"
	local gmp_dir="./gmp-$GMP_VERSION"

	if cant_use_cache "$gmp_dir"; then
		rm -rf "$gmp_dir"
		write_download
		download_from_mirror "gmp-$GMP_VERSION.tar.xz" "gmp" | tar -Jx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$gmp_dir"
		CFLAGS="-std=gnu17 $CFLAGS" RANLIB=$RANLIB ./configure --prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		--disable-posix-threads \
		--enable-static \
		--disable-shared \
		$CONFIGURE_FLAGS ABI="$GMP_ABI" >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$gmp_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_openssl {
	#OpenSSL
	OPENSSL_CMD="./config"
	if [ "$OPENSSL_TARGET" != "" ]; then
		local OPENSSL_CMD="./Configure $OPENSSL_TARGET"
	fi
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="no-shared -static"
	else
		local EXTRA_FLAGS="shared"
	fi

	write_library openssl "$OPENSSL_VERSION"
	local openssl_dir="./openssl-openssl-$OPENSSL_VERSION"

	if cant_use_cache "$openssl_dir"; then
		rm -rf "$openssl_dir"
		write_download
		download_github_src "openssl/openssl" "openssl-$OPENSSL_VERSION" "openssl" | tar -zx >> "$DIR/install.log" 2>&1

		write_configure
		cd "$openssl_dir"
		RANLIB=$RANLIB $OPENSSL_CMD \
		--prefix="$INSTALL_DIR" \
		--openssldir="$INSTALL_DIR" \
		--libdir="$INSTALL_DIR/lib" \
		no-asm \
		no-hw \
		no-engine \
		$EXTRA_FLAGS >> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$openssl_dir"
	fi
	write_install
	make install_sw >> "$DIR/install.log" 2>&1
	install -m644 apps/openssl.cnf "$INSTALL_DIR/openssl.cnf"
	cd ..
	write_done
}

function build_curl {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--enable-static --disable-shared"
	else
		local EXTRA_FLAGS="--disable-static --enable-shared"
	fi

	write_library curl "$CURL_VERSION"
	local curl_dir="./curl-$CURL_VERSION"
	if cant_use_cache "$curl_dir"; then
		rm -rf "$curl_dir"
		write_download
		download_file "https://curl.se/download/curl-$CURL_VERSION.tar.gz" "curl" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$curl_dir"
		if [[ "$(uname -s)" == "Darwin" ]]; then
			sed -i'.bak' 's/^CURL_CONVERT_INCLUDE_TO_ISYSTEM//' ./configure.ac
		fi
		RANLIB=$RANLIB ./configure --disable-dependency-tracking \
		--enable-ipv6 \
		--enable-optimize \
		--enable-http \
		--enable-ftp \
		--disable-dict \
		--enable-file \
		--without-librtmp \
		--disable-gopher \
		--disable-imap \
		--disable-pop3 \
		--disable-rtsp \
		--disable-smtp \
		--disable-telnet \
		--disable-tftp \
		--disable-ldap \
		--disable-ldaps \
		--without-libidn \
		--without-libidn2 \
		--without-brotli \
		--without-nghttp2 \
		--without-zstd \
		--without-libpsl \
		--with-zlib="$INSTALL_DIR" \
		--with-ssl="$INSTALL_DIR" \
		--enable-threaded-resolver \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$curl_dir"
	fi

	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_yaml {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--disable-shared --enable-static"
	else
		local EXTRA_FLAGS="--enable-shared --disable-static"
	fi

	write_library yaml "$YAML_VERSION"
	local yaml_dir="./libyaml-$YAML_VERSION"
	if cant_use_cache "$yaml_dir"; then
		rm -rf "$yaml_dir"
		write_download
		download_github_src "yaml/libyaml" "$YAML_VERSION" "yaml" | tar -zx >> "$DIR/install.log" 2>&1
		cd "$yaml_dir"
		./bootstrap >> "$DIR/install.log" 2>&1

		write_configure

		RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		sed -i=".backup" 's/ tests win32/ win32/g' Makefile

		write_compile
		make -j $THREADS all >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$yaml_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_leveldb {
	write_library leveldb "$LEVELDB_VERSION"
	local leveldb_dir="./leveldb-$LEVELDB_VERSION"
	if cant_use_cache "$leveldb_dir"; then
		rm -rf "$leveldb_dir"
		write_download
		download_github_src "pmmp/leveldb" "$LEVELDB_VERSION" "leveldb" | tar -zx >> "$DIR/install.log" 2>&1
		#download_file "https://github.com/Mojang/leveldb-mcpe/archive/$LEVELDB_VERSION.tar.gz" | tar -zx >> "$DIR/install.log" 2>&1

		write_configure
		cd "$leveldb_dir"
		if [ "$DO_STATIC" != "yes" ]; then
			local EXTRA_FLAGS="-DBUILD_SHARED_LIBS=ON"
		else
			local EXTRA_FLAGS=""
		fi
		cmake . \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			-DLEVELDB_BUILD_TESTS=OFF \
			-DLEVELDB_BUILD_BENCHMARKS=OFF \
			-DLEVELDB_SNAPPY=OFF \
			-DLEVELDB_ZSTD=OFF \
			-DLEVELDB_TCMALLOC=OFF \
			-DCMAKE_BUILD_TYPE=Release \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			$EXTRA_FLAGS \
			>> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$leveldb_dir"
	fi

	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libpng {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
	else
		local EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
	fi

	write_library libpng "$LIBPNG_VERSION"
	local libpng_dir="./libpng-$LIBPNG_VERSION"
	if cant_use_cache "$libpng_dir"; then
		rm -rf "$libpng_dir"
		write_download
		download_file "https://downloads.sourceforge.net/project/libpng/libpng16/$LIBPNG_VERSION/libpng-$LIBPNG_VERSION.tar.gz" "libpng" | tar -zx >> "$DIR/install.log" 2>&1

		write_configure
		cd "$libpng_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libpng_dir"
	fi

	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libjpeg {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
	else
		local EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
	fi

	write_library libjpeg "$LIBJPEG_VERSION"
	local libjpeg_dir="./libjpeg-$LIBJPEG_VERSION"
	if cant_use_cache "$libjpeg_dir"; then
		rm -rf "$libjpeg_dir"
		write_download
		download_from_mirror "jpegsrc.v$LIBJPEG_VERSION.tar.gz" "libjpeg" | tar -zx >> "$DIR/install.log" 2>&1
		mv jpeg-$LIBJPEG_VERSION "$libjpeg_dir"

		write_configure
		cd "$libjpeg_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libjpeg_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}


function build_libxml2 {
	write_library libxml2 "$LIBXML_VERSION"
	local libxml2_dir="./libxml2-$LIBXML_VERSION"

	if cant_use_cache "$libxml2_dir"; then
		rm -rf "$libxml2_dir"
		write_download
		download_file "https://download.gnome.org/sources/libxml2/2.15/libxml2-$LIBXML_VERSION.tar.xz" "libxml2" | tar -xJ >> "$DIR/install.log" 2>&1

		write_configure
		cd "$libxml2_dir"
		if [ "$DO_STATIC" == "yes" ]; then
			local EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
		else
			local EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
		fi
		./configure --prefix="$INSTALL_DIR" \
			--without-iconv \
			--without-python \
			--without-lzma \
			--with-zlib="$INSTALL_DIR" \
			--config-cache \
			$EXTRA_FLAGS \
			$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libxml2_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libzip {
	#libzip
	if [ "$DO_STATIC" == "yes" ]; then
		local CMAKE_LIBZIP_EXTRA_FLAGS="-DBUILD_SHARED_LIBS=OFF"
	fi

	write_library libzip "$LIBZIP_VERSION"
	local libzip_dir="./libzip-$LIBZIP_VERSION"
	if cant_use_cache "$libzip_dir"; then
		rm -rf "$libzip_dir"
		write_download
		download_github_src "nih-at/libzip" "v$LIBZIP_VERSION" "libzip" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$libzip_dir"

		#we're using OpenSSL for crypto
		cmake . \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			$CMAKE_LIBZIP_EXTRA_FLAGS \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			-DBUILD_TOOLS=OFF \
			-DBUILD_REGRESS=OFF \
			-DBUILD_EXAMPLES=OFF \
			-DBUILD_DOC=OFF \
			-DENABLE_BZIP2=OFF \
			-DENABLE_COMMONCRYPTO=OFF \
			-DENABLE_GNUTLS=OFF \
			-DENABLE_MBEDTLS=OFF \
			-DENABLE_LZMA=OFF \
			-DBUILD_OSSFUZZ=OFF \
			-DENABLE_ZSTD=OFF >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libzip_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_sqlite3 {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--disable-shared"
	else
		local EXTRA_FLAGS="--disable-static"
	fi

	write_library sqlite3 "$SQLITE3_VERSION"
	local sqlite3_dir="./sqlite3-$SQLITE3_VERSION"

	if cant_use_cache "$sqlite3_dir"; then
		rm -rf "$sqlite3_dir"
		write_download
		download_file "https://www.sqlite.org/2026/sqlite-autoconf-$SQLITE3_VERSION.tar.gz" "sqlite3" | tar -zx >> "$DIR/install.log" 2>&1
		mv sqlite-autoconf-$SQLITE3_VERSION "$sqlite3_dir" >> "$DIR/install.log" 2>&1
		write_configure
		cd "$sqlite3_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		--disable-dependency-tracking \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$sqlite3_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libdeflate {
	write_library libdeflate "$LIBDEFLATE_VERSION"
	local libdeflate_dir="./libdeflate-$LIBDEFLATE_VERSION"

	if [ "$DO_STATIC" == "yes" ]; then
		local CMAKE_LIBDEFLATE_EXTRA_FLAGS="-DLIBDEFLATE_BUILD_STATIC_LIB=ON -DLIBDEFLATE_BUILD_SHARED_LIB=OFF"
	else
		local CMAKE_LIBDEFLATE_EXTRA_FLAGS="-DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_SHARED_LIB=ON"
	fi

	if cant_use_cache "$libdeflate_dir"; then
		rm -rf "$libdeflate_dir"
		write_download
		download_github_src "ebiggers/libdeflate" "$LIBDEFLATE_VERSION" "libdeflate" | tar -zx >> "$DIR/install.log" 2>&1
		cd "$libdeflate_dir"
		write_configure
		cmake . \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			-DLIBDEFLATE_BUILD_GZIP=OFF \
			$CMAKE_LIBDEFLATE_EXTRA_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libdeflate_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

cd "$LIB_BUILD_DIR"

build_zlib
build_gmp
build_openssl
build_curl
build_yaml
build_leveldb
if [ "$COMPILE_GD" == "yes" ]; then
	build_libpng
	build_libjpeg
	HAS_GD="--enable-gd"
	HAS_LIBJPEG="--with-jpeg"
else
	HAS_GD=""
	HAS_LIBJPEG=""
fi

build_libxml2
build_libzip
build_sqlite3
build_libdeflate

# PECL libraries

# 1: extension name
# 2: extension version
# 3: URL to get .tar.gz from
# 4: Name of extracted directory to move
function get_extension_tar_gz {
	echo -n "  $1: downloading $2..."
	download_file "$3" "php-ext-$1" | tar -zx >> "$DIR/install.log" 2>&1
	mv "$4" "$BUILD_DIR/php/ext/$1"
	write_done
}

# 1: extension name
# 2: extension version
# 3: github user name
# 4: github repo name
# 5: version prefix (optional)
function get_github_extension {
	get_extension_tar_gz "$1" "$2" "https://github.com/$3/$4/archive/$5$2.tar.gz" "$4-$2"
}

# 1: extension name
# 2: extension version
function get_pecl_extension {
	get_extension_tar_gz "$1" "$2" "https://pecl.php.net/get/$1-$2.tgz" "$1-$2"
}

cd "$BUILD_DIR/php"
write_out "PHP" "Downloading additional extensions..."

get_github_extension "pmmpthread" "$EXT_QTHREADS_COMMIT" "Bedrock-Phanatics" "ext-qthreads"


get_github_extension "yaml" "$EXT_YAML_VERSION" "php" "pecl-file_formats-yaml"
#get_pecl_extension "yaml" "$EXT_YAML_VERSION"

get_github_extension "igbinary" "$EXT_IGBINARY_VERSION" "igbinary" "igbinary"

get_github_extension "recursionguard" "$EXT_RECURSIONGUARD_VERSION" "pmmp" "ext-recursionguard"

echo -n "  crypto: downloading $EXT_CRYPTO_VERSION..."
git clone https://github.com/bukka/php-crypto.git "$BUILD_DIR/php/ext/crypto" >> "$DIR/install.log" 2>&1
cd "$BUILD_DIR/php/ext/crypto"
git checkout "$EXT_CRYPTO_VERSION" >> "$DIR/install.log" 2>&1
git submodule update --init --recursive >> "$DIR/install.log" 2>&1
cd "$BUILD_DIR"
write_done

get_github_extension "leveldb" "$EXT_LEVELDB_VERSION" "pmmp" "php-leveldb"

get_github_extension "chunkutils2" "$EXT_CHUNKUTILS2_VERSION" "pmmp" "ext-chunkutils2"

get_github_extension "libdeflate" "$EXT_LIBDEFLATE_VERSION" "pmmp" "ext-libdeflate"

get_github_extension "morton" "$EXT_MORTON_VERSION" "pmmp" "ext-morton"

get_github_extension "xxhash" "$EXT_XXHASH_VERSION" "pmmp" "ext-xxhash"

get_github_extension "arraydebug" "$EXT_ARRAYDEBUG_VERSION" "pmmp" "ext-arraydebug"

get_github_extension "encoding" "$EXT_ENCODING_VERSION" "pmmp" "ext-encoding"

get_github_extension "webrtc" "$EXT_WEBRTC_COMMIT" "axolotl-pm" "ext-webrtc"

echo -n "  snappy: downloading $EXT_SNAPPY_VERSION..."
git clone --branch "$EXT_SNAPPY_VERSION" --depth 1 https://github.com/kjdev/php-ext-snappy.git "$BUILD_DIR/php/ext/snappy" >> "$DIR/install.log" 2>&1
test "$(git -C "$BUILD_DIR/php/ext/snappy" rev-parse HEAD)" = "$EXT_SNAPPY_COMMIT"
git -C "$BUILD_DIR/php/ext/snappy" submodule update --init --depth 1 snappy >> "$DIR/install.log" 2>&1
write_done

echo -n "  toml: downloading $EXT_TOML_VERSION..."
git clone https://github.com/TrixNEW/ext-toml.git "$BUILD_DIR/php/ext/toml" >> "$DIR/install.log" 2>&1 &&
	git -C "$BUILD_DIR/php/ext/toml" checkout "$EXT_TOML_COMMIT" >> "$DIR/install.log" 2>&1 &&
	test "$(git -C "$BUILD_DIR/php/ext/toml" rev-parse HEAD)" = "$EXT_TOML_COMMIT" ||
	{ write_error "Failed to verify ext-toml source"; exit 1; }
write_done

cafile=""
if [[ "$COMPILE_TARGET" == "mac"* ]]; then
	cafile="/etc/ssl/cert.pem"
elif [[ "$COMPILE_TARGET" == "linux"* ]] && [[ "$IS_CROSSCOMPILE" != "yes" ]]; then
	#try to detect the correct location from the current system
	for file in \
		"$SSL_CERT_FILE" \
		"/etc/ssl/certs/ca-certificates.crt" \
		"/etc/pki/tls/certs/ca-bundle-crt" \
		"/etc/ssl/cert.pem";
	do
		if [ -f "$file" ]; then
			cafile="$file"
			break
		fi
	done
fi
if [ -z "$cafile" ]; then
	write_out "WARNING" "Don't know where to find SSL CA bundle for this target; PHP code won't be able to safely access https:// links unless openssl.cafile is configured to the correct path in php.ini"
else
	write_out "INFO" "System SSL CA bundle detected as $cafile; if this is not correct, please adjust openssl.cafile in php.ini"

fi

write_library "PHP" "$PHP_VERSION"

write_configure
cd php
rm -f ./aclocal.m4 >> "$DIR/install.log" 2>&1
rm -rf ./autom4te.cache/ >> "$DIR/install.log" 2>&1
rm -f ./configure >> "$DIR/install.log" 2>&1

./buildconf --force >> "$DIR/install.log" 2>&1

#hack for curl with pkg-config (ext/curl doesn't give --static to pkg-config on static builds)
if [ "$DO_STATIC" == "yes" ]; then
	if [ -z "$PKG_CONFIG" ]; then
		PKG_CONFIG="$(which pkg-config)" || true
	fi
	if [ ! -z "$PKG_CONFIG" ]; then
		#only export this if pkg-config exists, otherwise leave it (it'll fall back to curl-config)

		echo '#!/bin/sh' > "$BUILD_DIR/pkg-config-wrapper"
		echo 'exec '$PKG_CONFIG' "$@" --static' >> "$BUILD_DIR/pkg-config-wrapper"
		chmod +x "$BUILD_DIR/pkg-config-wrapper"
		export PKG_CONFIG="$BUILD_DIR/pkg-config-wrapper"
	fi
fi


if [ "$IS_CROSSCOMPILE" == "yes" ]; then
	sed -i=".backup" 's/pthreads_working=no/pthreads_working=yes/' ./configure
	if [ "$IS_WINDOWS" != "yes" ]; then
		if [ "$COMPILE_FOR_ANDROID" == "no" ]; then
			export LIBS="$LIBS -lpthread -ldl -lresolv"
		else
			#workarounds for musl 1.2.5
			export php_cv_type_cookie_off64_t=no
			export php_cv_func_pread=yes
			export php_cv_func_pwrite=yes
			export LIBS="$LIBS -lpthread -lresolv"
		fi
	else
		export LIBS="$LIBS -lpthread"
	fi

	mv ext/mysqlnd/config9.m4 ext/mysqlnd/config.m4
	sed  -i=".backup" "s{ext/mysqlnd/php_mysqlnd_config.h{config.h{" ext/mysqlnd/mysqlnd_portability.h
elif [ "$DO_STATIC" == "yes" ]; then
	export LIBS="$LIBS -ldl"
fi

if [ "$IS_WINDOWS" != "yes" ]; then
	HAVE_PCNTL="--enable-pcntl"
else
	HAVE_PCNTL="--disable-pcntl"
	cp -f ./win32/build/config.* ./main >> "$DIR/install.log" 2>&1
	sed 's:@PREFIX@:$DIR/bin/php7:' ./main/config.w32.h.in > ./wmain/config.w32.h 2>> "$DIR/install.log"
fi

if [[ "$(uname -s)" == "Darwin" ]] && [[ "$IS_CROSSCOMPILE" != "yes" ]]; then
	sed -i=".backup" 's/flock_type=unknown/flock_type=bsd/' ./configure
	export EXTRA_CFLAGS=-lresolv
fi

if [[ "$COMPILE_DEBUG" == "yes" ]]; then
	HAS_DEBUG="--enable-debug"
else
	HAS_DEBUG="--disable-debug"
fi

if [ "$FSANITIZE_OPTIONS" != "" ]; then
	CFLAGS="$CFLAGS -fsanitize=$FSANITIZE_OPTIONS -fno-omit-frame-pointer"
	CXXFLAGS="$CXXFLAGS -fsanitize=$FSANITIZE_OPTIONS -fno-omit-frame-pointer"
	LDFLAGS="-fsanitize=$FSANITIZE_OPTIONS $LDFLAGS"
fi

RANLIB=$RANLIB CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" ./configure $PHP_OPTIMIZATION --prefix="$INSTALL_DIR" \
--exec-prefix="$INSTALL_DIR" \
--with-curl \
--with-zlib \
--with-gmp \
--with-yaml \
--with-openssl \
--with-zip \
--with-libdeflate \
$HAS_LIBJPEG \
$HAS_GD \
--with-leveldb="$INSTALL_DIR" \
--without-readline \
$HAS_DEBUG \
--enable-chunkutils2 \
--enable-morton \
--enable-mbstring \
--disable-mbregex \
--enable-calendar \
--enable-pmmpthread \
--enable-fileinfo \
--with-libxml \
--enable-xml \
--enable-dom \
--enable-simplexml \
--enable-xmlreader \
--enable-xmlwriter \
--disable-cgi \
--disable-phpdbg \
--disable-session \
--without-pear \
--without-iconv \
--with-pdo-sqlite \
--with-pdo-mysql \
--with-pic \
--enable-phar \
--enable-ctype \
--enable-sockets \
--enable-shared=no \
--enable-static=yes \
--enable-shmop \
--enable-zts \
--disable-short-tags \
$HAVE_PCNTL \
$HAVE_MYSQLI \
--enable-bcmath \
--enable-cli \
--enable-ftp \
--enable-opcache=$HAVE_OPCACHE \
--enable-opcache-jit=$HAVE_OPCACHE_JIT \
--enable-igbinary \
--with-crypto \
--enable-recursionguard \
--enable-xxhash \
--enable-arraydebug \
--enable-encoding \
--enable-snappy \
--enable-toml \
--enable-webrtc=shared \
--with-libdatachannel="$BUILD_DIR/native/native" \
$HAVE_VALGRIND \
$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
write_compile
if [ "$COMPILE_FOR_ANDROID" == "yes" ]; then
	sed -i=".backup" 's/-export-dynamic/-all-static/g' Makefile
fi
sed -i=".backup" 's/PHP_BINARIES. pharcmd$/PHP_BINARIES)/g' Makefile
sed -i=".backup" 's/install-programs install-pharcmd$/install-programs/g' Makefile

if [[ "$DO_STATIC" == "yes" ]]; then
	sed -i=".backup" 's/--mode=link $(CC)/--mode=link $(CXX)/g' Makefile
fi

make -j $THREADS >> "$DIR/install.log" 2>&1
write_install
make install >> "$DIR/install.log" 2>&1

function relativize_macos_library_paths {
	IFS=$'\n' OTOOL_OUTPUT=($(otool -L "$1"))

	for (( i=0; i<${#OTOOL_OUTPUT[@]}; i++ ))
		do
		CURRENT_DYLIB_NAME=$(echo ${OTOOL_OUTPUT[$i]} | sed 's# (compatibility version .*##' | xargs)
		if [[ "$CURRENT_DYLIB_NAME" == "$INSTALL_DIR/"* ]]; then
			NEW_DYLIB_NAME="@loader_path/..${CURRENT_DYLIB_NAME#"$INSTALL_DIR"}"
			if (( i == 1 )) && [[ "$1" == *.dylib* ]]; then
				install_name_tool -id "$NEW_DYLIB_NAME" "$1" >> "$DIR/install.log" 2>&1 || exit 1
			else
				install_name_tool -change "$CURRENT_DYLIB_NAME" "$NEW_DYLIB_NAME" "$1" >> "$DIR/install.log" 2>&1 || exit 1
			fi
		elif [[ "$CURRENT_DYLIB_NAME" != "/usr/lib/"* ]] && [[ "$CURRENT_DYLIB_NAME" != "/System/"* ]] && [[ "$CURRENT_DYLIB_NAME" != "@loader_path"* ]] && [[ "$CURRENT_DYLIB_NAME" != "@rpath"* ]]; then
			write_out "ERROR" "Detected linkage to non-local non-system library $CURRENT_DYLIB_NAME by $1"
			exit 1
		fi
	done
}

function relativize_macos_all_libraries_paths {
	set +e
	for _library in $(find "$INSTALL_DIR" -name "*.dylib" -o -name "*.so"); do
		relativize_macos_library_paths "$_library"
	done
	set -e
}

if [[ "$(uname -s)" == "Darwin" ]] && [[ "$IS_CROSSCOMPILE" != "yes" ]]; then
	set +e
	install_name_tool -delete_rpath "$INSTALL_DIR/lib" "$INSTALL_DIR/bin/php" >> "$DIR/install.log" 2>&1

	relativize_macos_library_paths "$INSTALL_DIR/bin/php"

	relativize_macos_all_libraries_paths
	set -e
fi

write_status "generating php.ini"
trap - DEBUG
echo "memory_limit=1024M" >> "$INSTALL_DIR/bin/php.ini"
echo "date.timezone=UTC" >> "$INSTALL_DIR/bin/php.ini"
echo "short_open_tag=0" >> "$INSTALL_DIR/bin/php.ini"
echo "asp_tags=0" >> "$INSTALL_DIR/bin/php.ini"
echo "phar.require_hash=1" >> "$INSTALL_DIR/bin/php.ini"
echo "igbinary.compact_strings=0" >> "$INSTALL_DIR/bin/php.ini"
if [[ "$COMPILE_DEBUG" == "yes" ]]; then
	echo "zend.assertions=1" >> "$INSTALL_DIR/bin/php.ini"
else
	echo "zend.assertions=-1" >> "$INSTALL_DIR/bin/php.ini"
fi
echo "error_reporting=-1" >> "$INSTALL_DIR/bin/php.ini"
echo "display_errors=1" >> "$INSTALL_DIR/bin/php.ini"
echo "display_startup_errors=1" >> "$INSTALL_DIR/bin/php.ini"
echo "recursionguard.enabled=0 ;disabled due to minor performance impact, only enable this if you need it for debugging" >> "$INSTALL_DIR/bin/php.ini"
if [ -n "$cafile" ]; then
	echo "openssl.cafile=$cafile" >> "$INSTALL_DIR/bin/php.ini"
fi

if [ "$HAVE_OPCACHE" == "yes" ]; then
	echo "zend_extension=opcache.so" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.enable=1" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.enable_cli=1" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.save_comments=1" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.validate_timestamps=1" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.revalidate_freq=0" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.file_update_protection=0" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.jit=disable" >> "$INSTALL_DIR/bin/php.ini"
	echo "opcache.jit_buffer_size=0" >> "$INSTALL_DIR/bin/php.ini"
fi
if [[ "$COMPILE_TARGET" == "mac-"* ]]; then
	#we don't have permission to allocate executable memory on macOS due to not being codesigned
	#workaround this for now by disabling PCRE JIT
	echo "" >> "$INSTALL_DIR/bin/php.ini"
	echo "pcre.jit=off" >> "$INSTALL_DIR/bin/php.ini"
fi

write_done

if [[ "$HAVE_XDEBUG" == "yes" ]]; then
	get_github_extension "xdebug" "$EXT_XDEBUG_VERSION" "xdebug" "xdebug"
	write_library "xdebug" "$EXT_XDEBUG_VERSION"
	cd "$BUILD_DIR/php/ext/xdebug"
	write_configure
	"$INSTALL_DIR/bin/phpize" >> "$DIR/install.log" 2>&1
	./configure --with-php-config="$INSTALL_DIR/bin/php-config" >> "$DIR/install.log" 2>&1
	write_compile
	make -j4 >> "$DIR/install.log" 2>&1
	write_install
	make install >> "$DIR/install.log" 2>&1
	echo "" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo ";zend_extension=xdebug.so" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo ";https://xdebug.org/docs/all_settings#mode" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo "xdebug.mode=off" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo "xdebug.start_with_request=yes" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo ";The following overrides allow profiler, gc stats and traces to work correctly in ZTS" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo "xdebug.profiler_output_name=cachegrind.%s.%p.%r" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo "xdebug.gc_stats_output_name=gcstats.%s.%p.%r" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	echo "xdebug.trace_output_name=trace.%s.%p.%r" >> "$INSTALL_DIR/bin/php.ini" 2>&1
	write_done
	write_out INFO "Xdebug is included, but disabled by default. To enable it, change 'xdebug.mode' in your php.ini file."
fi


cd "$DIR"
echo "extension=webrtc.so" >> "$INSTALL_DIR/bin/php.ini"
python3 "$SCRIPT_DIR/native.py" install "$BUILD_DIR/native" --php-source "$BUILD_DIR/php" --runtime "$INSTALL_DIR" >> "$DIR/install.log" 2>&1

if [ "$DO_CLEANUP" == "yes" ]; then
	write_out "INFO" "Cleaning up"
	rm -r -f "$BUILD_DIR" >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/curl"* >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/curl-config"* >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/c_rehash"* >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/openssl"* >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/man" >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/share/man" >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/php" >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/misc" >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/lib/"*.a >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/lib/"*.la >> "$DIR/install.log" 2>&1
	rm -r -f "$INSTALL_DIR/include" >> "$DIR/install.log" 2>&1
fi

if [ "$SEPARATE_SYMBOLS" != "no" ]; then
	echo -n "[INFO] Separating debugging symbols into $SYMBOLS_DIR..."
	rm -rf "$SYMBOLS_DIR" || true 2>&1
	mkdir -p "$SYMBOLS_DIR" || true 2>&1
	cp -r "$INSTALL_DIR"/* "$SYMBOLS_DIR"
	cd "$INSTALL_DIR"
	find "lib" \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dylib.*' \) -print0 | while IFS= read -r -d '' file; do
		"$STRIP" -S "$file" >> "$DIR/install.log" 2>&1 || true #if this fails, this probably isn't an executable binary
	done
	for file in "bin/"*; do
		"$STRIP" -S "$file" >> "$DIR/install.log" 2>&1 || true #if this fails, this probably isn't an executable binary
	done
	cd "$DIR"
	write_done
fi

date >> "$DIR/install.log" 2>&1
write_out "Quark" "PHP was installed in $INSTALL_DIR."
write_out "Quark" "If it fails to start, attach install.log to a repository issue."
