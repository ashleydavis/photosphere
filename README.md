# Photosphere monorepo extended

This is an extended version of the monorepo for [the Photosphere application](https://rapidfullstackdevelopment.com/example-application).

In addition to the usual backand and frontend, this monorepo contains an Electron-based desktop version of Photosphere.

This code accompanies chapter 8 of the book [Rapid Fullstack Development](https://rapidfullstackdevelopment.com/).

## Pre-reqs

You need [Node.js](https://nodejs.org/) installed to run this code.

You need [Pnpm](https://pnpm.io/). It is used to install dependencies and managed the workspaces.

## Running Photosphere

First, clone a local copy of the code repository:

```bash
git clone git@github.com:Rapid-Fullstack-Development/photosphere-monorepo-extended.git
```

Then install all dependencies at the root of the monorepo:

```
cd photosphere-monorepo-extended
pnpm install
```

Next, start the backend. Follow the instructions in [./backend/README.md](./backend/README.md).

Start the web-based frontend. Follow the instructions in [./frontend/README.md](./frontend/README.md).

Start the Electron-based frontend. Follow the instructions in [./electron/README.md](./electron/README.md).









