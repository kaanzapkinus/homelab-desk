#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 "$DIR/fake_omp.py" "$@"
