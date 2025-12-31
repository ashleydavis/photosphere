//
// Setup the build directory.
//

const fs = require('fs-extra');
const { hoist } = require('hoist-modules');

async function main() {
    const buildDir = `./tmp/build`;
    fs.removeSync(buildDir);
    fs.ensureDirSync(buildDir);

    //
    // Package.json.
    //
    const package = JSON.parse(fs.readFileSync(`package.json`, 'utf8'));
    package.name = "Photosphere";
    fs.writeFileSync(`${buildDir}/package.json`, JSON.stringify(package, null, 2));

    //
    // Copy files.
    //
    fs.copySync('main.js', `${buildDir}/main.js`);
    fs.copySync('frontend/dist', `${buildDir}/frontend/dist`);

    //
    // Copy and hoist node-modules.
    // An `npm install` is not enough due to the shared packages in the monorepo.
    //
    await hoist("./", `${buildDir}/node_modules`, { devDependencies: true });
}

main()
    .catch(err => {
        console.error(`Build setup failed.`);
        console.error(err);
        process.exit(1);
    });


