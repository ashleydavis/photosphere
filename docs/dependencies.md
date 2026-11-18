# Dependencies

```mermaid
flowchart LR
    api["api<br/>Platform-agnostic Photosphere API"]
    ui["user-interface<br/>Frontend UI"]
    frontend["photosphere-frontend<br/>Photosphere App frontend"]

    ui --> api
    frontend --> ui
```
