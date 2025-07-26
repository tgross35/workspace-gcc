source_dir := justfile_directory() / "gcc"
build_dir := justfile_directory() / "gcc-build"
install_dir := justfile_directory() / "local-install"
config_hash_file := build_dir / ".configure-hash"
bin_dir := build_dir / "bin"
launcher := "ccache"

# Prefer mold then lld if available
linker := ```
	if which mold > /dev/null 2> /dev/null; then
		echo "mold"
	elif which lld >/dev/null 2> /dev/null; then
		echo "lld"
	fi
```

export LD := env("LD ", linker)
export CC := env("CC ", launcher + " cc")
export CXX := env("CXX ", launcher + " c++")
export CFLAGS := env("CFLAGS ", "-O2")
export CXXFLAGS := env("CXXFLAGS ", "-O2")

# Print recipes and exit
default:
	"{{ just_executable() }}" --list

mingw_arch := "x86_64-w64-mingw32"
mingw_version := "12.0.0"
mingw_dl := justfile_directory() / "mingw-w64.tar.bz2"
mingw_src := justfile_directory() / "mingw-w64-v" + mingw_version
mingw_build := justfile_directory() / "mingw-build"
mingw_bootstrap := justfile_directory() / "bootstrap"
mingw_prefix := justfile_directory() / "mingw-prefix"
mingw_gcc_build := justfile_directory() / "mingw-gcc-build"

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

set_bootstrap_path := "export PATH=" + mingw_bootstrap + "/bin:${PATH}"

configure-thing:
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

alias cfg := configure

# Configure CMake
configure target="" languages="c,c++,rust":
	#!/bin/bash

	set -ex

	# Hash all configurable parts
	hash="{{ sha256(LD + CC + CXX + CFLAGS + CXXFLAGS + source_dir + build_dir + target + languages + install_dir + launcher) }}"
	if [ "$hash" = "$(cat '{{config_hash_file}}')" ]; then
		echo configuration up to date, skipping
		exit
	else
		echo config outdated, rerunning
	fi

	args=("--prefix={{ install_dir }}" "--enable-languages={{ languages }}")

	if [ "$(uname -o)" = "Darwin" ]; then
		lib_root="/opt/homebrew/Cellar"
		gmp_version="$(ls "$lib_root/gmp/" | head -n1)"
		mpc_version="$(ls "$lib_root/libmpc/" | head -n1)"
		mpfr_version="$(ls "$lib_root/mpfr/" | head -n1)"
		args+=("-with-gmp=$lib_root/gmp/$gmp_version")
		args+=("-with-mpc=$lib_root/libmpc/$mpc_version")
		args+=("-with-mpfr=$lib_root/mpfr/$mpfr_version")
	fi

	if [ -n "{{ target }}" ]; then
		args+=("--target={{ target }}")
	fi

	mkdir -p "{{ build_dir }}"
	cd "{{ build_dir }}"

	"{{ source_dir }}/configure" \
		--enable-multilib \
		"${args[@]}"

	printf "$hash" > "{{ config_hash_file }}"

alias b := build

# Build the project
build: configure
	make -C "{{ build_dir }}" "-j{{ num_cpus() }}"

# Install to the provided prefix. Does not rebuild/reconfigure
install: build
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
	make -C "{{ build_dir }}" check-gcc RUNTESTFLAGS="{{ options }}" "-j{{ num_cpus() }}"

# Print the location of built binaries
bindir:
	echo "{{ bin_dir }}"

# Launch a binary with the given name
bin binname *binargs:
	"{{ bin_dir }}/{{ binname }}" {{ binargs }}

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
