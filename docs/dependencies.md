# Dependencies

```mermaid
flowchart LR
    utils["utils<br/>Platform-independent utilities"]
    edefs["electron-defs<br/>Electron IPC type definitions"]
    nodeutils["node-utils<br/>Node-only utilities"]
    lanshare["lan-share<br/>LAN credential sharing"]
    api["api<br/>Photosphere database API"]
    restapi["rest-api<br/>HTTP REST API"]
    ui["user-interface<br/>React frontend UI"]
    cli["cli<br/>CLI tool (psi)"]
    desktop["desktop<br/>Electron main process"]
    desktopfe["desktop-frontend<br/>Electron renderer"]

    nodeutils --> utils & edefs
    lanshare --> nodeutils & edefs
    api --> nodeutils & utils
    restapi --> api & utils
    ui --> api & lanshare & utils
    cli --> api & lanshare & nodeutils & utils
    desktop --> api & edefs & lanshare & nodeutils & restapi & utils
    desktopfe --> ui & edefs
```
