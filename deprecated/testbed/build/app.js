"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.App = App;
const react_1 = __importDefault(require("react"));
const test_indexeddb_1 = require("./tests/test-indexeddb");
function App() {
    return (react_1.default.createElement(test_indexeddb_1.TestIndexeddb, null));
}
