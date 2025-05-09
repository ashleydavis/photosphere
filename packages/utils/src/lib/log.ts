export const log = {
    info(message: string) {
        console.log(message);
    },
    success(message: string) {
        console.log(message);
    },
    verbose(message: string) {
        console.log(message);
    },
    fail(message: string) {
        console.log(message);
    },
    error(message: string) {
        console.error(message);
    },
    exception(message: string, error: Error) {
        console.error(message);
        console.error(error.stack || error.message || error);

        this.json("exception", {
            message: message,
            error, //logo: serialize error.
        });
    },
    debug(message: string) {
        console.debug(message);
    },
    warn(message: string) {
        console.warn(message);
    },

    //
    // Includes streaming JSON data in the output.
    //
    json(key: string, data: any) {
        console.log(`JSON: ${key}:`);
        console.log(JSON.stringify(data, null, 2));
    }
};