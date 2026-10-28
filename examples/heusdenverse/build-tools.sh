#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# Builds the small H3 tools the scripts call (hexdisk, cells, pentagons) into build/, against
# the H3 C library vendored in Packages/CH3.
set -eu
HERE=${0:A:h}
H3=$HERE/../../Packages/CH3/Sources/CH3
mkdir -p $HERE/build
for tool in hexdisk cells pentagons; do
  clang -O2 -w -I$H3/include -I$H3 $H3/*.c $HERE/tools/$tool.c -o $HERE/build/$tool
done
print "built: ${(j:, :)${(@f)$(ls $HERE/build)}}"
