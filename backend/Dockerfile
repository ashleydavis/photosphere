FROM node:20.10.0 AS builder

WORKDIR /build

RUN npm install -g pnpm@8.15.5
RUN npm install -g hoist-modules

COPY . .

RUN pnpm install --frozen-lockfile
RUN pnpm run compile

WORKDIR /build/backend

RUN hoist-modules ./ ./hoisted_node_modules
RUN rm -rf ./node_modules
RUN mv ./hoisted_node_modules ./node_modules

FROM node:20.10.0

WORKDIR /app

RUN npm install -g pnpm

COPY --from=builder /build/backend/package.json ./
COPY --from=builder /build/backend/build ./build
COPY --from=builder /build/backend/node_modules ./node_modules

CMD npm start
