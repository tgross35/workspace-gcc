source_dir := justfile_directory() / "llvm-project"
build_dir := justfile_directory() / "llvm-build"
install_dir := justfile_directory() / "local-install"
config_hash_file := build_dir / ".configure-hash"
bin_dir := build_dir / "bin"
targets := "AArch64;X86"
launcher := "ccache"

# Prefer mold then lld if available
[unix]
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
[unix]
configure build-type="Debug" projects="clang":
	#!/bin/sh
	# Hash all configurable parts 
	hash="{{ sha256(source_dir + build_dir + build-type + install_dir + projects + linker_arg + launcher) }}"
	if [ "$hash" = "$(cat '{{config_hash_file}}')" ]; then
		echo configuration up to date, skipping
		exit
	else
		echo config outdated, rerunning
	fi

	printf "$hash" > "{{ config_hash_file }}"

	cmake "-S{{ source_dir }}/llvm" "-B{{ build_dir }}" \
		-G Ninja \
		-DCMAKE_C_COMPILER_LAUNCHER={{ launcher }}\
		-DCMAKE_CXX_COMPILER_LAUNCHER={{ launcher }}\
		-DCMAKE_EXPORT_COMPILE_COMMANDS=true \
		"-DCMAKE_BUILD_TYPE={{ build-type }}" \
		"-DCMAKE_INSTALL_PREFIX={{ install_dir }}" \
		"-DLLVM_ENABLE_PROJECTS={{ projects }}" \
		"-DLLVM_TARGETS_TO_BUILD={{ targets }}" \
		"{{linker_arg}}"

# Configure CMake
[windows]
configure build-type="Debug" projects="clang":
	# Windows seems to require the host triple be set
	cmake "-S{{ source_dir }}/llvm" "-B{{ build_dir }}" \
		-G Ninja \
		-DCMAKE_C_COMPILER_LAUNCHER={{ launcher }}\
		-DCMAKE_CXX_COMPILER_LAUNCHER={{ launcher }}\
		-DCMAKE_EXPORT_COMPILE_COMMANDS=true \
		"-DCMAKE_BUILD_TYPE={{ build-type }}" \
		"-DCMAKE_INSTALL_PREFIX={{ install_dir }}" \
		"-DLLVM_ENABLE_PROJECTS={{ projects }}" \
		"-DLLVM_TARGETS_TO_BUILD={{ targets }}" \
		"-DLLVM_HOST_TRIPLE=x86_64-pc-windows-msvc" \
		"{{linker_arg}}"

alias b := build

# Build the project
build: configure
	cmake --build "{{ build_dir }}"

# Clean the build directory
clean:
	cmake --build "{{ build_dir }}" --target clean

# Run the LLVM test suite. Does not rebuild/reconfigure
test-llvm: build
	ninja -C "{{ build_dir }}" check-llvm
	# cmake "{{ build_dir }}" check-llvm

# Run the complete test suite. Does not rebuild/reconfigure
test: build
	ninja -C "{{ build_dir }}" check-all
	# cmake "{{ build_dir }}" check-all

# Install to the provided prefix. Does not rebuild/reconfigure
install: build
	cmake "{{ build_dir }}" install

# Run Lit on the specified files
lit +testfiles: build
	"{{ bin_dir }}/llvm-lit" -v {{ testfiles }}

# Print the location of built binaries
bindir:
	echo "{{ bin_dir }}"

# Launch a binary with the given name
bin binname *binargs:
	"{{ bin_dir }}/{{ binname }}" {{ binargs }}

# Run the code formatter
fmt *args:
	"{{ source_dir }}/llvm/utils/git/code-format-helper.py" {{ args }}

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
