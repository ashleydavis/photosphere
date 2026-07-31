import { installUrl } from "../../lib/install-url";

//
// Unit tests for the WHATWG URL globals. The AWS SDK builds every request URL through them, and the
// embedded engine provides neither, so a missing install shows up as "'URL' is not defined" on the
// first S3 call.
//
describe("install-url", () => {

    test("installs URL and URLSearchParams on a scope that has neither", () => {
        const scope: any = {};

        installUrl(scope);

        expect(typeof scope.URL).toBe("function");
        expect(typeof scope.URLSearchParams).toBe("function");
    });

    test("the installed URL parses the parts the SDK signs a request from", () => {
        const scope: any = {};
        installUrl(scope);

        const parsed = new scope.URL("http://photosphere-adhoc.minio.test:9000/db/.db/files.dat?x-id=GetObject");

        expect(parsed.protocol).toBe("http:");
        expect(parsed.hostname).toBe("photosphere-adhoc.minio.test");
        expect(parsed.port).toBe("9000");
        expect(parsed.pathname).toBe("/db/.db/files.dat");
        expect(parsed.search).toBe("?x-id=GetObject");
    });

    test("the installed URLSearchParams reads query parameters", () => {
        const scope: any = {};
        installUrl(scope);

        const params = new scope.URLSearchParams("list-type=2&prefix=db%2F");

        expect(params.get("list-type")).toBe("2");
        expect(params.get("prefix")).toBe("db/");
    });

    test("leaves an engine's own URL alone", () => {
        const existingUrl = function ExistingUrl() { /* the engine's own implementation */ };
        const scope: any = { URL: existingUrl };

        installUrl(scope);

        expect(scope.URL).toBe(existingUrl);
    });
});
