// Mock for fs-extra
const pathExists = jest.fn().mockResolvedValue(true);
const readdir = jest.fn().mockResolvedValue([]);

module.exports = {
    pathExists,
    readdir
};

module.exports.default = module.exports;