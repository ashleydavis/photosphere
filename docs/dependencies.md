# Dependencies

```mermaid
flowchart LR
    lanshare["lan-share<br/>LAN credential sharing"]
    api["api<br/>Platform-agnostic Photosphere API"]
    nodeapi["node-api<br/>Node.js-specific Photosphere API"]
    restapi["rest-api<br/>REST API"]
    ui["user-interface<br/>Frontend UI"]
    cli["cli<br/>CLI"]
    desktop["desktop<br/>Electron main"]
    desktopfe["desktop-frontend<br/>Electron renderer"]

    nodeapi --> api
    restapi --> api & nodeapi
    ui --> api & nodeapi
    cli --> api & nodeapi & lanshare
    desktop --> api & nodeapi & lanshare & restapi & desktopfe
    desktopfe --> ui
```
