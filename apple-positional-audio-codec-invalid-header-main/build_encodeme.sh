#!/bin/bash
set -e
clang++ -g -Os -std=c++2b -fmodules -fcxx-modules -fobjc-arc -arch x86_64 -arch arm64 -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) -framework AVFAudio -framework AudioToolbox encodeme.mm -o encodeme
chmod +x encodeme
