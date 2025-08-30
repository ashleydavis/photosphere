FROM oven/bun:1-alpine AS builder

WORKDIR /build

RUN apk update
RUN apk add zip

COPY . .

RUN bun install --frozen-lockfile

WORKDIR /build/apps/frontend

ENV VITE_BASE_URL=""
ENV VITE_NODE_ENV="production"

# Build the frontend
RUN bun run build

WORKDIR /build/apps/backend

# Build the backend
RUN bun build --env=disable --compile --minify --sourcemap --target=bun-linux-x64 --outfile photosphere-server ./src/index.ts

# Have to use the Bun image so that we can install sharp.
FROM oven/bun:1-alpine 

# Otherwise prefer to use this:
# FROM alpine:3

WORKDIR /app

COPY --from=builder /build/apps/frontend/dist ./public
COPY --from=builder /build/apps/backend/photosphere-server ./

# Have to add sharp otherwise it doesn't work.
RUN bun add sharp

ENV FRONTEND_STATIC_PATH=/app/public

CMD ./photosphere-server
# CMD sleep infinity
