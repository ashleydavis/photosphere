import { formatBytes } from "../../lib/format";

describe("formatBytes", () => {
    describe("with default options (binary units)", () => {
        it("should format 0 bytes", () => {
            expect(formatBytes(0)).toBe("0 Bytes");
        });

        it("should format bytes under 1 KiB", () => {
            expect(formatBytes(100)).toBe("100 Bytes");
            expect(formatBytes(1023)).toBe("1,023 Bytes");
        });

        it("should format exactly 1 KiB", () => {
            expect(formatBytes(1024)).toBe("1 KiB");
        });

        it("should format KiB values", () => {
            expect(formatBytes(1536)).toBe("1.5 KiB");
            expect(formatBytes(2048)).toBe("2 KiB");
            expect(formatBytes(10240)).toBe("10 KiB");
            expect(formatBytes(102400)).toBe("100 KiB");
        });

        it("should format MiB values", () => {
            expect(formatBytes(1048576)).toBe("1 MiB");
            expect(formatBytes(1572864)).toBe("1.5 MiB");
            expect(formatBytes(10485760)).toBe("10 MiB");
            expect(formatBytes(104857600)).toBe("100 MiB");
        });

        it("should format GiB values", () => {
            expect(formatBytes(1073741824)).toBe("1 GiB");
            expect(formatBytes(1610612736)).toBe("1.5 GiB");
            expect(formatBytes(10737418240)).toBe("10 GiB");
            expect(formatBytes(107374182400)).toBe("100 GiB");
        });

        it("should format TiB values", () => {
            expect(formatBytes(1099511627776)).toBe("1 TiB");
            expect(formatBytes(1649267441664)).toBe("1.5 TiB");
        });

        it("should handle intelligent decimal places", () => {
            // Values >= 100 should have no decimals
            expect(formatBytes(104857600)).toBe("100 MiB");
            expect(formatBytes(107374182400)).toBe("100 GiB");
            
            // Values 10-99 should have up to 1 decimal
            expect(formatBytes(12582912)).toBe("12 MiB");
            expect(formatBytes(13107200)).toBe("12.5 MiB");
            
            // Values < 10 should have up to 2 decimals
            expect(formatBytes(5242880)).toBe("5 MiB");
            expect(formatBytes(5767168)).toBe("5.5 MiB");
            expect(formatBytes(2359296)).toBe("2.25 MiB");
        });
    });

    describe("with decimal units", () => {
        const decimalOptions = { binary: false };

        it("should format exactly 1 KB", () => {
            expect(formatBytes(1000, decimalOptions)).toBe("1 KB");
        });

        it("should format KB values", () => {
            expect(formatBytes(1500, decimalOptions)).toBe("1.5 KB");
            expect(formatBytes(10000, decimalOptions)).toBe("10 KB");
            expect(formatBytes(100000, decimalOptions)).toBe("100 KB");
        });

        it("should format MB values", () => {
            expect(formatBytes(1000000, decimalOptions)).toBe("1 MB");
            expect(formatBytes(1500000, decimalOptions)).toBe("1.5 MB");
            expect(formatBytes(10000000, decimalOptions)).toBe("10 MB");
        });

        it("should format GB values", () => {
            expect(formatBytes(1000000000, decimalOptions)).toBe("1 GB");
            expect(formatBytes(1500000000, decimalOptions)).toBe("1.5 GB");
        });
    });

    describe("with custom locale", () => {
        it("should format with German locale", () => {
            expect(formatBytes(1536, { locale: "de-DE" })).toBe("1,5 KiB");
            expect(formatBytes(1234567890, { locale: "de-DE" })).toBe("1,15 GiB");
        });

        it("should format with French locale", () => {
            expect(formatBytes(1536, { locale: "fr-FR" })).toBe("1,5 KiB");
        });
    });

    describe("with custom decimal places", () => {
        it("should respect custom decimal places for small values", () => {
            expect(formatBytes(2359296, { decimals: 3 })).toBe("2.25 MiB");
            expect(formatBytes(2411724, { decimals: 3 })).toBe("2.3 MiB");
            expect(formatBytes(2306867, { decimals: 3 })).toBe("2.2 MiB");
        });
    });
});