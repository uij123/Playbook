#!/bin/sh
exec node "$(dirname "$0")/cli/dist/index.js" "$@"
