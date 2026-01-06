import { IUuidGenerator } from './uuid-generator';
import { v4 as uuidv4 } from 'uuid';

//
// Random UUID generator using the uuid library
// Works in both Node.js and browser environments
//
export class RandomUuidGenerator implements IUuidGenerator {
    generate(): string {
        return uuidv4();
    }
}
