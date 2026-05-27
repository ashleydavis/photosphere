import { TestUuidGenerator } from "../../lib/test-uuid-generator";

describe("TestUuidGenerator", () => {
    test("generate() returns a non-empty string", () => {
        const generator = new TestUuidGenerator();

        const uuid = generator.generate();

        expect(typeof uuid).toBe("string");
        expect(uuid.length).toBeGreaterThan(0);
    });

    test("generate() returns unique values on successive calls", () => {
        const generator = new TestUuidGenerator();

        const first = generator.generate();
        const second = generator.generate();

        expect(first).not.toBe(second);
    });

    test("generate() produces deterministic output for the same counter position", () => {
        const generatorA = new TestUuidGenerator();
        const generatorB = new TestUuidGenerator();

        const firstA = generatorA.generate();
        const secondA = generatorA.generate();
        const firstB = generatorB.generate();
        const secondB = generatorB.generate();

        expect(firstA).toBe(firstB);
        expect(secondA).toBe(secondB);
    });

    test("generate() returns values in standard UUID v4 string format", () => {
        const generator = new TestUuidGenerator();

        const uuid = generator.generate();

        expect(uuid).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    });

    test("reset() restarts the counter so subsequent ids match the first sequence", () => {
        const generator = new TestUuidGenerator();
        const first = generator.generate();
        const second = generator.generate();

        generator.reset();
        const afterResetFirst = generator.generate();
        const afterResetSecond = generator.generate();

        expect(afterResetFirst).toBe(first);
        expect(afterResetSecond).toBe(second);
    });

    test("two separate instances do not share counter state", () => {
        const generatorA = new TestUuidGenerator();
        const generatorB = new TestUuidGenerator();

        const firstA = generatorA.generate();
        generatorA.generate();
        const firstB = generatorB.generate();

        expect(firstA).toBe(firstB);
    });
});
