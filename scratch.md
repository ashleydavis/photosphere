

CLI: Be good to reference databases by name (or id) as they are in the configured database list.
    Then it can use all the same key, s3, etc.
    Just need to move the database configuration to a shared configuration file.




Now I'd like to be able to share a database configuration and its secrets or a secret from one device to another over the LAN.

This should work in both the CLI tool and Electron app. One app is started as a sender, the other as a receiver. The receiver should be able to view and modify details of the database configuration or secret before they save it to their device.

When the receiver "shares" a database configuration or secret they should be able to view and modify any of details because they click "Share".

We'll need to warn the user of the dangers  of sharing their credentials on a network that they don't own.

Please look at the branch qr-proto to see an example of how this can work in the Electron app.