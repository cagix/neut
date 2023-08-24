#!/bin/bash

base_dir=$(pwd)

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
COMPILER_VERSION=$($NEUT version)
clang_option="-fsanitize=address"
digest=$(echo -n "develop $clang_option" | sha256sum -b | xxd -r -p | base64 | tr '/+' '_-' )

cd $SCRIPT_DIR/meta
NEUT_TARGET_ARCH=$TARGET_ARCH $NEUT build --clang-option $clang_option

pids=()

for target_dir in "$@"; do
  cd $base_dir
  cd $target_dir

  for i in $(find . -maxdepth 1 -mindepth 1 -type d | sort); do
    cd $i
    echo $(basename $i)
    (
      exit_code=0
      NEUT_TARGET_ARCH=$TARGET_ARCH $NEUT clean
      NEUT_TARGET_ARCH=$TARGET_ARCH $NEUT build --clang-option $clang_option
      output=$(ASAN_OPTIONS=detect_leaks=1 ./.build/$TARGET_ARCH-linux/compiler-$COMPILER_VERSION/build-option-$digest/executable/$(basename $i) 2>&1 > actual)
      last_exit_code=$?
      if [ $last_exit_code -ne 0 ]; then
        printf "\033[1;31merror:\033[0m a test failed: $(basename $i)\n$output\n"
        exit_code=$last_exit_code
      fi
      mismatch=$(diff expected actual 2>&1)
      last_exit_code=$?
      if [ $last_exit_code -ne 0 ]; then
        printf "\033[1;31merror:\033[0m found an unexpected result in: $(basename $i)\n$mismatch\n"
        exit_code=$last_exit_code
      fi
      exit $exit_code
    ) &
    pids+=($!)
    cd ..
  done
done

exit_code=0

for pid in $pids; do
  wait $pid
  result=$?
  if [ $result -ne 0 ]; then
    exit_code=$result
  fi
done

exit $exit_code
