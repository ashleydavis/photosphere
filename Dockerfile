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

# Build the frontend
RUN bun run build

WORKDIR /build/backend

# Build the backend
RUN bun build --compile --minify --sourcemap --target=bun-linux-x64-baseline --outfile photosphere ./src/index.ts

FROM ubuntu:25.04

WORKDIR /app

COPY --from=builder /build/frontend/dist ./public
COPY --from=builder /build/backend/photosphere ./

ENV FRONTEND_STATIC_PATH=/app/public

CMD ./photosphere
# CMD sleep infinity
