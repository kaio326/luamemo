FROM openresty/openresty:1.27.1.2-0-alpine-fat

# Install lapis and all its dependencies via Alpine's lua5.1-* apk packages.
# These are compiled against standard Lua 5.1 ABI, which is identical to
# LuaJIT's ABI — all C modules (.so) load correctly in OpenResty.
# No luarocks required; no LuaJIT "65536 constants" manifest issue.
RUN apk add --no-cache \
    lua5.1-lapis \
    lua5.1-pgmoon \
    lua5.1-lpeg \
    lua5.1-socket \
    lua5.1-cjson \
    lua5.1-filesystem \
    lua-date

# The repo is mounted at /app at runtime — nothing to COPY here.
# The library lives at /app/lapis_memory/, config at /app/dev/.

