const webpack = require('webpack');
const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');
const CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = {
    entry: './src/index.tsx',
    output: {
        filename: '[name].[contenthash].js',
        path: path.resolve(__dirname, 'dist'),
    },
    devtool: 'source-map',
    mode: 'development',
    target: 'web',
    performance: { //TODO: Adjust/remove this later for prod performance.
        hints: false,
        maxEntrypointSize: 512000,
        maxAssetSize: 512000
    },
    devServer: {
        historyApiFallback: true,
    },
    watchOptions: {
        ignored: /node_modules/,
    },
    module: {
        rules: [
            {
                test: /\.tsx?$/,
                use: 'ts-loader',
                exclude: /node_modules/,
            },
            {
                test: /\.js$/,
                use: ['source-map-loader'],
                enforce: 'pre'
            },
            {
                test: /\.css$/,
                use: [
                    'style-loader',
                    'css-loader',
                    'postcss-loader',
                ],
            },
        ],
    },
    resolve: {
        extensions: ['.tsx', '.ts', '.js'],
        // https://stackoverflow.com/a/64802753/25868
        fallback: {
            "fs": false,
            "tls": false,
            "net": false,
            "path": false,
            "zlib": false,
            "http": false,
            "https": false,
            "stream": false,
            "crypto": false,
            "crypto-browserify": require.resolve('crypto-browserify'),
        },
    },
    plugins: [
        new webpack.EnvironmentPlugin({
            ...process.env,
        }),
        new HtmlWebpackPlugin({
            template: 'src/index.html',
            excludeChunks: [ 'service-worker' ],
        }),
        new CopyWebpackPlugin({
            patterns: [
                { from: 'src/service-worker.js', to: './' },
            ],
        }),
    ],
};
