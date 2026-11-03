FROM docker.io/alpine:latest
RUN apk add --no-cache bash git ca-certificates lua5.4 lua5.4-filesystem lua5.4-socket ripgrep coreutils
