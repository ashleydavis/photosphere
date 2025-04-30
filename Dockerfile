FROM oven/bun:1 AS builder

WORKDIR /build

RUN apt update -y
RUN apt install -y zip

COPY . .

RUN bun install --frozen-lockfile

WORKDIR /build/frontend

ENV VITE_BASE_URL=""
ENV VITE_NODE_ENV="production"
ENV VITE_APP_MODE="readwrite"
ENV VITE_AUTH_TYPE="no-auth"
ENV VITE_GOOGLE_API_KEY=""

RUN bun run build
RUN zip -r pfe.zip ./dist
RUN mv pfe.zip ../backend/pfe.zip

WORKDIR /build/backend

RUN bun build --compile --minify --sourcemap --target=bun-linux-x64-baseline --outfile photosphere ./src/index.ts

FROM ubuntu:25.04

WORKDIR /app

COPY --from=builder /build/backend/photosphere ./

CMD ./photosphere
# CMD sleep infinity
