#!/bin/sh
#
#  mkdist.sh
#  CrossPack-AVR
#
#  Created by Christian Starkjohann on 2012-11-28.
#  Copyright (c) 2012 Objective Development Software GmbH.

pkgUnixName=CrossPack-AVR
pkgPrettyName="CrossPack for AVR Development"
pkgUrlName=crosspack    # name used for http://www.obdev.at/$pkgUrlName
pkgVersion=20121128

version_make=3.82
version_gdb=7.5
version_gmp=4.3.2
version_mpfr=3.1.0
version_mpc=0.9
version_libusb=1.0.8
version_headers=6.1.0.1157
version_avarice=2.13
version_avrdude=5.11.1
version_simulavr=0.1.2.7
# We want to add simavr to the distribution, but it does not compile easily...

version_binutils=2.22
version_gcc=4.6.2
#version_gcc3=3.4.6
version_avrlibc=1.8.0

debug=false
if [ "$1" = debug ]; then
    debug=true
fi

prefix="/usr/local/$pkgUnixName-$pkgVersion"
configureArgs="--disable-dependency-tracking --disable-nls --disable-werror"

umask 0022

xcodepath="$(xcode-select -print-path)"
sysroot="$xcodepath/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk"
# Ensure that no references to older versions of CrossPack AVR are in PATH:
PATH="$(echo "$PATH" | sed -e "s|:/usr/local/$pkgUnixName/bin||g")"
# Add new install destination and Xcode tools to PATH:
PATH="$prefix/bin:$PATH:$xcodepath/usr/bin:$xcodepath/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export PATH

commonCFLAGS="-isysroot $sysroot"
# Build libraries for i386 and x86_64, but executables i386 only so that the
# size of the distribution is not unecessary large.
buildCFLAGS="$commonCFLAGS -arch i386"  # used for tool chain


###############################################################################
# Check prerequisites first
###############################################################################

if ! autoconf -V >/dev/null 2>&1; then
    echo "autoconf version 2.63 or higher is required. Please download and install it."
    exit
fi


###############################################################################
# Obtaining the packages from the net
###############################################################################

# update the 'patches' directory by downloading current patches from freebsd ports
updatePatches()
{
    # Find out what is the difference between
    # http://www.freebsd.org/cgi/cvsweb.cgi/ports
    # and
    # http://www.freebsd.org/cgi/cvsweb.cgi/~checkout~/ports
    tmpdir="/tmp/avrcrosspack-tmp-$$"
    rm -rf "$tmpdir"
    mkdir "$tmpdir"
    if [ ! -d patches ]; then
        mkdir patches
    fi
    for i in avr-gdb; do
        echo "=== Fetching patches for $i"
        url="http://www.freebsd.org/cgi/cvsweb.cgi/ports/devel/$i/files/files.tar.gz?tarball=1"
        curl --location --progress-bar "$url" | tar -C "$tmpdir" -x -z -f -
        base=$(echo "$i" | sed -e 's/^avr-//')
        version=""
        for file in "$tmpdir/files"/*; do
            if [ "$file" != "$tmpdir/files/*" ]; then
                version=$(echo "$file" | sed -e "s/^.*$base\(-[0-9][^-]*\).*$/\1/")
                if [ "$version" != "$file" ]; then
                    break
                else
                    version=""
                fi
            fi
        done
        dir="patches/$base$version"
        if [ ! -d "$dir" ]; then
            mkdir "$dir"
        fi
        mv -f "$tmpdir/files/"* "$dir/"
        rm -rf "$tmpdir/files"
    done
    rm -rf "$tmpdir"
}

# download a package and unpack it
getPackage() # <package-name>
{
    url="$1"
    package=$(basename "$url")
    if [ ! -f "packages/$package" ]; then
        echo "=== Downloading package $package"
        curl --location --progress-bar -o "packages/$package" "$url"
    fi
}


###############################################################################
# helper for building fat libraries
###############################################################################

lipoHelper() # <action> <file>
{
    action="$1"
    file="$2"
    if [ "$action" = rename ]; then
        if echo "$file" | egrep '\.(i386|x86_64)$' >/dev/null; then
            : # already renamed
        elif arch=$(lipo -info "$file" 2>/dev/null); then # true if lipo is applicable
            arch=$(echo $arch | sed -e 's/^.*: \([^:]*\)$/\1/g')
            case "$arch" in
            x86_64|i386)
                mv "$file" "$file.$arch";;
            esac
        fi
    elif [ "$action" = merge ]; then
        base=$(echo "$file" | sed -E -e 's/[.](i386|x86_64)$//g')
        if [ ! -f "$base.x86_64" ]; then
            mv -f "$base.i386" "$base"
        elif [ ! -f "$base.i386" ]; then
            mv -f "$base.x86_64" "$base"
        elif lipo -create -arch i386 "$base.i386" -arch x86_64 "$base.x86_64" -output "$base"; then
            rm -f "$base.i386" "$base.x86_64"
        fi
    else
        echo "Invalid action $1"
    fi
}

lipoHelperRecursive() # <action> <baseDir>
{
    action="$1"
    baseDir="$2"
    if [ "$action" = "rename" ]; then
        find "$baseDir" -type f -and '(' -name '*.a' -or -name '*.dylib*' -or -name '*.so*' -or -perm -u+x ')' -print | while read i; do
            lipoHelper "$action" "$i"
        done
    else
        find "$baseDir" -type f -and -name '*.i386' -print | while read i; do
            lipoHelper "$action" "$i"
        done
    fi
}


###############################################################################
# building the packages
###############################################################################

# checkreturn is used to check for exit status of subshell
checkreturn()
{
	rval="$?"
	if [ "$rval" != 0 ]; then
		exit "$rval"
	fi
}

applyPatches()  # <package-name>
{
    name="$1"
    base=$(echo "$name" | sed -e 's/-[.0-9]\{1,\}$//g')
    for patchdir in patches patches-local; do
        for target in "$base" "$name"; do
            if [ -d "$patchdir/$target" ]; then
                echo "=== applying patches from $patchdir/$target"
                (
                    cd "compile/$name"
                    for patch in "../../$patchdir/$target/"*; do
                        if [ "$patch" != "../$patchdir/$target/*" ]; then
                            echo "    -" "$(basename "$patch")"
                            if patch --silent -f -p0 < "$patch"; then
                                :
                            else
                                echo "*** FreeBSD Patch $patch failed!"
                                echo "Press enter to continue anyway"
                                read
                            fi
                        fi
                    done
                )
            fi
        done
    done
}

unpackPackage() # <package-name>
{
    name="$1"
    archive=$(echo "packages/$name"* | awk '{print $1}')    # wildcard expands to compression extension
    extension=$(echo "$archive" | awk -F . '{print $NF}')
    zipOption="-z"
    if [ "$extension" = "bz2" ]; then
        zipOption="-j"
    fi
    if [ ! -d compile ]; then
        mkdir compile
    fi
    echo "=== unpacking $name"
    rm -rf "compile/$name"
    mkdir "compile/tmp"
    if [ "$extension" = "zip" ]; then
        unzip -d compile/tmp "$archive"
    else
        tar -x $zipOption -C compile/tmp -f "$archive"
    fi
    mv compile/tmp/* "compile/$name"
    rm -rf compile/tmp
    if [ ! -d "compile/$name" ]; then
        echo "*** Package $name does not contain expected directory"
        exit 1
    fi
}

mergeAVRHeaders()
{
    for i in "../avr-headers-$version_headers"/io?*.h; do
        cp -f "$i" include/avr/
    done
    # We must merge the conditional includes of both versions of io.h since we
    # want to build a superset:
    awk 'BEGIN {
            line = 0;
            insertAt = 0;
            recordLines = 1;
        }

        {
            if (file != FILENAME) {     # file changed
                if (file != "") {
                    recordLines = 0;    # not first file
                }
                file = FILENAME;
            }
            if (def != "" && match($0, "^#[ \t]*include")) {
                includes[def] = $0;
            } else if (match($0, "^#[a-zA-Z]+[ \t]+[(]?defined")) {
                if (insertAt == 0) {
                    insertAt = line;
                }
                def = $3;
                gsub("[^a-zA-Z0-9_]", "", def);
            } else {
                def = "";
                if (recordLines) {
                    lines[line++] = $0;
                }
            }
        }

        END {
            for (i = 0; i < line; i++) {
                if (i == insertAt) {
                    prefix = "#if";
                    for (def in includes) {
                        printf("%s defined (%s)\n%s\n", prefix, def, includes[def]);
                        prefix = "#elif";
                    }
                }
                print lines[i];
            }
        }
    ' "../avr-headers-$version_headers/io.h" include/avr/io.h > include/avr/io.h.new
    mv -f include/avr/io.h.new include/avr/io.h
}

buildPackage() # <package-name> <known-product> <additional-config-args...>
{
    name="$1"
    product="$2"
    if [ -f "$product" ]; then
        return  # the product we generate exists already
    fi
    shift; shift
    echo "################################################################################"
    echo "Building $name"
    echo "################################################################################"
    cwd=$(pwd)
	base=$(echo "$name" | sed -e 's/-[.0-9]\{1,\}$//g')
    version=$(echo "$name" | sed -e 's/^.*-\([.0-9]\{1,\}\)$/\1/')
    unpackPackage "$name"
    applyPatches "$name"
    (
        cd "compile/$name"
        if [ "$base" = avr-binutils ]; then
            # we remove version check because we can't guarantee a particular version
            sed -ibak 's/  \[m4_fatal(\[Please use exactly Autoconf \]/  \[m4_errprintn(\[Please use exactly Autoconf \]/g' ./config/override.m4
            (cd ld; autoreconf)
        fi
        if [ "$base" = avr-libc ]; then
            mergeAVRHeaders
        fi
        if [ -x ./bootstrap ]; then # avr-libc builds lib tree from this script
            ./bootstrap             # If the package has a bootstrap script, run it
            if [ "$base" = simulavr ]; then
                autoconf            # additional magic needed for simulavr
                ./bootstrap
            fi
        fi
        if [ "$base" = avr-gcc -o "$base" = simulavr ]; then    # build gcc in separate dir, it will fail otherwise
            mkdir build-objects
            rm -rf build-objects/*
            cd build-objects
            rootdir=..
        else
            rootdir=.
        fi
        if [ "$base" != avr-libc ]; then
            export CC="xcrun gcc $buildCFLAGS"
            export CXX="xcrun g++ $buildCFLAGS"
        fi
        make distclean 2>/dev/null
        echo "cwd=`pwd`"
        echo $rootdir/configure --prefix="$prefix" $configureArgs "$@"
        $rootdir/configure --prefix="$prefix" $configureArgs "$@" || exit 1
        if [ -d $rootdir/bfd ]; then # if we build GNU binutils, ensure we update headers after patching
            make    # expect this make to fail, but at least we have configured everything
            (
                cd $rootdir/bfd
                rm -f bfd-in[23].h libbfd.h libcoff.h
                make headers
            )
        fi
        if ! make; then
            echo "################################################################################"
            echo "Retrying build of $name -- first attempt failed"
            echo "################################################################################"
            if ! make; then
                echo "################################################################################"
                echo "Building $name failed, even after retry."
                echo "################################################################################"
                exit 1
            fi
        fi
        make install || exit 1
        case "$product" in
            "$cwd"/*)   # install destination is in source tree -> do nothing
                echo "package $name is not part of distribution"
                ;;
            *)          # install destination is not in source tree
                mkdir "$prefix" 2>/dev/null
                mkdir "$prefix/etc" 2>/dev/null
                mkdir "$prefix/etc/versions.d" 2>/dev/null
                echo "$base: $version" >"$prefix/etc/versions.d/$base"
                ;;
        esac
    )
    checkreturn
}

copyPackage() # <package-name> <destination>
{
    name="$1"
    destination="$2"
    unpackPackage "$name"
    mkdir -p "$destination" 2>/dev/null
    echo "=== installing files in $name"
    mv "compile/$name/"* "$destination/"
    chmod -R a+rX "$destination"
}


###############################################################################
# main code
###############################################################################

if ! "$debug"; then
    rm -rf math
    rm -rf compile
    updatePatches
    rm -rf "$prefix"
fi

if [ ! -d packages ]; then
    mkdir packages
fi

atmelBaseURL="http://distribute.atmel.no/tools/opensource/Atmel-AVR-Toolchain-3.4.1.830/avr/"
getPackage "$atmelBaseURL/avr-binutils-$version_binutils.tar.gz"
getPackage "$atmelBaseURL/avr-gcc-$version_gcc.tar.gz"
getPackage "$atmelBaseURL/avr-headers-$version_headers.zip"
getPackage "$atmelBaseURL/avr-libc-$version_avrlibc.tar.gz"
#getPackage http://ftp.sunet.se/pub/gnu/gcc/releases/gcc-"$version_gcc3"/gcc-"$version_gcc3".tar.bz2

getPackage http://ftp.sunet.se/pub/gnu/make/make-"$version_make".tar.bz2
getPackage ftp://ftp.gmplib.org/pub/gmp-"$version_gmp"/gmp-"$version_gmp".tar.bz2
getPackage http://ftp.sunet.se/pub/gnu/mpfr/mpfr-"$version_mpfr".tar.bz2
getPackage http://www.multiprecision.org/mpc/download/mpc-"$version_mpc".tar.gz
getPackage http://ftp.sunet.se/pub/gnu/gdb/gdb-"$version_gdb".tar.bz2
getPackage http://downloads.sourceforge.net/avarice/avarice-"$version_avarice".tar.bz2
getPackage http://download.savannah.gnu.org/releases/avr-libc/avr-libc-manpages-"$version_avrlibc".tar.bz2
getPackage http://download.savannah.gnu.org/releases/avr-libc/avr-libc-user-manual-"$version_avrlibc".tar.bz2
getPackage http://switch.dl.sourceforge.net/project/libusb/libusb-1.0/libusb-"$version_libusb"/libusb-"$version_libusb".tar.bz2
getPackage http://switch.dl.sourceforge.net/project/libusb/libusb-0.1%20%28LEGACY%29/0.1.12/libusb-0.1.12.tar.gz
getPackage http://download.savannah.gnu.org/releases/avrdude/avrdude-"$version_avrdude".tar.gz
getPackage http://download.savannah.gnu.org/releases/avrdude/avrdude-doc-"$version_avrdude".tar.gz
getPackage http://download.savannah.gnu.org/releases/simulavr/simulavr-"$version_simulavr".tar.gz

installdir="$(pwd)/math"
if [ ! -d "$installdir" ]; then
    mkdir "$installdir"
fi

#########################################################################
# math prerequisites:
#########################################################################
buildPackage gmp-"$version_gmp"   "$installdir/lib/libgmp.a"  --prefix="$installdir" --enable-shared=no
buildPackage mpfr-"$version_mpfr" "$installdir/lib/libmpfr.a" --with-gmp="$installdir" --prefix="$installdir" --enable-shared=no
buildPackage mpc-"$version_mpc"   "$installdir/lib/libmpc.a"  --with-gmp="$installdir" --with-mpfr="$installdir" --prefix="$installdir" --enable-shared=no
rm -f "$installdir/lib/"*.dylib # ensure we have no shared libs

#########################################################################
# additional goodies
#########################################################################
buildPackage make-"$version_make" "$prefix/bin/make"
(
    for arch in i386 x86_64; do
        buildCFLAGS="$commonCFLAGS -arch $arch"
        buildPackage libusb-"$version_libusb" "$prefix/lib/libusb-1.0.a" --disable-shared
        buildPackage libusb-0.1.12 "$prefix/lib/libusb.a" --disable-shared
        rm -f "$prefix/lib"/libusb*.dylib
        for file in "$prefix/lib"/libusb*.a; do
            if [ "$file" != "$prefix/lib/libusb*.a" ]; then
                lipoHelper rename "$file"
            fi
        done
    done
    for file in "$prefix/lib"/libusb*.a.i386; do
        if [ "$file" != "$prefix/lib/libusb*.a.i386" ]; then
            lipoHelper merge "$file"
        fi
    done
)
checkreturn

#########################################################################
# binutils and prerequisites
#########################################################################
buildPackage avr-binutils-"$version_binutils" "$prefix/bin/avr-nm" --target=avr
if [ ! -f "$prefix/bfd/lib/libbfd.a" ]; then
    mkdir -p "$prefix/bfd/include"  # copy bfd directory manually
    mkdir "$prefix/bfd/lib"
    cp compile/avr-binutils-"$version_binutils"/bfd/libbfd.a "$prefix/bfd/lib/"
    cp compile/avr-binutils-"$version_binutils"/bfd/bfd.h "$prefix/bfd/include/"
    cp compile/avr-binutils-"$version_binutils"/include/ansidecl.h "$prefix/bfd/include/"
    cp compile/avr-binutils-"$version_binutils"/include/symcat.h "$prefix/bfd/include/"
fi
if [ ! -f "$prefix/lib/libiberty.a" ]; then
    mkdir "$prefix/lib"
    cp compile/avr-binutils-"$version_binutils"/libiberty/libiberty.a "$prefix/lib/"
fi

#########################################################################
# gcc bootstrap
#########################################################################
buildPackage avr-gcc-"$version_gcc" "$prefix/bin/avr-gcc" --target=avr --enable-languages=c --disable-libssp --disable-libada --with-dwarf2 --disable-shared --with-gmp="$installdir" --with-mpfr="$installdir" --with-mpc="$installdir"

# If we want to support avr-gcc version 3.x, we want to have it available as
# separate binary avr-gcc3, not with avr-gcc-select. Unfortunately, we also need
# a separate compile of avr-libc with gcc 3.x (other built-in functions etc).
# We don't enable this until we have found a good way to hold both compiles of
# avr-libc in parallel.
#for i in avr-ar avr-ranlib; do
#    ln -s $i "$prefix/bin/${i}3"
#done
#buildPackage gcc-"$version_gcc3" "$prefix/bin/avr-gcc3" --target=avr --enable-languages=c,c++ --disable-libssp --program-suffix=3 --program-prefix="avr-"
#for i in avr-ar avr-ranlib; do
#    rm -f "$prefix/bin/${i}3"
#done

#########################################################################
# avr-libc
#########################################################################
unpackPackage "avr-headers-$version_headers"
buildPackage avr-libc-"$version_avrlibc" "$prefix/avr/lib/libc.a" --host=avr
copyPackage avr-libc-user-manual-"$version_avrlibc" "$prefix/doc/avr-libc"
copyPackage avr-libc-manpages-"$version_avrlibc" "$prefix/man"

#########################################################################
# avr-gcc full build
#########################################################################
buildPackage avar-gcc-"$version_gcc" "$prefix/bin/avr-gcc" --target=avr --enable-languages=c,c++ --enable-fixed-point --disable-libssp --disable-libada --with-dwarf2 --disable-shared --with-gmp="$installdir" --with-mpfr="$installdir" --with-mpc="$installdir"

#########################################################################
# gdb and simulavr
#########################################################################
buildPackage gdb-"$version_gdb" "$prefix/bin/avr-gdb" --target=avr --without-python
(
    binutils="$(pwd)/compile/avr-binutils-$version_binutils"
    buildCFLAGS="$buildCFLAGS $("$prefix/bin/libusb-config" --cflags) -I$binutils/bfd -I$binutils/include -O"
    export LDFLAGS="$("$prefix/bin/libusb-config" --libs) -L$binutils/bfd -lz -L$binutils/libiberty -liberty"
    buildPackage avarice-"$version_avarice" "$prefix/bin/avarice"
)
checkreturn
buildPackage simulavr-"$version_simulavr" "$prefix/bin/simulavr" --with-bfd="$prefix/bfd" --with-libiberty="$prefix" --disable-static --enable-dependency-tracking

#########################################################################
# avrdude
#########################################################################
(
    buildCFLAGS="$buildCFLAGS $("$prefix/bin/libusb-config" --cflags)"
    export LDFLAGS="$("$prefix/bin/libusb-config" --libs)"
    buildPackage avrdude-"$version_avrdude" "$prefix/bin/avrdude" 
    copyPackage avrdude-doc-"$version_avrdude" "$prefix/doc/avrdude"
    if [ ! -f "$prefix/doc/avrdude/index.html" ]; then
        ln -s avrdude.html "$prefix/doc/avrdude/index.html"
    fi
)
checkreturn

#########################################################################
# ensure that we don't link anything local:
#########################################################################
libErrors=$(find "$prefix" -type f -perm +0100 -print | while read file; do
    locallibs=$(otool -L "$file" | tail -n +2 | grep '^/usr/local/')
    if [ -n "$locallibs" ]; then
        echo "*** $file uses local libraries:"
        echo "$locallibs"
    fi
done)

if [ -n "$libErrors" ]; then
    echo "################################################################################"
    echo "Aborting build due to above errors"
    echo "################################################################################"
    exit
fi

#########################################################################
# Create shell scripts and supporting files
#########################################################################
rm -f "$prefix/versions.txt"
cat "$prefix/etc/versions.d"/* >"$prefix/versions.txt"
echo "stripping all executables"
find "$prefix" -type f -perm -u+x -exec strip '{}' \; 2>/dev/null

# avr-man
cat >"$prefix/bin/avr-man" <<-EOF
	#!/bin/sh
	exec man -M "$prefix/man:$prefix/share/man" "\$@"
EOF
chmod a+x "$prefix/bin/avr-man"

# avr-info
cat >"$prefix/bin/avr-info" <<-EOF
	#!/bin/sh
	exec info -d "$prefix/share/info" "\$@"
EOF
chmod a+x "$prefix/bin/avr-info"

# avr-help
cat >"$prefix/bin/avr-help" <<-EOF
	#!/bin/sh
	exec open "$prefix/manual/index.html"
EOF
chmod a+x "$prefix/bin/avr-help"

# avr-gcc-select
cat > "$prefix/bin/avr-gcc-select" <<-EOF
    #!/bin/sh
    echo "avr-gcc-select is not supported any more."
    echo "This version of $pkgPrettyName comes with gcc 4 only."
    exit 1
EOF
chmod a+x "$prefix/bin/avr-gcc-select"

# uninstall script
cat >"$prefix/uninstall" <<-EOF
	#!/bin/sh
	if [ "\$1" != nocheck ]; then
		if [ "\$(whoami)" != root ]; then
			echo "\$0 must be run as root, use \\"sudo \$0\\""
			exit 1
		fi
	fi
	echo "Are you sure you want to uninstall $pkgPrettyName $pkgVersion?"
	echo "[y/N]"
	read answer
	if echo "\$answer" | egrep -i 'y|yes' >/dev/null; then
		echo "Starting uninstall."
		if cd "$prefix/.."; then
			rm -f "$pkgUnixName"
		fi
		rm -rf "$prefix"
        rm -rf "/etc/paths.d/50-at.obdev.$pkgUnixName"
		rm -f "/Applications/$pkgUnixName-Manual.html"
		rm -rf "/Library/Receipts/$pkgUnixName.pkg"
		echo "$pkgPrettyName is now removed."
	else
		echo "Uninstall aborted."
	fi
EOF
chmod a+x "$prefix/uninstall"

# avr-project
cat >"$prefix/bin/avr-project" <<-EOF
	#!/bin/sh
	if [ \$# != 1 ]; then
		echo "usage: \$0 <ProjectName>" 1>&2
		exit 1
	fi
	if [ "\$1" = "--help" -o "\$1" = "-h" ]; then
		{
			echo "This command creates an empty project with template files";
			echo
			echo "usage: \$0 <ProjectName>"
		} 1>&2
		exit 0;
	fi
	
	name=\$(basename "\$1")
	dir=\$(dirname "\$1")
	cd "\$dir"
	if [ -x "\$name" ]; then
		echo "An object named \$name already exists." 1>&2
		echo "Please delete this object and try again." 1>&2
		exit 1
	fi
	template=~/.$pkgUnixName/templates/TemplateProject
	if [ ! -d "\$template" ]; then
		template="$prefix/etc/templates/TemplateProject"
	fi
	echo "Using template: \$template"
	cp -R "\$template" "\$name" || exit 1
	cd "\$name" || exit 1
	mv TemplateProject.xcodeproj "\$name.xcodeproj"
EOF
chmod a+x "$prefix/bin/avr-project"

# templates
rm -rf "$prefix/etc/templates"
cp -R "templates" "$prefix/etc/"
(
	if cd "$prefix/etc/templates/TemplateProject/TemplateProject.xcodeproj"; then
		rm -rf *.mode1 *.pbxuser xcuserdata project.xcworkspace/xcuserdata
	fi
)

# manual
(
    cd manual-source
    ./mkmanual.sh "$prefix" "$pkgPrettyName"
)
rm -rf "$prefix/manual"
mv "manual" "$prefix/"


#########################################################################
# Mac OS X Package creation
#########################################################################

# remove files which should not make it into the package
chmod -R a+rX "$prefix"
find "$prefix" -type f -name '.DS_Store' -exec rm -f '{}' \;
find "$prefix" -type f \( -name '*.i386' -or -name '*.x86_64' \) -print -exec rm -f '{}' \;

echo "=== Making Mac OS X Package"
pkgroot="/tmp/$pkgUnixName-root-$$"
rm -rf "$pkgroot"
mkdir "$pkgroot"
mkdir "$pkgroot/usr"
mkdir "$pkgroot/usr/local"
cp -a "$prefix" "$pkgroot/usr/local/"

osxpkgtmp="/tmp/osxpkg-$$"
rm -rf "$osxpkgtmp"
cp -a package-info "$osxpkgtmp"
find "$osxpkgtmp" \( -name '*.plist' -or -name '*.rtf' -or -name '*.html' -or -name '*.txt' -or -name 'post*' \) -print | while read i; do
    echo "Running substitution on $i"
    cp "$i" "$i.tmp"	# create file with same permissions (is overwritten in next line)
    sed -e "s|%version%|$pkgVersion|g" -e "s|%pkgPrettyName%|$pkgPrettyName|g" -e "s|%prefix%|$prefix|g" -e "s|%pkgUnixName%|$pkgUnixName|g" -e "s|%pkgUrlName%|$pkgUrlName|g" "$i" > "$i.tmp"
    rm -f "$i"
    mv "$i.tmp" "$i"
done

echo "Building package..."

rm -rf "/tmp/$pkgUnixName-flat.pkg"
pkgbuild --identifier at.obdev.$pkgUnixName --scripts "$osxpkgtmp/scripts" --version "$pkgVersion" --install-location / --root "$pkgroot" "/tmp/$pkgUnixName-flat.pkg"
distfile="/tmp/$pkgUnixName-$$.dist"
cat >"$distfile" <<EOF
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="1">
    <title>$pkgPrettyName</title>
    <welcome file="Welcome.rtf" />
    <readme file="Readme.rtf" />
    <background file="background.jp2" scaling="proportional" alignment="center" />
    <pkg-ref id="at.obdev.$pkgUnixName"/>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="at.obdev.$pkgUnixName"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="at.obdev.$pkgUnixName" visible="false">
        <pkg-ref id="at.obdev.$pkgUnixName"/>
    </choice>
    <pkg-ref id="at.obdev.$pkgUnixName" version="$pkgVersion" onConclusion="none">$pkgUnixName-flat.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "$distfile" --package-path /tmp --resources "$osxpkgtmp/Resources" "/tmp/$pkgUnixName.pkg"
rm -f "$distfile"
rm -rf "/tmp/$pkgUnixName-flat.pkg"
rm -rf "$pkgroot"


#########################################################################
# Disk Image
#########################################################################

rwImage="/tmp/$pkgUnixName-$pkgVersion-rw-$$.dmg"   # temporary disk image
dmg="/tmp/$pkgUnixName-$pkgVersion.dmg"

mountpoint="/Volumes/$pkgUnixName"

# Unmount remainings from previous attempts so that we can be sure that
# We don't get a digit-suffix for our mount point
for i in "$mountpoint"*; do
    hdiutil eject "$i" 2>/dev/null
done

# Create a new disk image and mount it
rm -f "$rwImage"
hdiutil create -type UDIF -fs HFS+ -fsargs "-c c=64,a=16,e=16" -nospotlight -volname "$pkgUnixName" -size 65536k "$rwImage"
hdiutil attach -readwrite -noverify -noautoopen "$rwImage"

# Copy our data to the disk image:
# Readme:
cp -a "$osxpkgtmp/Readme.rtf" "/Volumes/$pkgUnixName/Readme.rtf"
# Package:
cp -a "/tmp/$pkgUnixName.pkg" "/Volumes/$pkgUnixName/"

# Now set Finder options, window size and position and Finder options:
# Note:
# Window bounds is {topLeftX, topLeftY, bottomRightX, bottomRightY} in flipped coordinates
# Icon posistions are icon center, measured from top (flipped coordinates)
echo "Starting AppleScript"
osascript <<EOF
    tell application "Finder"
        tell disk "$pkgUnixName"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {400, 200, 900, 550}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 180
            set position of item "Readme.rtf" of container window to {140, 170}
            set position of item "$pkgUnixName.pkg" of container window to {350, 170}
            close
            open
            update without registering applications
            delay 2
            eject
        end tell
    end tell
EOF
echo "AppleScript done"

# Ensure images is ejected (should be done by AppleScript above anyway)
hdiutil eject "$mountpoint" 2>/dev/null

# And convert it to a compressed read-only image (zlib is smaller than bzip2):
rm -f "$dmg"
#hdiutil convert -format UDBZ -o "$dmg" "$rwImage"
hdiutil convert -format UDZO -imagekey zlib-level=9 -o "$dmg" "$rwImage"

# Remove read-write version of image because it opens automatically when we
# double-click the read-only image.
rm -f "$rwImage"
open $(dirname "$dmg")


#########################################################################
# Cleanup
#########################################################################

echo "=== cleaning up..."
if ! "$debug"; then
    rm -f "/tmp/$pkgUnixName.pkg"
    rm -rf compile  # source and objects are HUGE
fi
echo "... done"

#########################################################################
# Create git tag
#########################################################################

xcrun git tag "releases/$pkgVersion"
echo "################################################################################"
echo "Please push the new git tag"
echo "################################################################################"
