import { IOpSelection } from "../defs/ops";

//
// Applies a single database operation to the field set for a database record.
//
export function applyOperation(op: IOpSelection, fields: any): void {
    switch (op.type) {
        case "set": {
            for (const [name, value] of Object.entries(op.fields)) {
                fields[name] = value;
            }
            break;
        }

        case "push": {
            if (!fields[op.field]) {
                fields[op.field] = [];
            }
            fields[op.field].push(op.value);
            break;
        }

        case "pull": {
            if (!fields[op.field]) {
                fields[op.field] = [];
            }
            fields[op.field] = fields[op.field].filter((v: any) => v !== op.value);
            break;
        }

        default: {
            throw new Error(`Invalid operation type: ${(op as any).type}`);
        }
    }
}
