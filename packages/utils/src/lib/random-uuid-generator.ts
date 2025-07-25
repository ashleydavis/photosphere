import { IUuidGenerator } from './uuid-generator';

//
// Random UUID generator using crypto.randomUUID()
//
export class RandomUuidGenerator implements IUuidGenerator {
    generate(): string {
        const uuid = crypto.randomUUID();
        console.log(`[!!!!!!!] ${uuid}`);
        return uuid;
    }
}