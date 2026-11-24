#!/bin/bash
# Prints the hash of everything the helper build is made from. build.sh seals
# it into the bundle (Contents/Resources/source.sha256); setup.sh compares it
# with the checkout to tell whether the committed build is current.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
cat src/main.swift AllowShowNotifier.app/Contents/Info.plist | shasum -a 256 | cut -d' ' -f1
