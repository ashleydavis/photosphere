FROM oven/bun:1 AS builder

WORKDIR /build

COPY . .

RUN bun install --frozen-lockfile

WORKDIR /build/backend

RUN bun build --compile --minify --sourcemap --target=bun-linux-x64-baseline ./src/index.ts --outfile photosphere

FROM ubuntu:25.04

WORKDIR /app

COPY --from=builder /build/backend/photosphere ./

CMD ./photosphere
# CMD sleep infinity
