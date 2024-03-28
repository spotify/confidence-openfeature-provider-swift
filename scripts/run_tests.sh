#!/bin/bash

set -e

script_dir=$(dirname $0)
root_dir="$script_dir/../"

# Set the client token in your local keychain using the following command:
# security add-generic-password -s 'swift-provider-e2e'  -a 'confidence-test' -w 'TOKEN'
# You can then run the script with no arguments - you will need to allow access the first time only.
test_runner_client_token=$1
if [[ -z "${test_runner_client_token// }" ]]; then
    test_runner_client_token=$(security find-generic-password -w -s 'swift-provider-e2e' -a 'confidence-test')
fi

(cd $root_dir &&
    TEST_RUNNER_CLIENT_TOKEN=$test_runner_client_token TEST_RUNNER_TEST_FLAG_NAME=$2 xcodebuild \
        -quiet \
        -scheme Confidence-Package \
        -destination 'platform=iOS Simulator,name=iPhone 14 Pro,OS=16.2' \
        test)
