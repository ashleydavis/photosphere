import { createServer } from "../server";
import request from "supertest";

describe("photosphere backend", () => {

    test("no assets", async () => {

        const mockCollection: any = {
            find() {
                return {
                    toArray() {
                        return [];
                    },
                };
            },
        };
        const mockDb: any = {
            collection() {
                return mockCollection;
            },
        };
        
        const app = createServer(mockDb);
        const response = await request(app).get("/assets");
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({ 
            assets: [],
        });
    });
});