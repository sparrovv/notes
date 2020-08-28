#!/usr/bin/env sh

set -o errexit
set -o nounset

if [ $# -ne 1 ] ; then
    echo "Usage: ./draft.sh <note name>"
      exit 1
fi

path=drafts/$(date +%Y%m%d)_$1;
echo $path
mkdir -p $path
touch $path/README.md
