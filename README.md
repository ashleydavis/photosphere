# Photosphere monorepo extended

This is the official ongoing monorepo for Photosphere, an application for managing your photos (videos coming later).

Photosphere is designed to be easy to host for yourself. Host the web page, supply an AWS S3 bucket (other storage providers coming later), and you are ready to go. 

Contained herein are the code for Photosphere's:
- Backend
- Web frontend
- Electron app
- Android and iOS apps

Early development of Photosphere was covered in the book [Rapid Fullstack Development](https://rapidfullstackdevelopment.com/).

## Running Photosphere locally for development

### Pre-reqs

You need [Node.js](https://nodejs.org/) installed to run this code.

You need [Pnpm](https://pnpm.io/). It is used to install dependencies and manage the workspaces.

### Setup

First, clone a local copy of the code repository:

```bash
git clone git@github.com:Rapid-Fullstack-Development/photosphere-monorepo-extended.git
```

Then install all dependencies at the root of the monorepo:

```
cd photosphere-monorepo-extended
pnpm install
```

### Compile shared components

Photosphere has TypeScript packages that are shared been components. 

You must compile them first:

```bash
pnpm run compile
```

To compile continously during development:

```bash
pnpm run compile:watch
```

### Start the components that you need

To start the backend, follow the instructions in [./backend/README.md](./backend/README.md).

To start the web-based frontend, follow the instructions in [./frontend/README.md](./frontend/README.md).

To start the Electron-based frontend, follow the instructions in [./electron/README.md](./electron/README.md).

To start the mobile frontend, follow the instructions in [./mobile/README.md](./mobile/README.md).









