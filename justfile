# Build script for all of GCC's build scripts
#
# Requires the following directory structure:
#
# workspace-gcc/  # name is unimportant
#     justfile    # this file
#     gcc/        # gcc clone
#
# And will create the following directories:
# - gcc-build: the full three-stage build
# - gcc-build-no-bootstrap: development build without bootstrap (set
#   BOOTSTRAP=0 to use)
# - local-install: destination of `just install`
# - local-install-no-bootstrap: local install for BOOTSTRAP=0
#
# MinGW note: the out-of-the-box build is broken, some patches are needed. At
# least "Windows: Don't ignore native system header dir" and "Windows: Don't
# ignore native system header dir" from this list are needed:
# <https://github.com/gcc-mirror/gcc/compare/master...tgross35:gcc:patch-win-build>
#
# Non-base deps that I have needed:
# - binutils
# - bison
# - diffutils
# - findutils
# - flex
# - gmp
# - m4
# - make
# - mpc
# - mpfr
# - patch
#
# Specific to Linux unless multilib is disabled:
# - gcc-multilib
#
# Specific to MinGW
# - bisonc++
#
# Not needed but speeds up builds:
# - ccache
# - mold
#
# Needed for running tests:
# - dejagnu

set windows-shell := ["C:/msys64/msys2_shell.cmd", "-ucrt64", "-defterm", "-here", "-no-start", "-c"]

# gcc configure doesn't seem to like absolute Windows paths, so we use relative
# and forward slashes.
root := if os() == "windows" {
    replace(replace(justfile_directory(), 'C:\', '/c/'), '\', '/')
} else {
	justfile_directory()
}
root_rel_build_dir := if os() == "windows" {
	".."
} else {
	justfile_directory()
}

# Allow disabling bootstrap by setting BOOTSTRAP=0. This uses a separate build
# directory.
do_bootstrap := env("DO_BOOTSTRAP", "1")

source_dir := root / "gcc"
source_dir_rel_build_dir := root_rel_build_dir / "gcc"
build_dir := if do_bootstrap == "0" { root / "gcc-build-no-bootstrap" } else { root / "gcc-build" }
install_dir := if do_bootstrap == "0" { root / "local-install-no-bootstrap" } else { root / "local-install" }
config_hash_file := build_dir / ".configure-hash"
bin_dir := install_dir / "bin"
bin_sfx := if os() == "windows" { ".exe" } else { "" }
launcher := "ccache"

# default_languages := "c,c++,rust"
default_languages := "c,c++"

# Prefer mold then lld if available
linker := `(command -v mold >/dev/null && echo mold) || (command -v lld >/dev/null && echo lld) || true`

# Allow overriding these via env, otherwise set defaults
export LD := env("LD", linker)
export CC := env("CC", launcher + " cc")
export CXX := env("CXX", launcher + " c++")
# Not modified/reexported but used in cache
cflags := env("CFLAGS", "")
cxxflags := env("CXXFLAGS", "")

# Print recipes and exit
default:
	@echo "source: {{ source_dir }}"
	@echo "build: {{ build_dir }}"
	@echo "install: {{ install_dir }}"
	@"{{ just_executable() }}" --list

set_bootstrap_path := "export PATH=" + mingw_bootstrap + "/bin:${PATH}"

alias cfg := configure

# Run configuration
configure target="" languages=default_languages:
	#!/bin/bash
	set -ex

	# Hash all configurable parts
	cfg_hash="{{ sha256(LD + CC + CXX + cflags + cxxflags + do_bootstrap + source_dir + build_dir + install_dir + launcher + target + languages) }}"
	git_hash="$(git -C "{{ source_dir }}" rev-parse HEAD)"
	hash="$cfg_hash-$git_hash"
	if [ "$hash" = "$(cat '{{ config_hash_file }}')" ]; then
		echo configuration up to date, skipping
		exit
	else
		echo config outdated, rerunning
	fi

	args=(
		"--with-pkgversion=Local build $(git -C "{{ source_dir }}" rev-parse HEAD)"
		"--prefix={{ install_dir }}"
		"--enable-languages={{ languages }}"
	)

	[ "{{ do_bootstrap }}" = "0" ] && args+=("--disable-bootstrap")

	os="$(uname -o)"

	if [ "$os" = "Darwin" ]; then
		# I haven't been able to get this one working successfully

		# Help the build locate required libraries
		lib_root="/opt/homebrew/Cellar"
		gmp_version="$(ls "$lib_root/gmp/" | head -n1)"
		mpc_version="$(ls "$lib_root/libmpc/" | head -n1)"
		mpfr_version="$(ls "$lib_root/mpfr/" | head -n1)"
		args+=(
			"--with-gmp=$lib_root/gmp/$gmp_version"
			"--with-mpc=$lib_root/libmpc/$mpc_version"
			"--with-mpfr=$lib_root/mpfr/$mpfr_version"
		)

		args+=("--enable-multilib")
	elif [ "$os" = "Msys" ]; then
		# From https://github.com/msys2/MINGW-packages/tree/52d1c20a0810167bb39a095727d327885eb6b9c8/mingw-w64-gcc
		# and https://github.com/Martchus/PKGBUILDs/blob/88cec2bf9801ac0a322dbe03bc6cbcb6da6da61d/gcc/mingw-w64/PKGBUILD
		# For more MinGW build debugging, see also
		# https://sourceforge.net/p/mingw-w64/mailman/mingw-w64-public/thread/CAPMxyhJYHMKBkXDMt71j-ZpLqtzzn85ikO87imLgYEzQEHAzjw@mail.gmail.com/

		# Some of these are disabled because they lead to an overflow error with
		# ordinal link indices.
	    args+=(
			--disable-libstdcxx-pch
			--disable-libssp
			--disable-multilib
			--disable-rpath
			--disable-win32-registry
			--disable-nls
			--disable-werror
			--disable-symvers
			--with-gnu-as
			--with-gnu-ld
			--with-dwarf2

			--enable-static
			# --enable-libatomic
			--with-arch=nocona
			# --enable-checking=yes
			--enable-mingw-wildcard
			--enable-fully-dynamic-string
			# --enable-libstdcxx-backtrace=yes
			# --enable-libstdcxx-filesystem-ts
			# --enable-libstdcxx-time
			# --enable-libgomp
			--disable-libgomp
			# --enable-threads=posix
			# --enable-graphite
			# --with-libiconv
			--with-system-zlib
			# --with-gmp=/ucrt64
			# --with-mpfr=/ucrt64
			# --with-mpc=/ucrt64
			# --with-isl=/ucrt64
			# --with-libstdcxx-zoneinfo=yes
			--disable-libstdcxx-debug
			# --enable-plugin
			--with-boot-ldflags=-static-libstdc++
			--with-stage1-ldflags=-static-libstdc++
			--with-local-prefix=/ucrt64/local
			--with-native-system-header-dir=/ucrt64/include
	    )
	else
		args+=("--enable-multilib")
	fi

	if [ -n "{{ target }}" ]; then
		args+=("--target={{ target }}")
	fi

	mkdir -p "{{ build_dir }}"
	cd "{{ build_dir }}"

	pwd
	"{{ source_dir_rel_build_dir }}/configure" "${args[@]}"

	printf "$hash" > "{{ config_hash_file }}"

alias b := build

# Build the project, reconfiguring if necessary
build: configure
	make -C "{{ build_dir }}" "-j{{ num_cpus() }}"

# Install to the provided prefix. Does not rebuild/reconfigure
install:
	make -C "{{ build_dir }}" install

# Clean the build directory
clean:
	rm -rf "{{ build_dir }}"
	mkdir "{{ build_dir }}"

# Run tests on the specified files. Does not rebuild
test *testfiles:
	make -C "{{ build_dir }}" -k check "-j{{ num_cpus() }}"

# Run gcc tests
test-gcc *options:
	# The test suntax is so confusing. Some useful tips are at
	# https://gcc-newbies-guide.readthedocs.io/en/latest/working-with-the-testsuite.html.
	# I haven't been able to filter tests successfully like that describes, so I
	# usually wind up running the whole relevant `.exp` file and using
	# `rg 'test-name' -g '**/gcc.sum' --no-ignore -C1` to find the relevant
	# summary files.
	make -C "{{ build_dir }}/gcc" check-gcc RUNTESTFLAGS="-v {{ options }}" "-j{{ num_cpus() }}"

# Print the location of built binaries
bindir:
	echo "{{ bin_dir }}"

alias r := run

# Launch a binary with the given name
[no-cd]
run name *args:
	"{{ bin_dir }}/{{ name }}{{ bin_sfx }}" {{ args }}

# Symlink configuration so C language servers work correctly
configure-clangd: configure
	#!/usr/bin/env sh
	set -eaux
	cmd_file="{{ build_dir / "compile_commands.json" }}"
	if [ -f "$cmd_file" ]; then
		ln -is "$cmd_file" "{{ source_dir }}"
	else
		echo "$cmd_file not found"
	fi

# I think the below is config from when I was attempting to cross compile.
# Unfortunately I don't remember it ever working.

mingw_arch := "x86_64-w64-mingw64"
mingw_version := "12.0.0"
mingw_dl := root / "mingw-w64.tar.bz2"
mingw_src := root / "mingw-w64-v" + mingw_version
mingw_build := root / "mingw-build"
mingw_bootstrap := root / "bootstrap"
mingw_prefix := root / "mingw-prefix"
mingw_gcc_build := root / "mingw-gcc-build"

configure-something-not-sure-what:
	#!/bin/bash

	{{ set_bootstrap_path }}
	mkdir -p {{ mingw_prefix / mingw_arch / "lib" }}
	CC={{ mingw_arch }}-gcc DESTDIR={{ mingw_prefix }}/{{ mingw_arch }}/lib/ sh {{ mingw_prefix }}/src/libmemory.c
	ln {{ mingw_prefix }}/{{ mingw_arch }}/lib/libmemory.a /bootstrap/{{ mingw_arch }}/lib/
	CC={{ mingw_arch }}-gcc DESTDIR={{ mingw_prefix }}/{{ mingw_arch }}/lib/ sh {{ mingw_prefix }}/src/libchkstk.S
	ln {{ mingw_prefix }}/{{ mingw_arch }}/lib/libchkstk.a /bootstrap/{{ mingw_arch }}/lib/


mingw-crt:
	#!/bin/bash
	set -ex

	{{ set_bootstrap_path }}
	mkdir -p "{{ mingw_build }}/crt"
	cd "{{ mingw_build }}/crt"
	{{ mingw_src }}/mingw-w64-crt/configure \
		--prefix={{ mingw_bootstrap }}/{{ mingw_arch }} \
		--with-sysroot={{ mingw_bootstrap }}/{{ mingw_arch }} \
		--host={{ mingw_arch }} \
		--with-default-msvcrt=msvcrt-os \
		--disable-dependency-tracking \
		--disable-lib32 \
		--enable-lib64 \
		CFLAGS="-Os" \
		LDFLAGS="-s" \

	make -j$(nproc)
	make install

mingw-setup:
	#!/bin/bash
	set -ex
	curl -L -o "{{ mingw_dl }}" \
		"https://downloads.sourceforge.net/project/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v{{ mingw_version }}.tar.bz2"
	tar xjf mingw-w64.tar.bz2

mingw-headers:
	#!/bin/bash
	set -ex
	mkdir -p "{{ mingw_build }}/headers"
	cd "{{ mingw_build }}/headers"
	"{{ mingw_src }}/mingw-w64-headers/configure" \
		--prefix={{ mingw_bootstrap }}/{{ mingw_arch }} \
		--host={{ mingw_arch }} \
		--with-default-msvcrt=msvcrt-os
	make "-j{{ num_cpus() }}"
	make install
	cd "{{ mingw_bootstrap }}"
	ln -s "{{ mingw_arch }}" mingw

mingw-gcc:
	mkdir -p "{{ mingw_gcc_build }}"
	cd "{{ mingw_gcc_build }}"
	"{{ source_dir }}"/configure \
		"--prefix={{ mingw_bootstrap }}" \
		"--with-sysroot={{ mingw_bootstrap }}" \
		"--target={{ mingw_arch }}" \
		--enable-static \
		--disable-shared \
		--with-pic \
		--enable-languages=c,c++,fortran \
		--enable-libgomp \
		--enable-threads=posix \
		--enable-version-specific-runtime-libs \
		--disable-dependency-tracking \
		--disable-nls \
		--disable-lto \
		--disable-multilib \
		CFLAGS_FOR_TARGET="-Os" \
		CXXFLAGS_FOR_TARGET="-Os" \
		LDFLAGS_FOR_TARGET="-s" \
		CFLAGS="-Os" \
		CXXFLAGS="-Os" \
		LDFLAGS="-s"

	make "-j{{ num_cpus() }}" all-gcc
	make install-gcc
