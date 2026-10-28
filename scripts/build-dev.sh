#!/usr/bin/env sh
# Builds the dev place's five parts as models in build/, for importing into Studio (the Studio MCP
# import_rbxm, or drag into the Explorer). `rojo serve dev.project.json` is the live alternative.
set -e
cd "$(dirname "$0")/.."
(cd dev && wally install)
mkdir -p build
for part in Packages ServerPackages Shared Server Client; do
	rojo build "dev/projects/$part.project.json" -o "build/$part.rbxm"
done
ls -l build
