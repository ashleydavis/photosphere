"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const react_1 = __importDefault(require("react"));
const client_1 = require("react-dom/client");
const app_1 = require("./app");
require("@fortawesome/fontawesome-free/css/all.css");
require("./tailwind.css");
require("./styles.css");
const container = document.getElementById('app');
const root = (0, client_1.createRoot)(container);
root.render(react_1.default.createElement(app_1.App, null));
