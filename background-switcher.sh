#!/usr/bin/env bash


if [[ x"$@" = x"quit" ]]
then
    exit 0
fi

if [[ ! $# -eq 0 ]]
then
    echo "$@" | socat - unix-connect:/tmp/background-switcher.socket

    # $@ = "quit"
    exit 0
fi

echo "quit"
echo "query" | socat - unix-connect:/tmp/background-switcher.socket
