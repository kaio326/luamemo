FROM alpine:3.19
RUN apk add --no-cache lua5.1
COPY . /app
WORKDIR /app
CMD ["lua5.1", "main.lua"]
