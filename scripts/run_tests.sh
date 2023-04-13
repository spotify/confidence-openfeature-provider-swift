#!/bin/bash

set -e

script_dir=$(dirname $0)
root_dir="$script_dir/../"

(cd $root_dir &&
    TEST_RUNNER_KONFIDENS_CLIENT_TOKEN=$1 TEST_RUNNER_TEST_FLAG_NAME=$2 xcodebuild \
        -scheme ConfidenceProvider \
        -sdk "iphonesimulator" \
        -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=16.2' \
        test)
