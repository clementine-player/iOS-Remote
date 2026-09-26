#!/bin/sh
# Regenerates the Swift for Clementine's remote control protocol.
#
# Needs protoc and protoc-gen-swift, the same version as the swift-protobuf package in
# Packages/ClementineKit/Package.swift (1.38.1):
#   brew install protobuf swift-protobuf
set -eu
cd "$(dirname "$0")/../Packages/ClementineKit"
protoc --proto_path=Proto \
    --swift_opt=Visibility=Public \
    --swift_out=Sources/ClementineKit/Protocol \
    Proto/remotecontrolmessages.proto
