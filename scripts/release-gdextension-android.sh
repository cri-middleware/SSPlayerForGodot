#!/usr/bin/env zsh
set -e

BASEDIR=$(dirname $0)
BASEDIR=$(cd $BASEDIR && pwd -P)
ROOTDIR=${BASEDIR}/..
ROOTDIR=$(cd $ROOTDIR && pwd -P)

pushd ${ROOTDIR} > /dev/null
BINDIR=$(pwd)/bin/android
/bin/rm -rf ${BINDIR}
# r28b, the NDK setup-extension installs. godot-cpp's own default follows its
# master, which this repository builds against unpinned.
NDK_VERSION=28.1.13356709
targets=("template_release" "template_debug")
for target in ${targets[@]}; do
    scripts/build-extension.sh platform=android arch=arm32 compiledb=no strip=yes ndk_version=${NDK_VERSION} target=${target} "$@"
    scripts/build-extension.sh platform=android arch=arm64 compiledb=no strip=yes ndk_version=${NDK_VERSION} target=${target} "$@"
    scripts/build-extension.sh platform=android arch=x86_64 compiledb=no strip=yes ndk_version=${NDK_VERSION} target=${target} "$@"
done

popd > /dev/null # ${ROOTDIR}
