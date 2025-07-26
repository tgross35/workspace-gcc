source_dir := justfile_directory() / "gcc"
build_dir := justfile_directory() / "gcc-build"
install_dir := justfile_directory() / "local-install"
config_hash_file := build_dir / ".configure-hash"
bin_dir := build_dir / "bin"
launcher := "ccache"

# Prefer mold then lld if available
default_linker_arg := ```
	link_arg=""
	if which mold > /dev/null 2> /dev/null; then
		echo "mold"
	elif which lld >/dev/null 2> /dev/null; then
		echo "lld"
	fi
```
linker := env("LLVM_USE_LINKER", default_linker_arg)
linker_arg := if linker == "" { "" } else { "-DLLVM_USE_LINKER=" + linker }

# Print recipes and exit
default:
	"{{ just_executable() }}" --list

alias cfg := configure

# Configure CMake
configure languages="c,c++,rust":
	#!/bin/bash

	set -ex

	# Hash all configurable parts
	hash="{{ sha256(source_dir + build_dir + languages + install_dir + linker_arg + launcher) }}"
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

	mkdir -p "{{ build_dir }}"
	cd "{{ build_dir }}"

	"{{ source_dir }}/configure" \
		"CC={{ launcher }} gcc" \
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
