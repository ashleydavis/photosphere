# Dependencies

```mermaid
flowchart LR
    utils["utils<br/>Platform-independent utilities"]
    edefs["electron-defs<br/>Electron IPC type definitions"]
    nodeutils["node-utils<br/>Node-only utilities"]
    lanshare["lan-share<br/>LAN credential sharing"]
    api["api<br/>Photosphere API"]
    restapi["rest-api<br/>REST API"]
    ui["user-interface<br/>Frontend UI"]
    cli["cli<br/>CLI"]
    desktop["desktop<br/>Electron main"]
    desktopfe["desktop-frontend<br/>Electron renderer"]

    nodeutils --> utils
    lanshare --> nodeutils & edefs
    api --> nodeutils & utils
    restapi --> api & utils
    ui --> api & lanshare & utils
    cli --> api & lanshare & nodeutils & utils
    desktop --> api & edefs & lanshare & nodeutils & restapi & utils
    desktopfe --> ui & edefs
```
